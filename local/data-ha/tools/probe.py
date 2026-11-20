"""Local readiness/protocol smoke checks, not failover or application E2E tests."""
import argparse
import base64
import json
import os
import time
import urllib.request
import uuid
from datetime import datetime, timezone

parser = argparse.ArgumentParser()
parser.add_argument('stage', choices=['redis', 'rabbitmq', 'mongodb'])
parser.add_argument('--configure', action='store_true')
args = parser.parse_args()

def eventually(action, seconds=150):
    end = time.monotonic() + seconds
    while True:
        try:
            return action()
        except Exception as error:
            if time.monotonic() > end:
                raise RuntimeError(f'Readiness deadline: {type(error).__name__}: {error}') from error
            time.sleep(2)

def redis_check():
    import redis
    from redis.sentinel import Sentinel
    password = os.environ['REDIS_PASSWORD']
    sentinel = Sentinel([(f'sentinel-{n}',26379) for n in 'abc'],
        sentinel_kwargs={'password':password,'socket_timeout':3}, password=password, socket_timeout=3)
    def ready():
        primary = sentinel.master_for('doktori-master', decode_responses=True)
        replication = primary.info('replication')
        assert replication['connected_slaves'] == 2, replication
        return primary
    primary = eventually(ready)
    statuses = []
    for name in 'abc':
        node = redis.Redis(host=f'sentinel-{name}',port=26379,password=password,decode_responses=True,socket_timeout=3)
        assert str(node.execute_command('SENTINEL','CKQUORUM','doktori-master')).startswith('OK')
        statuses.append({'node':f'sentinel-{name}','master':node.sentinel_get_master_addr_by_name('doktori-master')})
    key = 'doktori:ha:smoke:' + uuid.uuid4().hex
    assert primary.set(key,'ready',ex=60)
    replicated = primary.wait(2,5000)
    assert replicated == 2, f'WAIT replicas={replicated}'
    replicas = []
    versions = set()
    for name in 'abc':
        node = redis.Redis(host=f'redis-{name}',password=password,decode_responses=True,socket_timeout=3)
        assert node.get(key) == 'ready'
        role = node.info('replication')
        versions.add(node.info('server')['redis_version'])
        replicas.append({'node':f'redis-{name}','role':role['role'],'link':role.get('master_link_status')})
    return {'server_versions':sorted(versions),'nodes':replicas,'sentinels':statuses,'write_read':True,
            'wait_replicas':replicated,'note':'TTL smoke key; no failover/durability claim'}

