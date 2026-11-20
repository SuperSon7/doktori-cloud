"""Render actual Terraform templates and syntax-check them without executing bootstrap."""
import argparse
import ast
import base64
import gzip
import json
import re
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform", default="terraform")
    parser.add_argument("--bash", default="bash")
    parser.add_argument("--node", default="node")
    parser.add_argument("--alloy-image", help="Optional Docker Desktop offline Alloy validation image")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    templates = root / "terraform/environments/prod/data/templates"
    common = dict(project_name="test", environment="test", aws_region="ap-northeast-2",
        enable_data_ha_observability=True, remote_write_url="http://prometheus:9090/api/v1/write",
        loki_push_url="http://loki:3100/loki/api/v1/push")
    cases = {}
    for enabled in (False, True):
        cases[f"redis-{enabled}"] = ("redis_node_user_data.sh.tftpl", dict(common,
            node_name="redis-a", node_role="primary", redis_sentinel_enabled=enabled,
            redis_master_name="test-master", redis_primary_dns="redis-a.test.internal",
            redis_sentinel_quorum=2, redis_sentinel_nodes="redis-a.test.internal:26379,redis-c.test.internal:26379,redis-b.test.internal:26379",
            allow_initial_primary=False))
        cases[f"rabbitmq-{enabled}"] = ("rabbitmq_node_user_data.sh.tftpl", dict(common,
            node_name="rabbitmq-c", node_fqdn="rabbitmq-c.test.internal", cluster_enabled=enabled,
            primary_node_dns="rabbitmq-a.test.internal", primary_nodename="rabbit@rabbitmq-a.test.internal",
            quorum_exporter_b64=base64.b64encode((root / 'scripts/data-ha/quorum_exporter.py').read_bytes()).decode()))
        for member_id in (0, 1):
            cases[f"mongodb-{enabled}-{member_id}"] = ("mongodb_node_user_data.sh.tftpl", dict(common,
                node_name="mongodb", replica_enabled=enabled, replica_set_name="test-rs",
                replica_member_id=member_id, replica_members_json=json.dumps([
                    {"_id": index, "host": f"mongodb-{index}.test.internal:27017"} for index in range(3)])))
    for service in ('redis','rabbitmq','mongodb'):
        original = next(value for name,value in cases.items() if name.startswith(service+'-True'))
        cases[service+'-ha-observability-disabled'] = (original[0], dict(original[1],enable_data_ha_observability=False))
    expression = "jsonencode({" + ",".join(
        json.dumps(name) + "=templatefile(" + json.dumps((templates / filename).as_posix()) + "," + json.dumps(values) + ")"
        for name, (filename, values) in cases.items()) + "})"
    with tempfile.TemporaryDirectory(prefix="doktori-ha-syntax-") as work:
        if args.alloy_image:
            endpoint=subprocess.check_output(['docker','context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}'],text=True).strip()
            assert endpoint=='npipe:////./pipe/dockerDesktopLinuxEngine'
            (Path(work)/'redis-password').write_text('fake-validation-only',encoding='utf-8')
        result = subprocess.run([args.terraform, "console", "-no-color"], cwd=work,
            input=expression + "\n", text=True, encoding="utf-8", capture_output=True, check=True)
        rendered = json.loads(json.loads(result.stdout.strip()))
        for name, script in rendered.items():
            assert '\r' not in script, name + ': native bootstrap must use LF line endings'
            path = Path(work) / (name + ".sh")
            path.write_text(script, encoding="utf-8", newline="\n")
            subprocess.run([args.bash, "-n", str(path)], check=True)
            # Inspect every embedded script, including the quorum exporter payload.
            if name.startswith("mongodb"):
                for index, js in enumerate(re.findall(r"<<'?JS'?\n(.*?)\nJS", script, re.S)):
                    js_path = Path(work) / f"{name}-{index}.js"
                    js_path.write_text(js, encoding="utf-8")
                    subprocess.run([args.node, "--check", str(js_path)], check=True)
            for python in re.findall(r"<<'PY'\n(.*?)\nPY", script, re.S):
                ast.parse(python)
            wrapper = subprocess.run([args.terraform,'console','-no-color'],cwd=work,
                input='jsonencode(templatefile('+json.dumps((templates/'gzip_bootstrap.sh.tftpl').as_posix())+
                      ',{payload=base64gzip('+json.dumps(script.replace('${','$${').replace('%{','%%{'))+')}))\n',
                text=True,encoding='utf-8',capture_output=True,check=True)
            wrapped=json.loads(json.loads(wrapper.stdout.strip()))
            assert len(wrapped.encode()) < 16384, 'EC2 raw user_data byte limit exceeded'
            payload=re.search(r"printf '%s' '([^']+)'",wrapped).group(1)
            assert gzip.decompress(base64.b64decode(payload)).decode()==script
            wrapped_path=Path(work)/(name+'-wrapper.sh'); wrapped_path.write_text(wrapped,encoding='utf-8',newline='\n')
            subprocess.run([args.bash,'-n',str(wrapped_path)],check=True)
            if args.alloy_image:
                configs=re.findall(r'cat >/etc/alloy/config.alloy <<EOF\n(.*?)\nEOF',script,re.S)
                assert len(configs)==1, name + ': expected one full native Alloy configuration'
                config=configs[0]
                for key,value in {'NODE_NAME':cases[name][1]['node_name'],'NODE_ROLE':'primary',
                                  'EXPORTER_USER':'fake_monitor','EXPORTER_PASS':'fake_password'}.items():
                    config=config.replace('$'+key,value)
                (Path(work)/(name+'.alloy')).write_text(config,encoding='utf-8')
                subprocess.run(['docker','--context','desktop-linux','run','--rm','--network','none',
                    '-v',work+':/etc/alloy:ro',args.alloy_image,'validate','/etc/alloy/'+name+'.alloy'],check=True)
        subprocess.run([args.bash, "-n", str(root / "scripts/data-ha/configure-rabbitmq-quorum.sh")], check=True)
    print(f"PASS: {len(cases)} rendered scripts and gzip wrappers <16KiB; embedded JS/Python and operator syntax")


if __name__ == "__main__":
    main()
