"""Local-only Alertmanager evidence sink. No outgoing requests or human messages."""
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time

events = deque(maxlen=100)
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != '/alerts':
            self.send_error(404); return
        length = int(self.headers.get('Content-Length', '0'))
        if length > 65536:
            self.send_error(413); return
        data = json.loads(self.rfile.read(length))
        # Keep labels and delivery state, never request headers or metric payloads.
        with lock:
            events.append({'received_at': time.time(), 'status': data['status'],
                           'alerts': [{'status': a['status'], 'labels': a['labels']} for a in data['alerts']]})
        self.send_response(200); self.end_headers()

    def do_GET(self):
        if self.path != '/events':
            self.send_error(404); return
        with lock: body = json.dumps(list(events)).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)

    def log_message(self, *args): pass

ThreadingHTTPServer(('0.0.0.0',8081),Handler).serve_forever()