def rabbit_check():
    import pika
    user, password = os.environ['RABBITMQ_USER'], os.environ['RABBITMQ_PASSWORD']
    token = base64.b64encode(f'{user}:{password}'.encode()).decode()
    def api(path, method='GET', body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request('http://rabbitmq-a:15672/api/'+path,data=data,method=method,
            headers={'Authorization':'Basic '+token,'Content-Type':'application/json'})
        with urllib.request.urlopen(request,timeout=10) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    def ready():
        nodes = api('nodes')
        assert len(nodes)==3 and all(n.get('running') for n in nodes), 'Need three running brokers'
        return nodes
    nodes = eventually(ready)
    if args.configure:
        api('exchanges/%2F/notification.exchange','PUT',{'type':'direct','durable':True,'auto_delete':False,'internal':False,'arguments':{}})
        queues = {
            'notification.delivery.queue':{'x-message-ttl':600000,'x-dead-letter-exchange':'','x-dead-letter-routing-key':'notification.delivery.dlq'},
            'notification.delivery.wait.v2':{'x-dead-letter-exchange':'notification.exchange','x-dead-letter-routing-key':'notification.delivery'},
            'notification.delivery.dlq':{}}
        for name, arguments in queues.items():
            api('queues/%2F/'+name,'PUT',{'durable':True,'auto_delete':False,'arguments':{'x-queue-type':'quorum',**arguments}})
        api('bindings/%2F/e/notification.exchange/q/notification.delivery.queue','POST',{'routing_key':'notification.delivery','arguments':{}})
        api('policies/%2F/doktori-safe-dlx','PUT',{'pattern':r'^notification\.delivery\.(queue|wait\.v2)$',
            'apply-to':'quorum_queues','priority':10,'definition':{'dead-letter-strategy':'at-least-once','overflow':'reject-publish','delivery-limit':20}})
    def queues_ready():
        result=[]
        for name in ['notification.delivery.queue','notification.delivery.wait.v2','notification.delivery.dlq']:
            queue=api('queues/%2F/'+name)
            assert queue['type']=='quorum' and len(queue.get('members',[]))==3 and len(queue.get('online',[]))==3, queue
            result.append({key:queue[key] for key in ['name','type','members','online']})
        return result
    queues=eventually(queues_ready)
    connection=pika.BlockingConnection(pika.ConnectionParameters(host='rabbitmq-a',credentials=pika.PlainCredentials(user,password),blocked_connection_timeout=10,socket_timeout=10))
    try:
        channel=connection.channel()
        name='doktori.ha.smoke.'+uuid.uuid4().hex
        channel.queue_declare(queue=name,durable=True,arguments={'x-queue-type':'quorum'})
        channel.confirm_delivery()
        channel.basic_publish('',name,b'ready',mandatory=True,properties=pika.BasicProperties(delivery_mode=2))
        def receive():
            method,properties,body=channel.basic_get(name,auto_ack=False)
            assert method is not None and body==b'ready'
            channel.basic_ack(method.delivery_tag)
        eventually(receive,20)
        def drained():
            remaining=channel.queue_declare(queue=name,passive=True).method
            assert remaining.message_count==0 and remaining.consumer_count==0
        eventually(drained,20)
        channel.queue_delete(queue=name)
    finally:
        if connection.is_open:
            connection.close()
    return {'server_versions':[api('overview')['rabbitmq_version']],
            'running_nodes':[n['name'] for n in nodes],'queues':queues,'amqp_confirm_manual_ack':True,
            'note':'Own empty smoke queue removed; no app queues/messages consumed'}

def mongo_check():
    from pymongo import MongoClient, WriteConcern
    user,password=os.environ['MONGO_ADMIN_USERNAME'],os.environ['MONGO_ADMIN_PASSWORD']
    client=MongoClient(['mongo-a:27017','mongo-b:27017','mongo-c:27017'],replicaSet='doktori-rs',
        username=user,password=password,authSource='admin',serverSelectionTimeoutMS=5000)
    def ready():
        status=client.admin.command('replSetGetStatus')
        assert len(status['members'])==3 and sorted(m['state'] for m in status['members'])==[1,2,2]
        return status
    status=eventually(ready)
    if args.configure:
        for username,pwd,roles in [
            ('doktori',os.environ['MONGO_PASSWORD'],[{'role':'readWrite','db':'doktoridb'}]),
            ('monitor',os.environ['MONGO_MONITOR_PASSWORD'],[{'role':'clusterMonitor','db':'admin'},{'role':'read','db':'local'}])]:
            if not client.admin.command('usersInfo',username)['users']:
                client.admin.command('createUser',username,pwd=pwd,roles=roles)
    app=MongoClient(['mongo-a:27017','mongo-b:27017','mongo-c:27017'],replicaSet='doktori-rs',
        username='doktori',password=os.environ['MONGO_PASSWORD'],authSource='admin',
        w='majority',journal=True,wTimeoutMS=5000,serverSelectionTimeoutMS=10000,retryWrites=True)
    collection=app.doktoridb.messages
    collection.create_index([('roomId',1),('senderId',1),('clientMessageId',1)],unique=True,name='uk_room_sender_client')
    collection.create_index([('roomId',1)],name='idx_room_id')
    collection.create_index([('roundId',1)],name='idx_round_id')
    for field in ['userId','sessionId','meetingId']:
        app.doktoridb.user_behavior_logs.create_index([(field,1),('sentAt',-1)],name={'userId':'idx_user_sent_at','sessionId':'idx_session_sent_at','meetingId':'idx_meeting_sent_at'}[field])
    smoke=app.doktoridb.get_collection('ha_smoke',write_concern=WriteConcern(w='majority',j=True,wtimeout=5000))
    key=uuid.uuid4().hex
    assert smoke.insert_one({'_id':key,'kind':'local-readiness'}).acknowledged
    assert smoke.find_one({'_id':key}) is not None
    assert smoke.delete_one({'_id':key}).deleted_count==1
    return {'server_version':client.server_info()['version'],'set':status['set'],
            'members':[{'name':m['name'],'state':m['stateStr'],'health':m['health']} for m in status['members']],
            'majority_journal_write_read':True,'indexes':list(collection.index_information()),
            'note':'No election, unknown-result retry, restore, or application E2E tested'}

result={'stage':args.stage,'time':datetime.now(timezone.utc).isoformat(),
        'checks':{'redis':redis_check,'rabbitmq':rabbit_check,'mongodb':mongo_check}[args.stage]()}
print(json.dumps(result,ensure_ascii=False))
