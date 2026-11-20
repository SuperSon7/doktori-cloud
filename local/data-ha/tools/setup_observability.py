"""Create the local monitor identity; never touch queues or messages."""
import base64
import json
import os
import urllib.parse
import urllib.request

token=base64.b64encode((os.environ['RABBITMQ_USER']+':'+os.environ['RABBITMQ_PASSWORD']).encode()).decode()
user=urllib.parse.quote(os.environ['RABBITMQ_MONITOR_USER'],safe='')
for path, body in [
    ('users/'+user,{'password':os.environ['RABBITMQ_MONITOR_PASSWORD'],'tags':'monitoring'}),
    ('permissions/%2F/'+user,{'configure':'','write':'','read':''})]:
    request=urllib.request.Request('http://rabbitmq-a:15672/api/'+path,
        data=json.dumps(body).encode(),method='PUT',headers={'Authorization':'Basic '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(request,timeout=10) as response: response.read()
print('Configured monitor tag and empty AMQP permission expressions; no queue/message operations')
