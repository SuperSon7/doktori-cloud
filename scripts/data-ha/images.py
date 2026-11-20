"""Prepare/check data AMI templates offline, or explicitly run Packer later.

No AWS SDK/CLI calls, Terraform execution or source-variable rewriting.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SERVICES = ('redis', 'rabbitmq', 'mongodb')
RUNTIME = ROOT / 'packer/data-ha/.runtime'
AMI = re.compile(r'ami-(?:[0-9a-f]{8}|[0-9a-f]{17})\Z')


def invoke(packer, *arguments, env=None):
    subprocess.run([packer, *map(str, arguments)], cwd=ROOT, env=env, check=True)


def stage(directory):
    directory.mkdir(parents=True, exist_ok=False)
    common = (ROOT / 'packer/variables.pkr.hcl').read_text(encoding='utf-8')
    # Isolate the data build plugin pin without changing other AMI pipelines.
    needle = 'version = ">= 1.3.0"'
    if common.count(needle) != 1:
        raise ValueError('Review shared Amazon plugin constraint before staging')
    (directory / 'variables.pkr.hcl').write_text(common.replace(needle, 'version = "= 1.8.4"'), encoding='utf-8')
    for service in SERVICES:
        shutil.copy2(ROOT / f'packer/{service}.pkr.hcl', directory)


def manifest_ami(path, service, region):
    data = json.loads(path.read_text(encoding='utf-8'))
    run_id = data.get('last_run_uuid')
    builds = [b for b in data.get('builds', []) if run_id and b.get('packer_run_uuid') == run_id]
    if len(builds) != 1:
        raise ValueError(f'{service}: expected one artifact from last_run_uuid')
    build = builds[0]
    custom = build.get('custom_data', {})
    if build.get('builder_type') != 'amazon-ebs' or custom.get('data_ha_service') != service or custom.get('architecture') != 'arm64':
        raise ValueError(f'{service}: artifact type/service/architecture mismatch')
    if not AMI.fullmatch(custom.get('base_ami', '')):
        raise ValueError(f'{service}: missing concrete base AMI provenance')
    prefix, separator, ami = build.get('artifact_id', '').partition(':')
    if not separator or prefix != region or not AMI.fullmatch(ami):
        raise ValueError(f'{service}: artifact region or AMI ID mismatch')
    return ami


def export_inputs(manifests, region, through, output):
    services = SERVICES[:SERVICES.index(through) + 1]
    # Read and validate every artifact before creating any output.
    amis = {s: manifest_ami(manifests / f'manifest-{s}.json', s, region) for s in services}
    if len(set(amis.values())) != len(amis):
        raise ValueError('Different data services must not share an AMI artifact')
    values = {f'enable_{s}_ha': s in services for s in SERVICES}
    values.update(ha_ami_ids=amis, allow_redis_initial_primary=False, enable_data_ha_observability=True)
    # JSON input is explicitly selected, never automatically loaded by Terraform.
    if output.name in ('terraform.tfvars', 'terraform.tfvars.json') or output.name.endswith(('.auto.tfvars', '.auto.tfvars.json')):
        raise ValueError('Refusing auto-loaded Terraform inputs')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as handle:
        handle.write(json.dumps(values, indent=2) + '\n')
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('check', 'build', 'export'))
    parser.add_argument('--packer', default='packer')
    parser.add_argument('--service', choices=(*SERVICES, 'all'), default='all')
    parser.add_argument('--var-file', type=Path)
    parser.add_argument('--execute-cloud', action='store_true', help='build only: creates a billable temporary EC2 builder and AMI/snapshot')
    parser.add_argument('--manifests', type=Path)
    parser.add_argument('--region', default='ap-northeast-2')
    parser.add_argument('--through', choices=SERVICES, default='mongodb')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.action == 'check':
        # Packer -syntax-only does not validate the builder plugin or call AWS.
        with tempfile.TemporaryDirectory(prefix='doktori-packer-check-') as parent:
            directory = Path(parent) / 'templates'
            stage(directory)
            shutil.copy2(ROOT / 'packer/data-ha/build.pkrvars.hcl.example', directory / 'review.pkrvars.hcl')
            invoke(args.packer, 'fmt', '-check', directory)
            invoke(args.packer, 'validate', '-syntax-only', directory)
        print('PASS: isolated data templates, formatting and syntax only; no AWS/build')
    elif args.action == 'export':
        if args.manifests is None or args.output is None:
            parser.error('export requires --manifests and --output')
        export_inputs(args.manifests.resolve(), args.region, args.through, args.output.resolve())
        print('Wrote explicit review-only Terraform inputs; no Terraform executed')
    else:
        if not args.execute_cloud:
            parser.error('build creates AWS resources; add --execute-cloud only for an authorized build')
        if args.var_file is None or not args.var_file.is_file():
            parser.error('build requires a reviewed --var-file')
        settings = args.var_file.resolve()
        body = settings.read_text(encoding='utf-8')
        if 'REPLACE_WITH' in body or not re.search(r'data_ha_source_ami\s*=\s*"ami-(?:[0-9a-f]{8}|[0-9a-f]{17})"', body):
            parser.error('replace placeholders and provide a concrete base AMI')
        if settings.name.endswith('.example'):
            parser.error('copy the example to a reviewed build file first')
        run = RUNTIME / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
        templates = run / 'templates'
        stage(templates)
        manifests = run / 'manifests'
        manifests.mkdir()
        # Avoid picking up unrelated PKR_VAR values or implicit HCP publication.
        child_env = {k: v for k, v in os.environ.items() if not k.startswith(('PKR_VAR_', 'HCP_PACKER_'))}
        invoke(args.packer, 'init', templates, env=child_env)
        selected = SERVICES if args.service == 'all' else (args.service,)
        for service in selected:
            invoke(args.packer, 'build', '-on-error=cleanup', f'-only=amazon-ebs.{service}',
                   f'-var-file={settings}', f'-var=data_ha_manifest_dir={manifests.as_posix()}',
                   f'-var=data_ha_build_id={run.name}', templates, env=child_env)
        print('Packer completed. Review manifests before exporting Terraform inputs: ' + str(manifests))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
