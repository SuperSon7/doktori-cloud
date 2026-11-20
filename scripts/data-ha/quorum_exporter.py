"""Bounded RabbitMQ status collector: GET only, three explicitly selected queues.

No message payloads, AMQP connections, declarations, publishing or acknowledgments.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import threading
import time
import urllib.parse
import urllib.request

QUEUES = ('notification.delivery.queue', 'notification.delivery.wait.v2', 'notification.delivery.dlq')


def sample(get):
    nodes = get('nodes')
    rows = []
    for queue in QUEUES:
        try:
            data = get('queues/%2F/' + urllib.parse.quote(queue, safe=''))
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            rows.append((queue, {'present': 0}))
            continue
        members = data.get('members', [])
        online = data.get('online')
        # Omitted membership is unknown, never a healthy zero/default majority.
        quorum = data.get('type') == 'quorum'
        row = {'present': 1, 'is_quorum': int(quorum)}
        if quorum:
            if not members or not isinstance(online, list):
                raise ValueError('Quorum membership unavailable')
            row.update(members=len(members), online_members=len(set(online) & set(members)),
                       required_majority=len(members) // 2 + 1,
                       leader_present=int(bool(data.get('leader')) and data['leader'] in online))
        rows.append((queue, row))
    output = [('doktori_rabbitmq_running_nodes', {}, sum(bool(n.get('running')) for n in nodes)),
              ('doktori_rabbitmq_partition_reports', {}, sum(len(n.get('partitions', [])) for n in nodes))]
    for queue, values in rows:
        output.extend(('doktori_rabbitmq_queue_' + name, {'queue': queue, 'vhost': '/'}, value)
                      for name, value in values.items())
    return output


def exposition(rows):
    return ''.join(name + ('{' + ','.join(k+'='+json.dumps(str(v)) for k,v in sorted(labels.items()))+'}' if labels else '')
                   + ' ' + str(value) + '\n' for name, labels, value in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text()) if args.config else {
        'url': os.environ['RABBITMQ_API_URL'], 'username': os.environ['RABBITMQ_MONITOR_USER'],
        'password': os.environ['RABBITMQ_MONITOR_PASSWORD'], 'listen': '0.0.0.0', 'port': 9419}
    token = base64.b64encode((config['username']+':'+config['password']).encode()).decode()
    lock = threading.Lock()
    state = {'last_success': 0}

    def get(path):
        request = urllib.request.Request(config['url'].rstrip('/')+'/api/'+path,
                                         headers={'Authorization': 'Basic '+token})
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.load(response)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/metrics':
                self.send_error(404)
                return
            start = time.monotonic()
            with lock:
                try:
                    rows = sample(get)
                    success = 1
                    state['last_success'] = time.time()
                except Exception:
                    # No response bodies, URLs with secrets, exception strings or stale samples.
                    rows, success = [], 0
                rows += [('doktori_rabbitmq_probe_success', {}, success),
                         ('doktori_rabbitmq_probe_last_success_timestamp_seconds', {}, state['last_success']),
                         ('doktori_rabbitmq_probe_duration_seconds', {}, time.monotonic()-start)]
            body = exposition(rows).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    ThreadingHTTPServer((config.get('listen', '127.0.0.1'), config.get('port', 9419)), Handler).serve_forever()


if __name__ == '__main__':
    main()
