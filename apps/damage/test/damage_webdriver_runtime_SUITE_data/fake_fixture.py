#!/usr/bin/env python3
"""HTTP child for OTP lifecycle tests. Not Selenium, Appium or the dashboard."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == '/health' else 404)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"fixture":true,"ready":true}')
    def log_message(self, *_):
        pass

p = argparse.ArgumentParser()
p.add_argument('--bind', default='127.0.0.1')
p.add_argument('--port', type=int, required=True)
a = p.parse_args()
print('OTP lifecycle fixture started', flush=True)
ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()
