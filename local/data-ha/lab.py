"""Run only this named Compose project on the local Docker Desktop Linux engine."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import urllib.request
import urllib.parse

ROOT=Path(__file__).resolve().parent
RUNTIME=ROOT/'.runtime'
ENV=RUNTIME/'.env'
CONTEXT='desktop-linux'
STAGES=('redis','rabbitmq','mongodb')
IMAGES={'REDIS_IMAGE':'redis:7.2-alpine','RABBITMQ_IMAGE':'rabbitmq:4.3-management','MONGO_IMAGE':'mongo:7.0',
        'REDIS_EXPORTER_IMAGE':'oliver006/redis_exporter:v1.67.0','MONGO_EXPORTER_IMAGE':'percona/mongodb_exporter:0.44.0',
        'PROMETHEUS_IMAGE':'prom/prometheus:v3.5.0','GRAFANA_IMAGE':'grafana/grafana:12.2.0','PYTHON_IMAGE':'python:3.12-slim',
        'ALERTMANAGER_IMAGE':'prom/alertmanager:v0.28.1','ALLOY_IMAGE':'grafana/alloy:v1.15.0','LOKI_IMAGE':'grafana/loki:3.6.5'}

def run(command,check=True):
    result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace')
    if check and result.returncode:
        # Docker errors/build logs do not require dumping the rendered secret-bearing config.
        print(result.stderr[-6000:],file=sys.stderr)
        raise RuntimeError(f'Command failed ({result.returncode}): {command[0]} {command[1]}')
    return result

def guard():
    endpoint=run(['docker','context','inspect',CONTEXT,'--format','{{.Endpoints.docker.Host}}']).stdout.strip()
    if endpoint!='npipe:////./pipe/dockerDesktopLinuxEngine':
        raise RuntimeError('Refusing a nonlocal or unexpected Docker endpoint: '+endpoint)

def compose(*arguments,check=True):
    if not ENV.exists(): raise RuntimeError('Run: python lab.py init')
    return run(['docker','--context',CONTEXT,'compose','--project-name','doktori-ha-local',
                '--env-file',str(ENV),'-f',str(ROOT/'compose.yaml'),*arguments],check=check)

def init():
    RUNTIME.mkdir(exist_ok=True)
    if ENV.exists():
        text=ENV.read_text();existing=dict(line.split('=',1) for line in text.splitlines() if '=' in line)
        additions={'RABBITMQ_MONITOR_USER':'ha_monitor','RABBITMQ_MONITOR_PASSWORD':secrets.token_hex(24)}
        lock=ROOT/'images.lock.json'
        additions.update({k:v['digest'] for k,v in json.loads(lock.read_text())['images'].items()} if lock.exists() else IMAGES)
        for key,value in additions.items():
            if key not in existing:text+=key+'='+value+'\n'
        ENV.write_text(text,encoding='utf-8')
        print('Existing credentials retained; missing observability settings added')
        return
    values={'REDIS_PASSWORD':secrets.token_hex(24),'RABBITMQ_USER':'doktori',
        'RABBITMQ_PASSWORD':secrets.token_hex(24),'RABBITMQ_ERLANG_COOKIE':secrets.token_hex(32),
        'MONGO_ADMIN_USERNAME':'lab_admin','MONGO_ADMIN_PASSWORD':secrets.token_hex(24),
        'MONGO_PASSWORD':secrets.token_hex(24),'MONGO_MONITOR_PASSWORD':secrets.token_hex(24),
        'MONGO_REPLICA_KEY':base64.b64encode(secrets.token_bytes(48)).decode(),
        'RABBITMQ_MONITOR_USER':'ha_monitor','RABBITMQ_MONITOR_PASSWORD':secrets.token_hex(24),
        'GRAFANA_PASSWORD':secrets.token_hex(24),**IMAGES}
    lock=ROOT/'images.lock.json'
    if lock.exists(): values.update({key:item['digest'] for key,item in json.loads(lock.read_text())['images'].items()})
    ENV.write_text(''.join(f'{key}={value}\n' for key,value in values.items()),encoding='utf-8')
    try: ENV.chmod(0o600)
    except OSError: pass
    print('Generated local-only credentials in .runtime/.env; not printed or committed')

def monitoring(stage):
    query='http://127.0.0.1:19090/api/v1/targets'
    for _ in range(30):
        try:
            with urllib.request.urlopen(query,timeout=5) as response: data=json.load(response)
            targets=[t for t in data['data']['activeTargets'] if t['labels']['job']==stage]
            if len(targets)==3 and all(t['health']=='up' for t in targets):
                return [{'target':t['labels']['instance'],'health':t['health']} for t in targets]
        except (OSError,KeyError,ValueError): pass
        time.sleep(2)
    raise RuntimeError('Three healthy monitoring scrape targets not found for '+stage)

def verify(stage,configure):
    if stage=='mongodb' and configure:
        compose('exec','-T','mongo-a','mongosh','--quiet','--host','127.0.0.1','/lab/init.js')
    result=compose('run','--rm','--no-deps','lab-tools',stage,*(['--configure'] if configure else []))
    try: report=json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError,IndexError):
        raise RuntimeError('Probe did not emit its JSON report')
    report['monitoring_targets']=monitoring(stage)
    report['scope']='Docker Desktop only; no failover, AZ, cloud, backup restore or application E2E'
    (RUNTIME/(stage+'-report.json')).write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

def lock_images():
    result={}
    for key,tag in IMAGES.items():
        info=json.loads(run(['docker','--context',CONTEXT,'image','inspect',tag]).stdout)[0]
        digests=info.get('RepoDigests',[])
        if not digests: raise RuntimeError('Pull the tagged source image before locking: '+tag)
        result[key]={'tag':tag,'digest':digests[0],'image_id':info['Id'],'architecture':info['Architecture']}
    (ROOT/'images.lock.json').write_text(json.dumps({'images':result},indent=2)+'\n',encoding='utf-8')
    lines=ENV.read_text().splitlines()
    ENV.write_text('\n'.join(key+'='+result[key]['digest'] if key in result else line
        for line in lines for key in [line.split('=',1)[0]])+'\n',encoding='utf-8')
    print('Locked public image digests; local credentials unchanged')

def observability():
    from visibility import verify as verify_visibility
    return verify_visibility()


def configure_observability(stage):
    marker=RUNTIME/'monitoring-stage.txt'
    previous=marker.read_text().strip() if marker.exists() else 'redis'
    through=max(STAGES.index(previous),STAGES.index(stage))
    selected=set(STAGES[:through+1])
    canonical=json.loads((ROOT/'observability/inventory.json').read_text())
    canonical['targets']=[t for t in canonical['targets'] if t['service'] in selected or t['job']=='data-ha-alloy']
    inventory=RUNTIME/'inventory.json';inventory.write_text(json.dumps(canonical,indent=2)+'\n',encoding='utf-8')
    run([sys.executable,str(ROOT.parents[1]/'monitoring/data-ha/build_assets.py'),'--inventory',str(inventory),
         '--output',str(ROOT/'observability/generated'),'--datasource','local-prom'])
    (ROOT/'observability/grafana/dashboards/ha.json').write_bytes((ROOT/'observability/generated/dashboard.json').read_bytes())
    marker.write_text(STAGES[through],encoding='utf-8')


parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('action',choices=['init','up','verify','status','stop','lock-images','observability'])
parser.add_argument('stage',nargs='?',choices=[*STAGES,'all'])
args=parser.parse_args()
try:
    if args.action=='init': init()
    else:
        guard()
        if args.action in ('up','verify') and args.stage not in STAGES: parser.error('Select one stage')
        if args.action=='up':
            init()
            configure_observability(args.stage)
            compose('config','--quiet')
            print('Building local client tools',flush=True)
            compose('build','--quiet','lab-tools')
            print('Starting local '+args.stage+' and observability',flush=True)
            compose('--profile',args.stage,'--profile','observability','up','-d','--wait','--wait-timeout','240')
            verify(args.stage,True)
            if args.stage=='rabbitmq':
                compose('run','--rm','--no-deps','--entrypoint','python','lab-tools','/setup-observability.py')
            compose('restart','prometheus')
        elif args.action=='verify': verify(args.stage,False)
        elif args.action=='status': print(compose('--profile','*','ps').stdout)
        elif args.action=='stop':
            if args.stage not in [*STAGES,'all']: parser.error('Select a stage or all')
            compose('--profile','*' if args.stage=='all' else args.stage,'stop')
            print('Stopped selected local services; volumes and credentials retained')
        elif args.action=='lock-images': lock_images()
        elif args.action=='observability': observability()
except Exception as error:
    print(str(error),file=sys.stderr)
    raise SystemExit(1)
