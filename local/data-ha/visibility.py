"""Verify this local observability path. Optional synthetic delivery stays local."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request
import uuid

ROOT=Path(__file__).resolve().parent

def request(url,body=None,headers=None):
    raw=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(url,data=raw,headers={'Content-Type':'application/json',**(headers or {})})
    with urllib.request.urlopen(req,timeout=15) as response:return json.load(response)

def query(expression):
    result=request('http://127.0.0.1:19090/api/v1/query?query='+urllib.parse.quote(expression))
    assert result['status']=='success', expression
    return result['data']['result']

def verify(delivery=False):
    runtime=ROOT/'.runtime'
    inventory=json.loads((runtime/'inventory.json' if (runtime/'inventory.json').exists() else ROOT/'observability/inventory.json').read_text())
    expected={}
    for t in inventory['targets']:expected[t['job']]=expected.get(t['job'],0)+1
    data=query('doktori_ha:ready_nodes{env="local",cluster="doktori-local-data"}')
    actual={r['metric']['job']:int(float(r['value'][1])) for r in data}
    assert actual==expected, {'expected':expected,'actual':actual}
    groups=request('http://127.0.0.1:19090/api/v1/rules')['data']['groups']
    assert all(r['health']=='ok' for g in groups for r in g['rules']), 'Rule evaluation error'
    firing=query('ALERTS{team="data-ha",alertstate="firing",env="local",cluster="doktori-local-data"}')
    assert not firing, 'Unexpected firing alerts: '+str([a['metric']['alertname'] for a in firing])
    metrics={
        'redis':['doktori_ha:redis_primary_count','doktori_ha:sentinel_quorum'],
        'rabbitmq':['doktori_ha:mq_online_members','doktori_rabbitmq_probe_success'],
        'mongodb':['doktori_ha:mongo_primary_count','doktori_ha:mongo_data_members','doktori_ha:mongo_lag_seconds']}
    results={}
    for service,expressions in metrics.items():
        if service not in expected:continue
        for expression in expressions:
            rows=query(expression+'{env="local",cluster="doktori-local-data"}')
            assert rows,expression
            results[expression]=[{'labels':r['metric'],'value':float(r['value'][1])} for r in rows]
    for service in ('redis','rabbitmq','mongodb'):
        if service not in expected:continue
        params={'query':'{env="local",cluster="doktori-local-data",service="'+service+'"}',
                'start':int((time.time()-1800)*1e9),'end':int(time.time()*1e9),'limit':1}
        logs=request('http://127.0.0.1:13100/loki/api/v1/query_range?'+urllib.parse.urlencode(params))
        assert logs['data']['result'],'No Loki log entries for '+service
    values=dict(line.split('=',1) for line in (runtime/'.env').read_text().splitlines() if '=' in line)
    auth=base64.b64encode(('lab:'+values['GRAFANA_PASSWORD']).encode()).decode()
    headers={'Authorization':'Basic '+auth}
    dashboard=request('http://127.0.0.1:13000/api/dashboards/uid/doktori-data-ha',headers=headers)['dashboard']
    assert len(dashboard['panels'])>=19
    datasources=request('http://127.0.0.1:13000/api/datasources',headers=headers)
    assert {'local-prom','local-loki'} <= {d['uid'] for d in datasources}
    report={'checked_at':datetime.now(timezone.utc).isoformat(),'expected_and_ready':actual,
            'queries':results,'rules':sum(len(g['rules']) for g in groups),'rule_errors':0,'firing_alerts':0,
            'log_services':[s for s in ('redis','rabbitmq','mongodb') if s in expected],
            'grafana':{'uid':dashboard['uid'],'panels':len(dashboard['panels']),'datasources':['local-prom','local-loki']},
            'scope':'local metrics/logs/alerts only; no failover, message delivery or EC2 bootstrap test'}
    if delivery:
        token=uuid.uuid4().hex;now=datetime.now(timezone.utc)
        labels={'alertname':'HAObservabilityDeliveryTest','env':'local','cluster':'doktori-local-data','test_id':token,'severity':'info'}
        alert={'labels':labels,'startsAt':now.isoformat(),'endsAt':(now+timedelta(seconds=10)).isoformat()}
        # Alertmanager v2 accepts an empty response body.
        def send(alert):
            req=urllib.request.Request('http://127.0.0.1:19093/api/v2/alerts',data=json.dumps([alert]).encode(),headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=5) as response:response.read()
        def seen(state):
            for _ in range(40):
                events=request('http://127.0.0.1:18081/events')
                if any(a['labels'].get('test_id')==token and a['status']==state for e in events for a in e['alerts']):return True
                time.sleep(1)
            return False
        send(alert);assert seen('firing'),'Local firing webhook not observed'
        # A finite TTL also cleans up the test alert if the verifier is interrupted.
        assert seen('resolved'),'Local resolved webhook not observed'
        report['synthetic_alert_delivery']={'firing':True,'resolved':True,'receiver':'local in-memory evidence sink; no external notification'}
    (runtime/'visibility-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--delivery-test',action='store_true');args=parser.parse_args()
    verify(args.delivery_test)
