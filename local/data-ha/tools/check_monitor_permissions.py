"""Exercise monitor denials using one disposable queue owned by this check."""
import base64
import json
import os
import urllib.error
import urllib.request
import uuid
import pika

queue='doktori.visibility.permission.'+uuid.uuid4().hex
path='queues/%2F/'+queue
def api(method,monitor=False,body=None):
    prefix='RABBITMQ_MONITOR_' if monitor else 'RABBITMQ_'
    token=base64.b64encode((os.environ[prefix+'USER']+':'+os.environ[prefix+'PASSWORD']).encode()).decode()
    req=urllib.request.Request('http://rabbitmq-a:15672/api/'+path,method=method,
        data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Basic '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=10) as r:r.read()

definition={'durable':True,'auto_delete':False,'arguments':{'x-queue-type':'classic'}}
api('PUT',body=definition)
try:
    try:
        api('PUT',monitor=True,body=definition)
        raise AssertionError('Monitor unexpectedly has queue configuration permission')
    except urllib.error.HTTPError as e:assert e.code in (401,403)
    result={}
    for action in ('publish','get'):
        connection=pika.BlockingConnection(pika.ConnectionParameters('rabbitmq-a',credentials=pika.PlainCredentials(
            os.environ['RABBITMQ_MONITOR_USER'],os.environ['RABBITMQ_MONITOR_PASSWORD'])))
        try:
            channel=connection.channel();channel.confirm_delivery()
            try:
                if action=='publish':channel.basic_publish('',queue,b'local-permission-test')
                else:channel.basic_get(queue,auto_ack=False)
                raise AssertionError('Monitor unexpectedly allowed '+action)
            except pika.exceptions.ChannelClosedByBroker as error:
                assert error.reply_code==403
                result[action+'_denied']=True
        finally:
            if connection.is_open:connection.close()
    print(json.dumps({'queue_configuration_denied':True,**result,'scope':'disposable owned classic queue; no application messages touched'}))
finally:
    api('DELETE')
