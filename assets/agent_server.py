#!/usr/bin/env python3
# agent_server.py — fallback minimo v7.0
import os, sys, json, socketserver, http.server, urllib.request

PORT = int(os.environ.get('AGENT_PORT', '8765'))
BASE_URL = os.environ.get('LLM_BASE_URL', 'http://127.0.0.1:8090/v1')
MODEL = os.environ.get('LLM_MODEL', 'gemma3-local')
API_KEY = os.environ.get('LLM_API_KEY', 'local')

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'[agent] {fmt % args}')

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'ok')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path == '/v1/chat/completions':
            content_len = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_len)
            try:
                req = urllib.request.Request(
                    f'{BASE_URL}/chat/completions',
                    data=body,
                    headers={
                        'Content-Type': 'application/json',
                        'Authorization': f'Bearer {API_KEY}',
                    },
                    method='POST'
                )
                with urllib.request.urlopen(req, timeout=300) as resp:
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() not in ('transfer-encoding',):
                            self.send_header(k, v)
                    self.end_headers()
                    self.wfile.write(resp.read())
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())
            return
        self.send_response(404)
        self.end_headers()

def main():
    print(f'[XTR Agent Server v7.0] Puerto={PORT} BaseURL={BASE_URL} Model={MODEL}')
    with socketserver.TCPServer(('0.0.0.0', PORT), Handler) as httpd:
        print(f'[XTR] Escuchando en 0.0.0.0:{PORT}')
        httpd.serve_forever()

if __name__ == '__main__':
    main()
