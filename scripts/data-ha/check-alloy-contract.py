"""Run native exporter configs against local DBs; never execute EC2 bootstrap."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

ROOT=Path(__file__).resolve().parents[2];LAB=ROOT/'local/data-ha';TEMPLATES=ROOT/'terraform/environments/prod/data/templates'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--terraform',default='terraform');args=parser.parse_args()
def docker(*args):return subprocess.check_output(['docker','--context','desktop-linux',*args],text=True,encoding='utf-8',stderr=subprocess.DEVNULL)
assert docker('context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}').strip()=='npipe:////./pipe/dockerDesktopLinuxEngine'
env=dict(l.split('=',1) for l in (LAB/'.runtime/.env').read_text().splitlines() if '=' in l)
containers=[];result={}
try:
 with tempfile.TemporaryDirectory(prefix='doktori-alloy-contract-') as directory:
  folder=Path(directory);(folder/'redis-password').write_text(env['REDIS_PASSWORD'])
  for service in ('redis','mongodb'):
   values={'project_name':'test','environment':'contract','aws_region':'ap-northeast-2',
     'node_name':'native-'+service,'enable_data_ha_observability':True,
     'remote_write_url':'http://prometheus:9090/api/v1/write','loki_push_url':'http://loki:3100/loki/api/v1/push'}
   if service=='redis':values.update(node_role='primary',redis_sentinel_enabled=True,redis_master_name='doktori-master',
      redis_primary_dns='redis-a',redis_sentinel_quorum=2,redis_sentinel_nodes='sentinel-a:26379,sentinel-b:26379,sentinel-c:26379',allow_initial_primary=False)
   else:values.update(replica_enabled=True,replica_set_name='doktori-rs',replica_member_id=0,
      replica_members_json=json.dumps([{'_id':i,'host':'mongo-'+s+':27017'} for i,s in enumerate('abc')]))
   expression='jsonencode(templatefile('+json.dumps((TEMPLATES/(service+'_node_user_data.sh.tftpl')).as_posix())+','+json.dumps(values)+'))'
   rendered=subprocess.run([args.terraform,'console','-no-color'],cwd=folder,input=expression+'\n',
      text=True,encoding='utf-8',capture_output=True,check=True)
   script=json.loads(json.loads(rendered.stdout.strip()))
   config=re.findall(r'cat >/etc/alloy/config.alloy <<EOF\n(.*?)\nEOF',script,re.S)[0]
   config=re.sub(r'loki.source.journal "[^"]+" \{.*?\n\}', '', config, flags=re.S)
   config=config.replace('$NODE_NAME',values['node_name']).replace('$NODE_ROLE','primary')
   config=config.replace('$EXPORTER_USER','monitor').replace('$EXPORTER_PASS',env['MONGO_MONITOR_PASSWORD'])
   config=config.replace('127.0.0.1:6379','redis-a:6379').replace('127.0.0.1:26379','sentinel-a:26379').replace('127.0.0.1:27017','mongo-a:27017')
   (folder/(service+'.alloy')).write_text(config,encoding='utf-8')
   name='doktori-ha-contract-'+service+'-'+uuid.uuid4().hex[:8];containers.append(name)
   docker('run','--rm','-d','--name',name,'--network','doktori-ha-local_lab','-v',str(folder)+':/etc/alloy:ro',
      'grafana/alloy:v1.15.0','run','--storage.path=/tmp/alloy','/etc/alloy/'+service+'.alloy')
  def query(q):
   with urllib.request.urlopen('http://127.0.0.1:19090/api/v1/query?query='+urllib.parse.quote(q),timeout=5) as r:return json.load(r)['data']['result']
  for _ in range(35):
   healthy=True
   for service,jobs in [('redis',{'redis','redis-sentinel','data-ha-host','data-ha-alloy'}),('mongodb',{'mongodb','data-ha-host','data-ha-alloy'})]:
    rows=query('up{env="contract",node="native-'+service+'"}')
    actual={r['metric']['job'] for r in rows if float(r['value'][1])==1}
    if not jobs<=actual:healthy=False
    result[service]={'expected_jobs':sorted(jobs),'actual_jobs':sorted(actual)}
   if healthy:break
   time.sleep(2)
  assert healthy,result
  redis=query('redis_instance_info{env="contract",job="redis",role="master"}')
  mongo=query('mongodb_rs_myState{env="contract",job="mongodb"}')
  assert redis and mongo,'Native metric role/name contract differs'
  result.update(redis_actual_role='master',mongodb_self_state=float(mongo[0]['value'][1]),
    cloud_bootstrap_executed=False,journal_collection_tested=False)
  (LAB/'.runtime/native-contract-report.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
  print(json.dumps(result,indent=2))
finally:
 for name in containers:
  try:docker('stop','-t','5',name)
  except subprocess.CalledProcessError:pass
