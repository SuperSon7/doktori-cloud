"""Exercise HA alert semantics with synthetic samples, not database failures."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import yaml

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('assets',ROOT/'monitoring/data-ha/build_assets.py')
assets=importlib.util.module_from_spec(spec);spec.loader.exec_module(assets)
inventory=json.loads((ROOT/'local/data-ha/observability/inventory.json').read_text())
rules,_=assets.assets(inventory,'local-prom')
E={'env':'local','cluster':'doktori-local-data'}
samples=[]

def add(metric,labels,value):
    samples.append({'metric':metric,'labels':dict(labels),'values':str(value)+'+0x40'})

for target in inventory['targets']:
    labels={**E,**target};job=target['job'];node=target['node'];add('up',labels,1)
    if job in ('redis','redis-sentinel'):add('redis_up',labels,1)
    if job=='redis':
        add('redis_instance_info',{**labels,'role':'master' if node=='redis-a' else 'slave'},1)
        add('redis_connected_slaves',labels,2 if node=='redis-a' else 0)
        add('redis_aof_last_write_status',labels,1)
        if node!='redis-a':add('redis_master_link_up',labels,1)
    if job=='redis-sentinel':
        add('redis_sentinel_master_ckquorum_status',labels,1)
        add('redis_sentinel_master_status',{**labels,'master_status':'ok','master_address':'redis-a:6379'},1)
    if job=='rabbitmq-quorum':
        add('doktori_rabbitmq_probe_success',labels,1)
        add('doktori_rabbitmq_partition_reports',labels,0)
        for queue in ('notification.delivery.queue','notification.delivery.wait.v2','notification.delivery.dlq'):
            for metric,value in [('present',1),('is_quorum',1),('online_members',3),('required_majority',2),('leader_present',1)]:
                add('doktori_rabbitmq_queue_'+metric,{**labels,'queue':queue,'vhost':'/'},value)
    if job=='rabbitmq':
        add('rabbitmq_alarms_memory_used_watermark',labels,0);add('rabbitmq_alarms_free_disk_space_watermark',labels,0)
        if node=='rabbitmq-a':
            for queue in ('notification.delivery.queue','notification.delivery.wait.v2','notification.delivery.dlq'):
                for metric,value in [('messages_ready',0),('messages_unacked',0),('consumers',1 if queue=='notification.delivery.queue' else 0)]:
                    add('rabbitmq_queue_'+metric,{**labels,'queue':queue,'vhost':'/'},value)
    if job=='mongodb':
        add('mongodb_up',labels,1);add('mongodb_rs_myState',labels,1 if node=='mongo-a' else 2)
        add('mongodb_mongod_replset_member_replication_lag',{**labels,'self':'1'},0)


def change(data,metric,value,**labels):
    matched=0
    for item in data:
        if item['metric']==metric and all(item['labels'].get(k)==v for k,v in labels.items()):
            item['values']=str(value)+'+0x40';matched+=1
    assert matched, metric


def remove(data,metric,**labels):
    data[:]=[s for s in data if not (s['metric']==metric and all(s['labels'].get(k)==v for k,v in labels.items()))]


def inputs(data):
    return [{'series':s['metric']+'{'+','.join(k+'='+json.dumps(v) for k,v in s['labels'].items())+'}',
             'values':s['values']} for s in data]


def expected(name,labels,severity='critical'):
    definition=next(r for r in rules['groups'][-1]['rules'] if r['alert']==name)
    return {'exp_labels':{**E,**labels,'severity':severity,'team':'data-ha'},'exp_annotations':definition['annotations']}


tests=[]
def case(name,mutate,alert,labels=None,severity='critical'):
    data=copy.deepcopy(samples);mutate(data)
    tests.append({'name':name,'interval':'15s','input_series':inputs(data),
        'alert_rule_test':[{'eval_time':'5m','alertname':alert,'exp_alerts':[] if labels is None else [expected(alert,labels,severity)]}]})

tests.append({'name':'healthy-including-idle-wait-and-dlq','interval':'15s','input_series':inputs(samples),
    'promql_expr_test':[{'expr':'ALERTS{team="data-ha",alertstate="firing"}','eval_time':'5m','exp_samples':[]},
        {'expr':'doktori_ha:ready_nodes','eval_time':'5m','exp_samples':[
            {'labels':'doktori_ha:ready_nodes{'+','.join(k+'='+json.dumps(v) for k,v in {**E,'job':j,'service':s}.items())+'}','value':3 if j!='data-ha-alloy' else 1}
            for j,s in [('redis','redis'),('redis-sentinel','redis'),('rabbitmq','rabbitmq'),('rabbitmq-quorum','rabbitmq'),('mongodb','mongodb'),('data-ha-alloy','observability')]]}]})
tests.append({'name':'all-telemetry-disappears','interval':'15s','input_series':[],
    'alert_rule_test':[{'eval_time':'5m','alertname':'DataHATelemetryMissing',
        'exp_alerts':[expected('DataHATelemetryMissing',t) for t in inventory['targets']]}]})
case('scrape-down',lambda d:change(d,'up',0,job='redis',node='redis-b'),'DataHAScrapeFailed',{'job':'redis','node':'redis-b','service':'redis'})
case('source-auth-failure',lambda d:change(d,'mongodb_up',0,node='mongo-b'),'DataHASourceFailed',{'job':'mongodb','node':'mongo-b','service':'mongodb'})
case('missing-health-metric',lambda d:remove(d,'redis_up',job='redis',node='redis-b'),'DataHAEssentialMetricsMissing',{'job':'redis','node':'redis-b','service':'redis'})
case('missing-sentinel-state',lambda d:remove(d,'redis_sentinel_master_ckquorum_status',node='redis-b'),'DataHAStateMetricsMissing',{'job':'redis-sentinel','node':'redis-b','service':'redis'})
case('redis-zero-primary',lambda d:remove(d,'redis_instance_info',role='master'),'RedisPrimaryCount',{})
data=copy.deepcopy(samples)
for s in data:
    if s['metric']=='redis_instance_info' and s['labels']['node']=='redis-b':s['labels']['role']='master'
tests.append({'name':'redis-two-primaries','interval':'15s','input_series':inputs(data),
    'alert_rule_test':[{'eval_time':'5m','alertname':'RedisPrimaryCount','exp_alerts':[expected('RedisPrimaryCount',{})]}]})
case('sentinel-ckquorum-fails',lambda d:change(d,'redis_sentinel_master_ckquorum_status',0,node='redis-c'),'RedisSentinelQuorum',{'node':'redis-c'})
case('one-report-sees-queue-quorum-loss',lambda d:change(d,'doktori_rabbitmq_queue_online_members',1,node='rabbitmq-c',queue='notification.delivery.queue'),
    'RabbitMQQuorumLost',{'queue':'notification.delivery.queue','vhost':'/'})
case('two-online-still-majority',lambda d:change(d,'doktori_rabbitmq_queue_online_members',2,queue='notification.delivery.queue'),'RabbitMQQuorumLost')
case('two-online-redundancy-warning',lambda d:change(d,'doktori_rabbitmq_queue_online_members',2,queue='notification.delivery.queue'),
    'RabbitMQReplicaDegraded',{'queue':'notification.delivery.queue','vhost':'/'},'warning')
case('queue-not-declared',lambda d:change(d,'doktori_rabbitmq_queue_present',0,node='rabbitmq-a',queue='notification.delivery.queue'),
    'RabbitMQQueueMissing',{'job':'rabbitmq-quorum','node':'rabbitmq-a','service':'rabbitmq','queue':'notification.delivery.queue','vhost':'/'})
case('mongo-no-primary',lambda d:change(d,'mongodb_rs_myState',2,node='mongo-a'),'MongoDBPrimaryCount',{})
case('mongo-self-lag-seconds',lambda d:change(d,'mongodb_mongod_replset_member_replication_lag',9,node='mongo-c'),
    'MongoDBReplicationLag',{'node':'mongo-c'},'warning')
data=copy.deepcopy(samples)
for s in data:
    if s['metric']=='up' and s['labels']['node']=='redis-b' and s['labels']['job']=='redis':s['values']='1+0x4 _x36'
tests.append({'name':'remote-write-stale-without-up-zero','interval':'15s','input_series':inputs(data),
    'alert_rule_test':[{'eval_time':'5m','alertname':'DataHATelemetryMissing','exp_alerts':[expected('DataHATelemetryMissing',{'job':'redis','node':'redis-b','service':'redis'})]}]})
# Old unlabeled samples may remain in the lookback window during migration.
data=copy.deepcopy(samples)
for node in 'abc':data.append({'metric':'redis_up','labels':{'job':'redis','instance':'old-'+node},'values':'1+0x40'})
tests.append({'name':'legacy-series-do-not-break-joins','interval':'15s','input_series':inputs(data),
    'promql_expr_test':[{'expr':'doktori_ha:ready_nodes{job="redis"}','eval_time':'5m',
        'exp_samples':[{'labels':'doktori_ha:ready_nodes{env="local",cluster="doktori-local-data",job="redis",service="redis"}','value':3}]}]})

parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--image',default='prom/prometheus:v3.5.0');args=parser.parse_args()
endpoint=subprocess.check_output(['docker','context','inspect','desktop-linux','--format','{{.Endpoints.docker.Host}}'],text=True).strip()
assert endpoint=='npipe:////./pipe/dockerDesktopLinuxEngine'
with tempfile.TemporaryDirectory(prefix='doktori-ha-rules-') as folder:
    work=Path(folder)
    (work/'rules.yml').write_text(yaml.safe_dump(rules,sort_keys=False),encoding='utf-8')
    (work/'tests.yml').write_text(yaml.safe_dump({'rule_files':['rules.yml'],'evaluation_interval':'15s','tests':tests},sort_keys=False),encoding='utf-8')
    # Redis-only stage must ignore bad telemetry from unselected services.
    inv={**inventory,'targets':[t for t in inventory['targets'] if t['service']=='redis']}
    stage_rules,_=assets.assets(inv,'local-prom')
    (work/'stage-rules.yml').write_text(yaml.safe_dump(stage_rules,sort_keys=False),encoding='utf-8')
    bad=copy.deepcopy(samples);change(bad,'mongodb_rs_myState',2);change(bad,'doktori_rabbitmq_queue_online_members',0)
    stage_test={'name':'stage-one-ignores-not-selected-services','interval':'15s','input_series':inputs(bad),
        'promql_expr_test':[{'expr':'ALERTS{team="data-ha",alertstate="firing"}','eval_time':'5m','exp_samples':[]}]}
    (work/'stage-tests.yml').write_text(yaml.safe_dump({'rule_files':['stage-rules.yml'],'evaluation_interval':'15s','tests':[stage_test]},sort_keys=False),encoding='utf-8')
    subprocess.run(['docker','--context','desktop-linux','run','--rm','--network','none','--entrypoint','promtool',
        '-v',folder+':/checks:ro','-w','/checks',args.image,'test','rules','tests.yml','stage-tests.yml'],check=True)
print(json.dumps({'synthetic_rule_cases':len(tests)+1,'database_failures_injected':False}))
