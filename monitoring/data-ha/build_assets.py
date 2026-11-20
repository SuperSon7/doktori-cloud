"""Render an explicitly selected data HA inventory, rules and Grafana dashboard.

No Docker, AWS or Terraform calls. Requires PyYAML 6.x on the rendering host.
"""
import argparse
import json
from pathlib import Path
import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
KEYS = 'env,cluster,job,node'
SCOPE = 'cluster!="",node!=""'
JOBS = 'redis|redis-sentinel|rabbitmq|rabbitmq-quorum|mongodb|data-ha-alloy'


def assets(inventory, datasource):
    env, cluster = inventory['env'], inventory['cluster']
    targets = inventory['targets']
    assert targets and all(t['job'] in JOBS.split('|') and t['node'] and t['service'] for t in targets)
    assert len({(t['job'],t['node']) for t in targets}) == len(targets)
    expected = [{'record':'doktori_ha_expected_target','expr':'vector(1)',
                 'labels':{'env':env,'cluster':cluster,**t}} for t in targets]
    fresh = f'((timestamp(up{{{SCOPE},job=~"{JOBS}"}}) > time() - 60) and on({KEYS}) doktori_ha_expected_target)'
    ready = f'''max by (env,cluster,service,job,node) ((
      (up{{{SCOPE},job=~"redis|redis-sentinel"}} * on({KEYS}) group_left() redis_up{{{SCOPE}}})
      or (up{{{SCOPE},job=~"rabbitmq|data-ha-alloy"}})
      or (up{{{SCOPE},job="rabbitmq-quorum"}} * on({KEYS}) group_left() doktori_rabbitmq_probe_success{{{SCOPE}}})
      or (up{{{SCOPE},job="mongodb"}} * on({KEYS}) group_left() mongodb_up{{{SCOPE}}})
    ) and on({KEYS}) {fresh})'''
    recordings = [
        ('doktori_ha:target_ready',ready),
        ('doktori_ha:expected_nodes','sum by(env,cluster,service,job)(doktori_ha_expected_target)'),
        ('doktori_ha:ready_nodes','sum by(env,cluster,service,job)(doktori_ha:target_ready) or on(env,cluster,job) (doktori_ha:expected_nodes * 0)'),
        ('doktori_ha:redis_primary_count',f'sum by(env,cluster)(redis_instance_info{{{SCOPE},job="redis",role="master"}} and on({KEYS}) {fresh}) or on(env,cluster) (sum by(env,cluster)(doktori_ha_expected_target{{job="redis"}}) * 0)'),
        ('doktori_ha:redis_replicas',f'max by(env,cluster)(redis_connected_slaves{{{SCOPE},job="redis"}} and on({KEYS}) redis_instance_info{{role="master"}} and on({KEYS}) {fresh})'),
        ('doktori_ha:sentinel_quorum',f'min by(env,cluster,node)(redis_sentinel_master_ckquorum_status{{{SCOPE},job="redis-sentinel"}} and on({KEYS}) {fresh})'),
        ('doktori_ha:mq_online_members',f'min by(env,cluster,queue,vhost)(doktori_rabbitmq_queue_online_members{{{SCOPE}}} and on({KEYS}) {fresh})'),
        ('doktori_ha:mq_required_majority',f'max by(env,cluster,queue,vhost)(doktori_rabbitmq_queue_required_majority{{{SCOPE}}} and on({KEYS}) {fresh})'),
        ('doktori_ha:mongo_primary_count',f'sum by(env,cluster)((mongodb_rs_myState{{{SCOPE},job="mongodb"}} == bool 1) and on({KEYS}) {fresh}) or on(env,cluster) (sum by(env,cluster)(doktori_ha_expected_target{{job="mongodb"}}) * 0)'),
        ('doktori_ha:mongo_data_members',f'count by(env,cluster)((mongodb_rs_myState{{{SCOPE},job="mongodb"}} == 1 or mongodb_rs_myState{{{SCOPE},job="mongodb"}} == 2) and on({KEYS}) {fresh}) or on(env,cluster) (sum by(env,cluster)(doktori_ha_expected_target{{job="mongodb"}}) * 0)'),
        ('doktori_ha:mongo_lag_seconds',f'max by(env,cluster,node)(mongodb_mongod_replset_member_replication_lag{{{SCOPE},self="1"}} and on({KEYS}) {fresh})'),
    ]
    definitions = [
        ('DataHARuleEvaluationFailure','increase(prometheus_rule_evaluation_failures_total[5m]) > 0','1m','critical','Prometheus rule evaluation is failing; dashboard recordings may be stale'),
        ('DataHALogDeliveryErrors',f'rate(loki_write_dropped_entries_total{{{SCOPE},job="data-ha-alloy"}}[5m]) > 0 or rate(loki_write_batch_retries_total{{{SCOPE},job="data-ha-alloy"}}[5m]) > 0','2m','warning','Alloy log delivery is retrying or dropping entries'),
        ('DataHAMetricDeliveryErrors',f'rate(prometheus_remote_storage_samples_failed_total{{{SCOPE},job="data-ha-alloy"}}[5m]) > 0','2m','critical','Alloy remote_write reports failed samples'),
        ('DataHATelemetryMissing',f'doktori_ha_expected_target unless on({KEYS}) {fresh}','1m','critical','Expected target has no fresh scrape sample'),
        ('DataHAScrapeFailed',f'(up{{{SCOPE},job=~"{JOBS}"}} == 0) and on({KEYS}) doktori_ha_expected_target','1m','critical','Exporter endpoint cannot be scraped'),
        ('DataHASourceFailed','doktori_ha:target_ready == 0','1m','critical','Exporter is reachable but its data source is not healthy'),
        ('DataHAEssentialMetricsMissing',f'(doktori_ha_expected_target unless on({KEYS}) doktori_ha:target_ready) and on({KEYS}) (up == 1)','1m','critical','Scrape succeeds but required source metrics are missing'),
        ('DataHAStateMetricsMissing',f'''((doktori_ha_expected_target{{job="redis"}} unless on({KEYS}) redis_instance_info{{{SCOPE}}})
          or (doktori_ha_expected_target{{job="redis-sentinel"}} unless on({KEYS}) redis_sentinel_master_ckquorum_status{{{SCOPE}}})
          or (doktori_ha_expected_target{{job="mongodb"}} unless on({KEYS}) mongodb_rs_myState{{{SCOPE}}})) and on({KEYS}) (up == 1)''','1m','critical','Required replication state is absent although exporter responds'),
        ('RedisPrimaryCount','doktori_ha:redis_primary_count != 1','1m','critical','Redis observed primary count differs from one'),
        ('RedisReplicaDegraded','doktori_ha:redis_replicas < 2','2m','warning','Redis has fewer than two connected replicas'),
        ('RedisReplicaWriteGate','doktori_ha:redis_replicas < 1','1m','critical','Redis min-replicas-to-write gate may reject writes'),
        ('RedisReplicaLinkDown',f'redis_master_link_up{{{SCOPE},job="redis"}} == 0','1m','critical','Redis replica lost its primary link'),
        ('RedisReplicaLag',f'redis_connected_slave_lag_seconds{{{SCOPE},job="redis"}} > 5','2m','warning','Redis replica ACK lag exceeds draft threshold'),
        ('RedisSentinelQuorum','doktori_ha:sentinel_quorum == 0','1m','critical','Sentinel CKQUORUM reports failure'),
        ('RedisSentinelDisagreement',f'count by(env,cluster)(count by(env,cluster,master_address)(redis_sentinel_master_status{{{SCOPE},master_status="ok"}})) > 1','1m','critical','Sentinels report different primary addresses'),
        ('RedisAOFWriteError',f'redis_aof_last_write_status{{{SCOPE}}} == 0','1m','critical','Redis AOF reports an unsuccessful write'),
        ('RabbitMQQuorumLost','doktori_ha:mq_online_members < on(env,cluster,queue,vhost) doktori_ha:mq_required_majority','1m','critical','Observed queue online members are below configured majority'),
        ('RabbitMQReplicaDegraded','doktori_ha:mq_online_members < 3','2m','warning','Queue has fewer than three online members'),
        ('RabbitMQQueueMissing',f'doktori_rabbitmq_queue_present{{{SCOPE}}} == 0','1m','critical','An explicitly monitored application queue is missing'),
        ('RabbitMQQueueNotQuorum',f'doktori_rabbitmq_queue_is_quorum{{{SCOPE}}} == 0','1m','critical','Application queue is not quorum type'),
        ('RabbitMQLeaderMissing',f'doktori_rabbitmq_queue_leader_present{{{SCOPE}}} == 0','1m','critical','Queue has no observed online leader'),
        ('RabbitMQPartition',f'doktori_rabbitmq_partition_reports{{{SCOPE}}} > 0','1m','critical','Management API reports a partition'),
        ('RabbitMQResourceAlarm',f'rabbitmq_alarms_memory_used_watermark{{{SCOPE}}} > 0 or rabbitmq_alarms_free_disk_space_watermark{{{SCOPE}}} > 0','1m','critical','RabbitMQ resource alarm can block publishers'),
        ('RabbitMQNoConsumers',f'(rabbitmq_queue_consumers{{{SCOPE},queue="notification.delivery.queue"}} == 0) and on(env,cluster,queue,vhost) (rabbitmq_queue_messages_ready > 0)','2m','warning','Delivery backlog exists without consumers'),
        ('RabbitMQDeadLetters',f'rabbitmq_queue_messages_ready{{{SCOPE},queue="notification.delivery.dlq"}} > 0','2m','warning','Dead-letter queue contains messages; inspect without consuming'),
        ('MongoDBPrimaryCount','doktori_ha:mongo_primary_count != 1','1m','critical','MongoDB observed primary count differs from one'),
        ('MongoDBDataMemberDegraded','doktori_ha:mongo_data_members < 3','2m','warning','Fewer than three members report primary/secondary state'),
        ('MongoDBDataMajorityLost','doktori_ha:mongo_data_members < 2','1m','critical','Fewer than two members report usable data-bearing state'),
        ('MongoDBReplicationLag','doktori_ha:mongo_lag_seconds > 5','2m','warning','MongoDB self-member replication lag exceeds draft threshold'),
    ]
    # Raw exporters of services not selected in this stage must not page.
    definitions = [(name,('('+expr+') and on(env,cluster) count by(env,cluster)(doktori_ha_expected_target{service="'+service+'"})'
                    if (service := next((s for prefix,s in [('Redis','redis'),('RabbitMQ','rabbitmq'),('MongoDB','mongodb')] if name.startswith(prefix)),None)) else expr),
                    duration,severity,summary) for name,expr,duration,severity,summary in definitions]
    alerts = [{'alert':name,'expr':expr,'for':duration,'labels':{'severity':severity,'team':'data-ha'},
               'annotations':{'summary':summary,'runbook_path':'runbooks/alerting/data-ha.md'}}
              for name,expr,duration,severity,summary in definitions]
    for alert in alerts:
        if alert['alert']=='DataHARuleEvaluationFailure':alert['labels'].update(env=env,cluster=cluster)
    rules = {'groups':[{'name':'data-ha-inventory','interval':'15s','rules':expected},
                       {'name':'data-ha-recording','interval':'15s','rules':[{'record':n,'expr':e} for n,e in recordings]},
                       {'name':'data-ha-alerts','interval':'15s','rules':alerts}]}
    selector = '{env=~"$env",cluster=~"$cluster"'
    def metric(name, extra=''): return name+selector+extra+'}'
    panels=[]
    def panel(title,query,unit='short',description='',stat=False):
        index=len(panels)
        panels.append({'id':index+1,'title':title,'description':description,'type':'stat' if stat else 'timeseries',
          'datasource':{'type':'prometheus','uid':datasource},'gridPos':{'x':(index%2)*12,'y':(index//2)*7+(3 if index>=2 else 0),'w':12,'h':10 if index<2 else 7},
          'targets':[{'refId':'A','expr':query,'legendFormat':('관측값' if any(s in query for s in ['redis_primary_count','redis_replicas','mongo_primary_count','mongo_data_members']) else '{{node}} {{queue}}')}],
          'fieldConfig':{'defaults':{'unit':unit,'noValue':'데이터 없음','custom':{'drawStyle':'line'}},'overrides':[]},
          'options':{'legend':{'displayMode':'list','placement':'bottom'},'tooltip':{'mode':'multi'}}})
    panel('수집 상태: 준비된 대상 수',metric('doktori_ha:ready_nodes'),description='응답·인증과 60초 이내 수집을 함께 본다. 전체 프로세스 중단은 아래 경보에서 확인한다.')
    panel('기대 대상 수',metric('doktori_ha:expected_nodes'),description='배포할 단계에 맞춰 별도 inventory를 렌더한다. 지표가 사라져도 기대 수는 남는다.')
    for item in panels[:2]:
        item['type']='table';item['targets'][0].update(format='table',instant=True)
        item['transformations']=[{'id':'filterFieldsByName','options':{'include':{'names':['job','service','Value']}}},
                                {'id':'sortBy','options':{'fields':[{'field':'job','desc':False}]}}]
        item['options']={'showHeader':True,'cellHeight':'sm'}
    panel('경보 발생 이력', 'count by(alertname,severity)(ALERTS'+selector+',alertstate="firing",team="data-ha"})',description='현재 firing만 조회할 때 0건은 빈 결과다. 수집·룰 로드 정상 여부와 함께 확인한다.')
    panels[-1]['targets'][0]['legendFormat']='{{alertname}} {{severity}}'
    panel('수집 시계열 나이', 'time() - timestamp(up'+selector+',job=~"'+JOBS+'"})','s')
    panels[-1]['targets'][0]['legendFormat']='{{job}} / {{node}}'
    panel('Redis primary 수',metric('doktori_ha:redis_primary_count'),description='정상 목표 1. 초기 role 라벨을 사용하지 않고 실제 INFO 역할을 집계한다.')
    panel('Redis 연결 replica 수',metric('doktori_ha:redis_replicas'),description='목표 2. 현재 min-replicas-to-write=1 설정과 함께 해석한다.')
    panel('Sentinel CKQUORUM',metric('doktori_ha:sentinel_quorum'),description='1 성공·0 실패. 성공이 데이터 무유실이나 복원을 보장하지 않는다.')
    panel('Redis replica ACK 지연',metric('redis_connected_slave_lag_seconds'),'s')
    panel('MQ 큐별 온라인 멤버: 보수적 최소',metric('doktori_ha:mq_online_members'),description='각 관리 API의 관측을 합산하지 않는다. 현재 목표 3, 과반 2. API 실패는 별도 경보다.')
    panel('MQ 큐별 실제 요구 과반',metric('doktori_ha:mq_required_majority'))
    panel('MQ Ready backlog',metric('rabbitmq_queue_messages_ready'))
    panel('MQ Unacked',metric('rabbitmq_queue_messages_unacked'))
    panel('MQ consumers',metric('rabbitmq_queue_consumers'),description='wait/DLQ 소비자 0은 설계상 가능하다. 본 큐 backlog가 있을 때만 무소비자 경보를 낸다.')
    panel('MQ 관리 API 수집 성공',metric('doktori_rabbitmq_probe_success'))
    panel('MongoDB primary 수',metric('doktori_ha:mongo_primary_count'),description='각 exporter의 myState만 집계해 전체 set 반복 보고의 중복을 피한다. 목표 1.')
    panel('MongoDB 정상 data member 수',metric('doktori_ha:mongo_data_members'),description='현재 3 voting data-bearing P-S-S 전용. 임의 arbiter/hidden 구성으로 일반화하지 않는다.')
    panel('MongoDB self-member replication lag',metric('doktori_ha:mongo_lag_seconds'),'s')
    panel('MongoDB 현재 연결 수',metric('mongodb_ss_connections',',conn_type="current"'))
    panel('Alloy 로그 전송량', 'sum by(node)(rate('+metric('loki_write_sent_entries_total',',job="data-ha-alloy"')+'[5m]))','ops')
    panel('Alloy remote_write 대기 sample', 'sum by(node)('+metric('prometheus_remote_storage_samples_pending',',job="data-ha-alloy"')+')')
    panels.append({'id':len(panels)+1,'title':'데이터 서비스 로그','description':'서비스·노드 라벨로 연결한다. 메시지 본문을 추가로 수집하는 계측은 하지 않는다.',
        'type':'logs','datasource':{'type':'loki','uid':'local-loki' if datasource=='local-prom' else 'loki'},
        'gridPos':{'x':0,'y':73,'w':24,'h':12},
        'targets':[{'refId':'A','expr':'{env=~"$env",cluster=~"$cluster",service=~"redis|rabbitmq|mongodb"}'}],
        'options':{'showLabels':True,'showTime':True,'sortOrder':'Descending','wrapLogMessage':True}})
    dashboard={'uid':'doktori-data-ha','title':'독토리 데이터 HA 상태','schemaVersion':39,'version':1,'refresh':'15s',
      'time':{'from':'now-30m','to':'now'},'timezone':'browser','panels':panels,
      'templating':{'list':[{'name':'env','type':'query','datasource':{'uid':datasource,'type':'prometheus'},
          'query':'label_values(doktori_ha_expected_target,env)','refresh':1,'sort':1},
        {'name':'cluster','type':'query','datasource':{'uid':datasource,'type':'prometheus'},
          'query':'label_values(doktori_ha_expected_target{env=~"$env"},cluster)','refresh':1,'sort':1}]}}
    return rules,dashboard


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--datasource',default='prometheus')
    parser.add_argument('--native',action='store_true')
    args=parser.parse_args()
    inventory=json.loads(args.inventory.read_text(encoding='utf-8'))
    rules,dashboard=assets(inventory,args.datasource)
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'rules.yml').write_text(yaml.safe_dump(rules,allow_unicode=True,sort_keys=False),encoding='utf-8')
    (args.output/'dashboard.json').write_text(json.dumps(dashboard,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    if args.native:
        config=yaml.safe_load((ROOT/'monitoring/prometheus/prometheus.yml').read_text(encoding='utf-8'))
        config['rule_files'].append('/etc/prometheus/data-ha/rules.yml')
        config['alerting']={'alertmanagers':[{'static_configs':[{'targets':['data-ha-alertmanager:9093']}]}]}
        (args.output/'prometheus.yml').write_text(yaml.safe_dump(config,sort_keys=False),encoding='utf-8')
    print(json.dumps({'targets':len(inventory['targets']),'alerts':len(rules['groups'][2]['rules']),'panels':len(dashboard['panels'])}))


if __name__=='__main__': main()
