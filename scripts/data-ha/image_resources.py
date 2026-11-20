"""Read-only audit of resources belonging to one tagged Packer run."""
import argparse
import json
import re
import subprocess
from pathlib import Path


def audit(profile, region, account, run_id, build_log=None):
    if not re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{8}', run_id):
        raise ValueError('Expected an exact data HA runner build ID')

    def aws(service, operation, *arguments):
        result = subprocess.run(['aws', '--profile', profile, '--region', region,
                                 '--no-cli-pager', '--cli-connect-timeout', '5', '--cli-read-timeout', '20',
                                 service, operation, *arguments, '--output', 'json'],
                                capture_output=True, text=True, encoding='utf-8', check=True)
        return json.loads(result.stdout)

    identity = aws('sts', 'get-caller-identity')
    if identity['Account'] != account:
        raise ValueError('Account mismatch; refusing audit in another account')
    tagged = ('--filters', f'Name=tag:DoktoriBuildRun,Values={run_id}')
    instances = [i for r in aws('ec2', 'describe-instances', *tagged)['Reservations'] for i in r['Instances']]
    alive = [i['InstanceId'] for i in instances if i['State']['Name'] != 'terminated']
    volumes = aws('ec2', 'describe-volumes', *tagged)['Volumes']
    groups = aws('ec2', 'describe-security-groups', *tagged)['SecurityGroups']
    keys = aws('ec2', 'describe-key-pairs', *tagged)['KeyPairs']
    interfaces = aws('ec2', 'describe-network-interfaces', *tagged)['NetworkInterfaces']
    images = aws('ec2', 'describe-images', '--owners', 'self', *tagged)['Images']
    snapshots = aws('ec2', 'describe-snapshots', '--owner-ids', 'self', *tagged)['Snapshots']
    named_groups, named_keys = [], []
    if build_log:
        raw = Path(build_log).read_bytes()
        log = raw.decode('utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig', errors='replace')
        # Also check names reported by Packer, so missing resource tags cannot
        # hide a temporary SG/key. Values originate from this run's local log.
        group_names = sorted(set(re.findall(r'Creating temporary security group for this instance: (packer_[0-9a-f-]+)', log)))
        key_names = sorted(set(re.findall(r'Creating temporary keypair: (packer_[0-9a-f-]+)', log)))
        if group_names:
            named_groups = [g['GroupId'] for g in aws('ec2', 'describe-security-groups', '--filters',
                            'Name=group-name,Values=' + ','.join(group_names))['SecurityGroups']]
        if key_names:
            named_keys = [k['KeyPairId'] for k in aws('ec2', 'describe-key-pairs', '--filters',
                          'Name=key-name,Values=' + ','.join(key_names))['KeyPairs']]
    kept = {b['Ebs']['SnapshotId'] for i in images for b in i.get('BlockDeviceMappings', []) if 'Ebs' in b}
    result = {
        'account': account, 'region': region, 'build_run': run_id,
        'active_instances': alive, 'terminated_instances': [i['InstanceId'] for i in instances if i['State']['Name'] == 'terminated'],
        'temporary_volumes': [v['VolumeId'] for v in volumes],
        'temporary_security_groups': [g['GroupId'] for g in groups],
        'temporary_key_pairs': [k['KeyPairId'] for k in keys],
        'temporary_network_interfaces': [n['NetworkInterfaceId'] for n in interfaces],
        'named_temporary_security_groups': named_groups,
        'named_temporary_key_pairs': named_keys,
        'retained_images': [{k: i[k] for k in ('ImageId', 'State', 'Public', 'Architecture', 'Name')} for i in images],
        'retained_image_snapshots': sorted(kept),
        'unreferenced_tagged_snapshots': [s['SnapshotId'] for s in snapshots if s['SnapshotId'] not in kept],
        'scope': 'exact build-run tag; read-only; no delete/terminate/Terraform calls',
    }
    result['temporary_resources_clean'] = not any((alive, volumes, groups, keys, interfaces, named_groups, named_keys, result['unreferenced_tagged_snapshots']))
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--region', required=True)
    parser.add_argument('--account', required=True)
    parser.add_argument('--run', required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--build-log', type=Path, help='also verify Packer-reported temporary SG/key names')
    args = parser.parse_args()
    try:
        result = audit(args.profile, args.region, args.account, args.run, args.build_log)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding='utf-8')
    print(text)
    raise SystemExit(0 if result['temporary_resources_clean'] else 1)
