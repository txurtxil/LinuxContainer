#!/usr/bin/env python3
# agent_server.py — v11.0  (solo stdlib, sin dependencias externas)
# Fixes: SO_REUSEADDR, PID file, reintentos bind, health-check backend,
#        graceful shutdown, no falla si backend no responde (reporta warning)

import os, sys, json, socket, socketserver, http.server, urllib.request, urllib.error, signal, time

PORT = int(os.environ.get('AGENT_PORT', '8765'))
BASE_URL = os.environ.get('LLM_BASE_URL', 'http://127.0.0.1:8090/v1')
MODEL = os.environ.get('LLM_MODEL', 'gemma3-local')
API_KEY = os.environ.get('LLM_API_KEY', 'local')
PID_FILE = os.environ.get('AGENT_PID_FILE', '/tmp/agent.pid')
MAX_BIND_RETRIES = int(os.environ.get('AGENT_BIND_RETRIES', '30'))
BIND_RETRY_DELAY = float(os.environ.get('AGENT_BIND_DELAY', '0.5'))

_shutdown_requested = False


def _write_pid():
    try:
        with open(PID_FILE, 'w') as f:
            f.write(str(os.getpid()))
    except Exception as e:
        print(f'[warn] No se pudo escribir PID file: {e}', flush=True)


def _remove_pid():
    try:
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
    except Exception:
        pass


def _check_backend(timeout=4):
    """Verifica que el backend MediaPipe (:8090) responda."""
    if BASE_URL.startswith('http://127.0.0.1:8090') or BASE_URL.startswith('http://localhost:8090'):
        try:
            req = urllib.request.Request(f'{BASE_URL}/models', method='GET')
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                print(f'[ok] Backend MediaPipe responde: {resp.status}', flush=True)
                return True
        except Exception as e:
            print(f'[warn] Backend MediaPipe (:8090) no responde: {e}', flush=True)
            return False
    return True  # Remoto: no verificamos aqui


def _wait_for_port_free(port, max_wait=10):
    """Espera activa a que el puerto quede libre."""
    t0 = time.time()
    while time.time() - t0 < max_wait:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(1)
            result = s.connect_ex(('127.0.0.1', port))
            s.close()
            if result != 0:
                return True
            print(f'[wait] Puerto {port} aun ocupado, esperando...', flush=True)
        except Exception:
            return True
        time.sleep(0.5)
    return False


class ReuseAddrTCPServer(socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        super().server_bind()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f'[agent] {fmt % args}', flush=True)

    def do_GET(self):
        if self.path == '/health':
            backend_ok = False
            try:
                if BASE_URL.startswith('http://127.0.0.1:8090') or BASE_URL.startswith('http://localhost:8090'):
                    req = urllib.request.Request(f'{BASE_URL}/models', method='GET')
                    with urllib.request.urlopen(req, timeout=2) as resp:
                        backend_ok = resp.status == 200
                else:
                    backend_ok = True
            except Exception:
                backend_ok = False

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'status': 'ok',
                'model': MODEL,
                'base_url': BASE_URL,
                'port': PORT,
                'pid': os.getpid(),
                'backend_ready': backend_ok,
            }).encode())
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


def _signal_handler(signum, frame):
    global _shutdown_requested
    print(f'[agent] Senal {signum} recibida, shutdown graceful...', flush=True)
    _shutdown_requested = True


def main():
    global _shutdown_requested
    print(f'[XTR Agent Server v11.0] Puerto={PORT} BaseURL={BASE_URL} Model={MODEL}', flush=True)

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    _write_pid()

    try:
        # Esperar a que el puerto se libere si estaba ocupado
        if not _wait_for_port_free(PORT, max_wait=6):
            print(f'[warn] Puerto {PORT} sigue ocupado tras esperar, intentando bind con SO_REUSEADDR...', flush=True)

        # Reintentar bind con SO_REUSEADDR y backoff
        httpd = None
        for attempt in range(1, MAX_BIND_RETRIES + 1):
            try:
                httpd = ReuseAddrTCPServer(('0.0.0.0', PORT), Handler)
                print(f'[ok] Bind exitoso en 0.0.0.0:{PORT} (intento {attempt})', flush=True)
                break
            except OSError as e:
                if e.errno == 98:
                    print(f'[warn] Puerto {PORT} ocupado (intento {attempt}/{MAX_BIND_RETRIES}), esperando {BIND_RETRY_DELAY}s...', flush=True)
                    time.sleep(BIND_RETRY_DELAY)
                else:
                    raise

        if httpd is None:
            print(f'[FATAL] No se pudo hacer bind en puerto {PORT} tras {MAX_BIND_RETRIES} intentos.', flush=True)
            sys.exit(1)

        # Health-check del backend (solo GPU local)
        if BASE_URL.startswith('http://127.0.0.1:8090') or BASE_URL.startswith('http://localhost:8090'):
            print('[XTR] Verificando backend MediaPipe...', flush=True)
            if not _check_backend(timeout=3):
                print('[warn] Backend MediaPipe no responde. El agente arranco, pero las peticiones fallaran hasta que :8090 este listo.', flush=True)
            else:
                print('[ok] Backend MediaPipe listo.', flush=True)

        print(f'[XTR] Escuchando en 0.0.0.0:{PORT}', flush=True)
        httpd.serve_forever()
    finally:
        _remove_pid()
        if httpd:
            try:
                httpd.server_close()
            except Exception:
                pass
        print('[agent] Shutdown completo.', flush=True)


if __name__ == '__main__':
    main()
