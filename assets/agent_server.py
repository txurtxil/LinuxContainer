#!/usr/bin/env python3
# agent_server.py — v10.0  (solo stdlib, SO_REUSEADDR, kill previo)
import os, sys, json, socket, socketserver, http.server, urllib.request, urllib.error

PORT = int(os.environ.get('AGENT_PORT', '8765'))
BASE_URL = os.environ.get('LLM_BASE_URL', 'http://127.0.0.1:8090/v1')
MODEL = os.environ.get('LLM_MODEL', 'gemma3-local')
API_KEY = os.environ.get('LLM_API_KEY', 'local')

class ReuseAddrTCPServer(socketserver.TCPServer):
    """Permite reutilizar el puerto inmediatamente (SO_REUSEADDR)."""
    allow_reuse_address = True
    daemon_threads = True

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'[agent] {fmt % args}', flush=True)

    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
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
            except urllib.error.HTTPError as e:
                self.send_response(e.code)
                for k, v in e.headers.items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(e.read())
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error': str(e)}).encode())
            return
        self.send_response(404)
        self.end_headers()

def wait_for_port_release(port, timeout=8):
    """Espera a que el puerto se libere antes de arrancar."""
    import time
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            result = s.connect_ex(('127.0.0.1', port))
            s.close()
            if result != 0:
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False

def main():
    print(f'[XTR Agent Server v10.0] Puerto={PORT} BaseURL={BASE_URL} Model={MODEL}', flush=True)

    # Esperar a que el puerto se libere si estaba ocupado
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        if s.connect_ex(('0.0.0.0', PORT)) == 0:
            print(f'[XTR] Puerto {PORT} ocupado. Esperando liberacion...', flush=True)
            if not wait_for_port_release(PORT):
                print(f'[WARN] Puerto {PORT} sigue ocupado. Forzando SO_REUSEADDR...', flush=True)
        s.close()
    except Exception:
        pass

    print(f'[XTR] Usando solo stdlib + SO_REUSEADDR. Escuchando en 0.0.0.0:{PORT}', flush=True)
    with ReuseAddrTCPServer(('0.0.0.0', PORT), Handler) as httpd:
        httpd.serve_forever()

if __name__ == '__main__':
    main()
