#!/usr/bin/env python3
"""
buscapersona.sh — Web UI v3.0
Sirve una interfaz web moderna para búsqueda OSINT intensiva en el puerto 9080.
Usa exclusivamente la librería estándar de Python (cero dependencias externas).

Características:
  - Formulario completo con todos los parámetros del script original
  - Streaming de resultados en tiempo real vía SSE
  - Resaltado de sintaxis ANSI en el navegador
  - Historial de búsquedas persistido en memoria
  - Cancelación de búsquedas en curso
  - Exportación de resultados (TXT / HTML)
  - Estadísticas en vivo
  - Botón de copia al portapapeles
  - Atajos de teclado
"""

import http.server
import socketserver
import json
import os
import subprocess
import threading
import time
import uuid
import html as html_mod
import urllib.parse
import signal
import sys
import re
from datetime import datetime
from io import BytesIO

# ─── Configuración ───────────────────────────────────────────────────────────
PORT = 9080
HOST = "0.0.0.0"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BINARY = os.path.join(SCRIPT_DIR, "buscapersona.sh")
MAX_HISTORY = 50

# ─── Estado global ───────────────────────────────────────────────────────────
jobs: dict[str, dict] = {}
jobs_lock = threading.Lock()

# ═══════════════════════════════════════════════════════════════════════════════
#  CONVERSIÓN ANSI → HTML
# ═══════════════════════════════════════════════════════════════════════════════

ANSI_RE = re.compile(r'\033\[([0-9;]+)m')

ANSI_CLASSES = {
    '0;31': 'c-red', '1;31': 'c-red c-bold',
    '0;32': 'c-green', '1;32': 'c-green c-bold',
    '0;33': 'c-yellow', '1;33': 'c-yellow c-bold',
    '0;34': 'c-blue', '1;34': 'c-blue c-bold',
    '0;35': 'c-magenta', '1;35': 'c-magenta c-bold',
    '0;36': 'c-cyan', '1;36': 'c-cyan c-bold',
    '0;37': 'c-white', '1;37': 'c-white c-bold',
    '1': 'c-bold', '2': 'c-dim', '0': '',
}

def ansi_to_html(text):
    """Convierte texto con códigos ANSI a HTML con clases CSS."""
    text = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('\n', '<br>')

    def _repl(m):
        code = m.group(1)
        classes = []
        for c in code.split(';'):
            cls = ANSI_CLASSES.get(c)
            if cls:
                classes.append(cls)
        if not classes:
            return ''
        if '' in classes:  # reset
            return '</span>'
        return f'<span class="{" ".join(classes)}">'

    result = ANSI_RE.sub(_repl, text)
    open_spans = result.count('<span') - result.count('</span>')
    if open_spans > 0:
        result += '</span>' * open_spans
    return result

def strip_ansi(text):
    return ANSI_RE.sub('', text)


# ═══════════════════════════════════════════════════════════════════════════════
#  GESTIÓN DE TRABAJOS (jobs)
# ═══════════════════════════════════════════════════════════════════════════════

def create_job(params):
    """Crea un job y lo lanza en un hilo."""
    job_id = uuid.uuid4().hex[:12]
    with jobs_lock:
        jobs[job_id] = {
            'id': job_id, 'params': params, 'status': 'queued',
            'lines': [], 'html_lines': [],
            'created_at': datetime.now().isoformat(),
            'finished_at': None, 'pid': None, 'progress': 0,
        }
    t = threading.Thread(target=_run_job, args=(job_id, params), daemon=True)
    t.start()
    return job_id

def _build_cmd(params):
    """Construye lista de argumentos para buscapersona.sh."""
    cmd = []
    for flag in ('-n', '-u', '-e', '-p', '-t', '-o', '--delay'):
        if flag in params and params[flag]:
            cmd += [flag, params[flag]]
    for flag in ('--all', '--dorks', '--tor', '--html', '--social-only', '--web-only', '-v'):
        if flag in params:
            cmd.append(flag)
    return cmd

def _run_job(job_id, params):
    """Ejecuta buscapersona.sh en un hilo."""
    if not any(k in params for k in ('-n', '-u', '-e', '-p')):
        _append_job(job_id, 'ERROR: Debes proporcionar al menos un campo (-n, -u, -e, -p)\n')
        _finish_job(job_id, 'error')
        return

    args = _build_cmd(params)
    cmd = ['bash', BINARY] + args

    _append_job(job_id, f'🚀 Ejecutando: {" ".join(cmd)}\n')
    _append_job(job_id, f'⏳ Iniciado: {datetime.now().strftime("%H:%M:%S")}\n\n')

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace',
            bufsize=1,
            env={**os.environ, 'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin')},
            cwd=SCRIPT_DIR,
            preexec_fn=os.setsid if hasattr(os, 'setsid') else None,
        )
        with jobs_lock:
            if job_id in jobs:
                jobs[job_id]['pid'] = proc.pid
                jobs[job_id]['status'] = 'running'

        for line in iter(proc.stdout.readline, ''):
            _append_job(job_id, line)

        proc.wait()
        status = 'completed' if proc.returncode == 0 else 'error'
        if status == 'completed':
            _append_job(job_id, '\n✅ Búsqueda completada exitosamente.\n')
        else:
            _append_job(job_id, f'\n❌ Error: proceso terminó con código {proc.returncode}\n')
        _finish_job(job_id, status)

    except Exception as e:
        _append_job(job_id, f'\n❌ Error en la ejecución: {e}\n')
        _finish_job(job_id, 'error')

def _append_job(job_id, text):
    with jobs_lock:
        j = jobs.get(job_id)
        if j:
            j['lines'].append(text)
            j['html_lines'].append(ansi_to_html(text))

def _finish_job(job_id, status):
    with jobs_lock:
        j = jobs.get(job_id)
        if j:
            j['status'] = status
            j['finished_at'] = datetime.now().isoformat()

def cancel_job(job_id):
    with jobs_lock:
        j = jobs.get(job_id)
        if j and j['status'] in ('running', 'queued') and j['pid']:
            try:
                os.killpg(os.getpgid(j['pid']), signal.SIGTERM)
                j['status'] = 'cancelled'
                _append_job(job_id, '\n⛔ Búsqueda cancelada.\n')
                j['finished_at'] = datetime.now().isoformat()
                return True
            except (ProcessLookupError, PermissionError, AttributeError):
                pass
    return False

def get_job_summary(job):
    """Resume los hallazgos de un job."""
    text = ' '.join(job.get('lines', []))
    findings = {
        'total': len(re.findall(r'[✓]', text)),
        'social': text.count('Social'),
        'username': text.count('Username'),
        'domains': text.count('registrado'),
        'dorks': text.count('Dork'),
        'docs': text.count('Docs'),
        'images': text.count('Images'),
        'news': text.count('News'),
    }
    # Extraer los enlaces encontrados
    links = re.findall(r'https?://[^\s<>"]+', strip_ansi(text))
    findings['links'] = links[:30]
    return findings


# ═══════════════════════════════════════════════════════════════════════════════
#  HTML / UI — Interfaz moderna con tema oscuro
# ═══════════════════════════════════════════════════════════════════════════════

def render_page():
    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>buscapersona.sh — OSINT Web UI</title>
<style>
  :root {{
    --bg: #0d1117; --surface: #161b22; --surface2: #1c2333; --surface3: #21262d;
    --border: #30363d; --text: #e6edf3; --text2: #8b949e; --text3: #6e7681;
    --accent: #58a6ff; --green: #3fb950; --red: #f85149;
    --yellow: #d29922; --purple: #bc8cff; --cyan: #39d2c0; --orange: #f0883e;
    --grad: linear-gradient(135deg, #e94560, #c23152);
    --radius: 10px; --radius-sm: 6px;
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.5; min-height: 100vh;
  }}
  .container {{ max-width: 1140px; margin: 0 auto; padding: 16px 20px; }}

  /* ── Header ── */
  header {{
    background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
    padding: 24px 20px; border-radius: var(--radius); margin-bottom: 20px;
    border: 1px solid var(--border); text-align: center;
  }}
  header h1 {{ font-size: 1.8rem; color: #e94560; }}
  header h1 span {{ color: var(--accent); }}
  header p {{ color: var(--text2); font-size: 0.9rem; margin-top: 4px; }}
  header .badge {{ display: inline-block; background: var(--surface2); padding: 2px 10px; border-radius: 12px; font-size: 0.7rem; color: var(--text2); margin-top: 6px; }}

  /* ── Cards ── */
  .card {{ background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 20px; margin-bottom: 16px; }}
  .card h2 {{ font-size: 1.1rem; margin-bottom: 14px; color: var(--accent); display: flex; align-items: center; gap: 8px; }}

  /* ── Formulario ── */
  .form-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }}
  @media (max-width: 700px) {{ .form-grid {{ grid-template-columns: 1fr; }} }}
  .fg {{ margin-bottom: 6px; }}
  .fg label {{ display: block; font-size: 0.8rem; color: var(--text2); margin-bottom: 3px; font-weight: 500; }}
  .fg input, .fg select {{
    width: 100%; padding: 9px 12px; background: var(--bg); border: 1px solid var(--border);
    border-radius: var(--radius-sm); color: var(--text); font-size: 0.9rem; transition: border .2s;
  }}
  .fg input:focus {{ outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px rgba(88,166,255,0.12); }}
  .fg input::placeholder {{ color: var(--text3); }}

  .check-row {{ display: flex; flex-wrap: wrap; gap: 8px 16px; margin: 10px 0; }}
  .check-row label {{ display: flex; align-items: center; gap: 5px; font-size: 0.85rem; cursor: pointer; color: var(--text2); user-select: none; }}
  .check-row input[type="checkbox"] {{ accent-color: var(--accent); width: 15px; height: 15px; cursor: pointer; }}

  .opt-row {{ display: flex; gap: 10px; flex-wrap: wrap; margin-top: 6px; }}
  .opt-row .fg {{ flex: 1; min-width: 110px; }}

  .actions {{ display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-top: 14px; }}

  /* ── Botones ── */
  .btn {{
    padding: 10px 24px; border: none; border-radius: var(--radius-sm); font-size: 0.9rem; font-weight: 600;
    cursor: pointer; transition: all .2s; display: inline-flex; align-items: center; gap: 6px;
  }}
  .btn-primary {{ background: var(--grad); color: #fff; }}
  .btn-primary:hover {{ transform: translateY(-1px); box-shadow: 0 4px 16px rgba(233,69,96,0.3); }}
  .btn-primary:disabled {{ opacity: 0.45; cursor: not-allowed; transform: none; box-shadow: none; }}
  .btn-danger {{ background: var(--red); color: #fff; }}
  .btn-danger:hover {{ filter: brightness(1.1); }}
  .btn-secondary {{ background: var(--surface2); color: var(--text); border: 1px solid var(--border); }}
  .btn-secondary:hover {{ background: var(--border); }}
  .btn-sm {{ padding: 5px 12px; font-size: 0.8rem; }}

  .spacer {{ flex: 1; }}

  /* ── Output ── */
  #output {{
    background: #0d1117; border: 1px solid var(--border); border-radius: var(--radius-sm);
    padding: 14px; font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', monospace;
    font-size: 0.82rem; line-height: 1.5; overflow-x: auto; white-space: pre-wrap; word-break: break-word;
    min-height: 180px; max-height: 65vh; overflow-y: auto;
  }}
  #output .placeholder {{ color: var(--text3); font-style: italic; }}

  .c-red {{ color: var(--red); }} .c-green {{ color: var(--green); }} .c-yellow {{ color: var(--yellow); }}
  .c-blue {{ color: var(--accent); }} .c-magenta {{ color: var(--purple); }} .c-cyan {{ color: var(--cyan); }}
  .c-white {{ color: var(--text); }} .c-bold {{ font-weight: bold; }} .c-dim {{ opacity: 0.55; }}

  /* ── Barra de progreso ── */
  #prog {{ height: 3px; background: var(--border); border-radius: 2px; overflow: hidden; margin: 8px 0; }}
  #prog .bar {{ height: 100%; width: 0%; background: var(--grad); transition: width .5s; border-radius: 2px; }}
  #prog.active .bar {{ animation: pulse 2s infinite; }}
  @keyframes pulse {{
    0% {{ width: 5%; opacity: 1; }}
    50% {{ width: 60%; opacity: 0.7; }}
    100% {{ width: 90%; opacity: 1; }}
  }}
  #prog.done .bar {{ width: 100%; background: var(--green); animation: none; }}

  /* ── Tabs ── */
  .tabs {{ display: flex; gap: 2px; border-bottom: 1px solid var(--border); margin-bottom: 12px; }}
  .tab {{ padding: 7px 18px; cursor: pointer; color: var(--text2); border-bottom: 2px solid transparent; transition: all .2s; font-size: 0.85rem; user-select: none; }}
  .tab:hover {{ color: var(--text); }}
  .tab.active {{ color: var(--accent); border-bottom-color: var(--accent); }}
  .tab-content {{ display: none; }}
  .tab-content.active {{ display: block; }}

  /* ── Stats ── */
  .stats {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 8px; margin-bottom: 12px; }}
  .stat {{ background: var(--surface2); border-radius: var(--radius-sm); padding: 10px; text-align: center; }}
  .stat .val {{ font-size: 1.3rem; font-weight: 700; }}
  .stat .lbl {{ font-size: 0.7rem; color: var(--text2); margin-top: 1px; text-transform: uppercase; letter-spacing: 0.5px; }}

  /* ── Historial ── */
  .hist-item {{
    padding: 10px 14px; border: 1px solid var(--border); border-radius: var(--radius-sm);
    margin-bottom: 6px; cursor: pointer; transition: background .2s; display: flex; align-items: center; gap: 10px;
  }}
  .hist-item:hover {{ background: var(--surface2); }}
  .hist-item .info {{ flex: 1; min-width: 0; }}
  .hist-item .title {{ font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
  .hist-item .meta {{ font-size: 0.75rem; color: var(--text2); }}
  .hist-item .dot {{
    width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0;
  }}
  .dot-running {{ background: var(--accent); animation: blink 1s infinite; }}
  .dot-completed {{ background: var(--green); }}
  .dot-error {{ background: var(--red); }}
  .dot-cancelled {{ background: var(--yellow); }}
  @keyframes blink {{ 0%,100% {{ opacity: 1; }} 50% {{ opacity: 0.3; }} }}

  .status-badge {{
    display: inline-block; padding: 2px 10px; border-radius: 10px; font-size: 0.75rem; font-weight: 600;
  }}
  .status-running {{ background: rgba(88,166,255,0.15); color: var(--accent); }}
  .status-completed {{ background: rgba(63,185,80,0.15); color: var(--green); }}
  .status-error {{ background: rgba(248,81,73,0.15); color: var(--red); }}
  .status-cancelled {{ background: rgba(210,153,34,0.15); color: var(--yellow); }}

  /* ── Toast ── */
  .toast {{
    position: fixed; bottom: 20px; right: 20px; background: var(--surface);
    border: 1px solid var(--border); border-radius: var(--radius-sm); padding: 12px 18px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.5); z-index: 999;
    transform: translateY(120px); opacity: 0; transition: all .3s; font-size: 0.85rem; max-width: 400px;
  }}
  .toast.show {{ transform: translateY(0); opacity: 1; }}
  .toast.error {{ border-left: 3px solid var(--red); }}
  .toast.success {{ border-left: 3px solid var(--green); }}

  .copied-msg {{ font-size: 0.7rem; color: var(--green); margin-left: 6px; }}

  .empty-state {{ padding: 30px; text-align: center; color: var(--text3); font-style: italic; }}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>🔍 <span>buscapersona</span>.sh</h1>
    <p>Búsqueda OSINT intensiva de personas en internet — Interfaz Web</p>
    <span class="badge">v3.0 · 14 módulos · 40+ plataformas · zero-deps</span>
  </header>

  <!-- Formulario -->
  <div class="card">
    <h2>🔎 Configuración de búsqueda</h2>
    <form id="searchForm" autocomplete="off">
      <div class="form-grid">
        <div class="fg">
          <label for="name">👤 Nombre completo</label>
          <input type="text" id="name" name="-n" placeholder="Ej: Juan Pérez">
        </div>
        <div class="fg">
          <label for="username">🔍 Nombre de usuario</label>
          <input type="text" id="username" name="-u" placeholder="Ej: juanperez80">
        </div>
        <div class="fg">
          <label for="email">📧 Correo electrónico</label>
          <input type="email" id="email" name="-e" placeholder="Ej: juan@ejemplo.com">
        </div>
        <div class="fg">
          <label for="phone">📞 Teléfono</label>
          <input type="text" id="phone" name="-p" placeholder="Ej: +525512345678">
        </div>
      </div>

      <div class="check-row">
        <label><input type="checkbox" id="chkAll" name="--all" value="1"> 🌟 <b>Todo</b> (máxima intensidad)</label>
        <label><input type="checkbox" name="--dorks" value="1"> 🔎 Google Dorks</label>
        <label><input type="checkbox" name="--tor" value="1"> 🔒 Tor</label>
        <label><input type="checkbox" name="-v" value="1"> 📢 Verbose</label>
      </div>

      <div class="opt-row">
        <div class="fg">
          <label for="timeout">⏱️ Timeout (s)</label>
          <input type="number" id="timeout" name="-t" value="10" min="3" max="120">
        </div>
        <div class="fg">
          <label for="delay">🐢 Delay min,max</label>
          <input type="text" id="delay" name="--delay" value="0.3,1.0" placeholder="0.3,1.0">
        </div>
        <div class="fg">
          <label for="outputDir">📁 Directorio salida</label>
          <input type="text" id="outputDir" name="-o" placeholder="/tmp/osint_resultados">
        </div>
      </div>

      <div class="actions">
        <button type="submit" id="btnSubmit" class="btn btn-primary">🔍 Iniciar búsqueda</button>
        <button type="button" id="btnCancel" class="btn btn-danger" style="display:none">⛔ Cancelar</button>
        <button type="button" class="btn btn-secondary btn-sm" onclick="clearOutput()">🗑️ Limpiar</button>
        <button type="button" class="btn btn-secondary btn-sm" id="btnExport" style="display:none" onclick="exportResults()">📥 Exportar</button>
        <span class="spacer"></span>
        <span id="statusMsg" style="font-size:0.85rem;color:var(--text2)">💡 Listo</span>
      </div>
    </form>
  </div>

  <!-- Stats -->
  <div class="stats" id="statsRow">
    <div class="stat"><div class="val c-green" id="statFound">0</div><div class="lbl">✓ Hallazgos</div></div>
    <div class="stat"><div class="val c-blue" id="statSocial">0</div><div class="lbl">Redes</div></div>
    <div class="stat"><div class="val c-magenta" id="statUsername">0</div><div class="lbl">Usernames</div></div>
    <div class="stat"><div class="val c-yellow" id="statDorks">0</div><div class="lbl">Dorks</div></div>
  </div>

  <!-- Progress bar -->
  <div id="prog"><div class="bar"></div></div>

  <!-- Tabs: Resultados + Historial -->
  <div class="card" style="padding-bottom: 8px;">
    <div class="tabs">
      <div class="tab active" data-tab="results" onclick="switchTab('results')">📄 Resultados</div>
      <div class="tab" data-tab="history" onclick="switchTab('history')">📜 Historial</div>
      <div class="tab" data-tab="links" onclick="switchTab('links')">🔗 Enlaces</div>
    </div>

    <div id="tab-results" class="tab-content active">
      <div style="display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap;align-items:center">
        <span class="status-badge" id="liveStatus" style="display:none">🟢 En vivo</span>
        <span id="lineCount" style="font-size:0.75rem;color:var(--text3)"></span>
        <span class="spacer"></span>
        <span id="copyHint" style="font-size:0.75rem;color:var(--text3);cursor:pointer" onclick="copyOutput()">📋 Copiar</span>
      </div>
      <pre id="output"><span class="placeholder">⏎ Los resultados aparecerán aquí después de iniciar una búsqueda. Completa al menos un campo y presiona "Iniciar búsqueda".</span></pre>
    </div>

    <div id="tab-history" class="tab-content">
      <div id="historyList"><div class="empty-state">⏳ Cargando historial...</div></div>
    </div>

    <div id="tab-links" class="tab-content">
      <div id="linksList"><div class="empty-state">Los enlaces encontrados aparecerán aquí durante la búsqueda.</div></div>
    </div>
  </div>
</div>

<div id="toast" class="toast"></div>

<script>
// ─── Estado ──────────────────────────────────────────────────────────────────
let currentJobId = null;
let polling = false;
let pollTimer = null;
const $ = id => document.getElementById(id);

// ─── Toast ────────────────────────────────────────────────────────────────────
function toast(msg, type='') {{
  const t = $('toast');
  t.textContent = msg;
  t.className = 'toast show ' + type;
  clearTimeout(t._hide);
  t._hide = setTimeout(() => t.classList.remove('show'), 4000);
}}

// ─── Tabs ─────────────────────────────────────────────────────────────────────
function switchTab(name) {{
  document.querySelectorAll('.tab').forEach(el => el.classList.toggle('active', el.dataset.tab === name));
  document.querySelectorAll('.tab-content').forEach(el => el.classList.toggle('active', el.id === 'tab-' + name));
}}

// ─── Inicio ───────────────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {{
  const form = $('searchForm');
  form.addEventListener('submit', async e => {{
    e.preventDefault();
    const hasData = ['name','username','email','phone'].some(id => $(id).value.trim());
    if (!hasData) {{ toast('⚠️ Completa al menos un campo', 'error'); return; }}
    await startSearch();
  }});

  // Si se marca "Todo", desmarcar específicos y viceversa
  $('chkAll').addEventListener('change', () => {{
    if ($('chkAll').checked) {{
      document.querySelectorAll('input[name="--dorks"], input[name="--tor"], input[name="-v"]').forEach(c => c.checked = false);
    }}
  }});
  document.querySelectorAll('input[name="--dorks"], input[name="--tor"], input[name="-v"]').forEach(cb => {{
    cb.addEventListener('change', () => {{ if (cb.checked) $('chkAll').checked = false; }});
  }});

  // Enter en inputs → submit
  document.querySelectorAll('#searchForm input').forEach(inp => {{
    inp.addEventListener('keydown', e => {{ if (e.key === 'Enter') form.dispatchEvent(new Event('submit')); }});
  }});

  // Cancel button
  $('btnCancel').addEventListener('click', cancelSearch);

  loadHistory();
  const savedId = sessionStorage.getItem('osintJobId');
  if (savedId) viewJob(savedId);
}});

// ─── Iniciar búsqueda ─────────────────────────────────────────────────────────
async function startSearch() {{
  const form = $('searchForm');
  const fd = new FormData(form);
  const data = new URLSearchParams();
  for (const [k, v] of fd) {{ if (v) data.append(k, v); }}

  setUI('loading');
  $('output').innerHTML = '<span class="placeholder">⏳ Iniciando búsqueda... Esto puede tomar varios segundos dependiendo de los módulos activados.</span>';
  $('liveStatus').style.display = 'inline';
  $('liveStatus').textContent = '⏳ Iniciando...';
  $('btnExport').style.display = 'none';

  try {{
    const resp = await fetch('/api/search', {{ method: 'POST', body: data }});
    const result = await resp.json();
    if (result.error) {{ toast('❌ ' + result.error, 'error'); setUI('idle'); return; }}
    currentJobId = result.job_id;
    sessionStorage.setItem('osintJobId', currentJobId);
    $('liveStatus').textContent = '🟢 En vivo';
    pollOutput(currentJobId);
    loadHistory();
  }} catch (err) {{
    toast('❌ Error de conexión: ' + err.message, 'error');
    setUI('idle');
  }}
}}

function setUI(state) {{
  const btn = $('btnSubmit');
  if (state === 'loading') {{
    btn.disabled = true; btn.innerHTML = '⏳ Buscando...';
    $('btnCancel').style.display = 'inline-flex';
    $('statusMsg').textContent = '🚀 Búsqueda en curso...';
    $('prog').className = 'active';
  }} else if (state === 'idle') {{
    btn.disabled = false; btn.innerHTML = '🔍 Iniciar búsqueda';
    $('btnCancel').style.display = 'none';
    $('statusMsg').textContent = '💡 Listo';
    $('prog').className = '';
    $('liveStatus').style.display = 'none';
  }}
}}

// ─── Polling de resultados ────────────────────────────────────────────────────
function pollOutput(jobId) {{
  if (polling) return;
  polling = true;
  let lastLen = 0;
  let idleCycles = 0;

  (async () => {{
    while (polling) {{
      try {{
        const resp = await fetch('/api/output?id=' + jobId);
        const data = await resp.json();
        if (data.error) {{ toast('❌ ' + data.error, 'error'); break; }}

        const out = $('output');
        if (data.html && data.html.length > lastLen) {{
          const newHtml = data.html.slice(lastLen).join('');
          if (lastLen === 0 && newHtml) out.innerHTML = '';
          out.innerHTML += newHtml;
          out.scrollTop = out.scrollHeight;
          lastLen = data.html.length;
          $('lineCount').textContent = lastLen + ' líneas';
          idleCycles = 0;
        }} else {{
          idleCycles++;
        }}

        // Actualizar pestaña de enlaces periódicamente
        if (lastLen > 0 && idleCycles < 3) updateLinksTab(jobId);

        const st = data.status;
        if (st === 'completed') {{
          out.innerHTML += '<br><span class="c-green c-bold">✅ Búsqueda completada.</span>';
          toast('✅ Búsqueda completada', 'success');
          finishPoll(jobId);
          $('prog').className = 'done';
          $('liveStatus').textContent = '✅ Completo';
          $('btnExport').style.display = 'inline-flex';
          loadHistory();
          break;
        }} else if (st === 'error') {{
          out.innerHTML += '<br><span class="c-red c-bold">❌ Error.</span>';
          finishPoll(jobId);
          $('prog').className = 'done';
          $('liveStatus').textContent = '❌ Error';
          break;
        }} else if (st === 'cancelled') {{
          finishPoll(jobId);
          break;
        }}
      }} catch (err) {{
        if (polling) await sleep(2000);
      }}
      await sleep(800);
    }}
  }})();
}}

function finishPoll(jobId) {{
  polling = false;
  setUI('idle');
}}

function sleep(ms) {{ return new Promise(r => setTimeout(r, ms)); }}

// ─── Cancelar ────────────────────────────────────────────────────────────────
async function cancelSearch() {{
  if (!currentJobId) return;
  try {{
    await fetch('/api/cancel', {{ method: 'POST', body: 'id=' + currentJobId,
      headers: {{'Content-Type': 'application/x-www-form-urlencoded'}} }});
    toast('⛔ Cancelando...');
  }} catch (e) {{ toast('❌ Error', 'error'); }}
}}

// ─── Limpiar ─────────────────────────────────────────────────────────────────
function clearOutput() {{
  $('output').innerHTML = '<span class="placeholder">⏎ Resultados limpiados.</span>';
  $('lineCount').textContent = '';
  $('linksList').innerHTML = '<div class="empty-state">Los enlaces aparecerán durante la búsqueda.</div>';
  resetStats();
}}

function resetStats() {{
  ['statFound','statSocial','statUsername','statDorks'].forEach(id => $(id).textContent = '0');
}}

// ─── Actualizar stats y enlaces ───────────────────────────────────────────────
function updateStats(data) {{
  if (!data || !data.html) return;
  const text = data.html.join(' ');
  $('statFound').textContent = (text.match(/c-green">[✓]/g) || []).length;
  $('statSocial').textContent = (text.match(/Social/g) || []).length;
  $('statUsername').textContent = (text.match(/Username/g) || []).length;
  $('statDorks').textContent = (text.match(/Dork/g) || []).length;
}}

async function updateLinksTab(jobId) {{
  try {{
    const resp = await fetch('/api/links?id=' + jobId);
    const data = await resp.json();
    if (data.links && data.links.length > 0) {{
      $('linksList').innerHTML = data.links.map(l =>
        '<div style="padding:4px 0;font-size:0.82rem;word-break:break-all">🔗 <a href="' + l + '" target="_blank" rel="noopener" style="color:var(--accent);text-decoration:none">' + l + '</a></div>'
      ).join('');
    }}
  }} catch (e) {{}}
}}

// ─── Copiar al portapapeles ──────────────────────────────────────────────────
function copyOutput() {{
  const text = $('output').textContent;
  navigator.clipboard.writeText(text).then(() => {{
    $('copyHint').textContent = '✅ Copiado';
    setTimeout(() => $('copyHint').textContent = '📋 Copiar', 2000);
  }}).catch(() => {{}});
}}

// ─── Exportar ─────────────────────────────────────────────────────────────────
function exportResults() {{
  const text = $('output').textContent;
  const blob = new Blob([text], {{ type: 'text/plain;charset=utf-8' }});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = 'osint_resultados_' + new Date().toISOString().slice(0,19).replace(/[:-]/g,'') + '.txt';
  a.click();
  URL.revokeObjectURL(url);
  toast('📥 Descargando resultados...', 'success');
}}

// ─── Historial ────────────────────────────────────────────────────────────────
async function loadHistory() {{
  try {{
    const resp = await fetch('/api/history');
    const data = await resp.json();
    const list = $('historyList');
    if (!list) return;
    if (!data.jobs || data.jobs.length === 0) {{
      list.innerHTML = '<div class="empty-state">📭 Sin búsquedas aún</div>';
      return;
    }}
    list.innerHTML = data.jobs.slice().reverse().map(j => {{
      const p = j.params || {{}};
      const parts = [];
      if (p['-n']) parts.push('👤 ' + esc(p['-n']));
      if (p['-u']) parts.push('🔍 ' + esc(p['-u']));
      if (p['-e']) parts.push('📧 ' + esc(p['-e']));
      if (p['-p']) parts.push('📞 ' + esc(p['-p']));
      const title = parts.join(' · ') || '(sin datos)';
      const time = new Date(j.created_at).toLocaleString();
      const st = j.status;
      return '<div class="hist-item" onclick="viewJob(\\'' + j.id + '\\')">' +
        '<div class="dot dot-' + st + '"></div>' +
        '<div class="info"><div class="title">' + title + '</div>' +
        '<div class="meta">' + time + ' · <span class="status-badge status-' + st + '">' + st + '</span></div></div></div>';
    }}).join('');
  }} catch (e) {{ console.error(e); }}
}}

function esc(str) {{
  const d = document.createElement('div'); d.textContent = str; return d.innerHTML;
}}

async function viewJob(jobId) {{
  currentJobId = jobId;
  sessionStorage.setItem('osintJobId', jobId);
  try {{
    const resp = await fetch('/api/output?id=' + jobId);
    const data = await resp.json();
    if (data.error) return;
    $('output').innerHTML = (data.html || []).join('') || '<span class="placeholder">(vacío)</span>';
    $('lineCount').textContent = (data.html || []).length + ' líneas';
    switchTab('results');
    updateStats(data);
    updateLinksTab(jobId);
    $('liveStatus').style.display = 'inline';
    $('liveStatus').textContent = data.status === 'completed' ? '✅ Completo' : data.status === 'error' ? '❌ Error' : data.status === 'running' ? '🟢 En vivo' : '⏹️ ' + data.status;
    if (data.status === 'completed') $('btnExport').style.display = 'inline-flex';
    if (data.status === 'running') {{ setUI('loading'); pollOutput(jobId); }}
  }} catch (e) {{ console.error(e); }}
}}
</script>
</body>
</html>"""


# ═══════════════════════════════════════════════════════════════════════════════
#  HTTP HANDLER
# ═══════════════════════════════════════════════════════════════════════════════

class Handler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path == '/':
            self._html(render_page())

        elif path == '/api/output':
            job_id = qs.get('id', [None])[0]
            if not job_id or job_id not in jobs:
                self._json({'error': 'Job not found'}, 404)
                return
            with jobs_lock:
                j = jobs.get(job_id, {})
                self._json({
                    'status': j.get('status', 'unknown'),
                    'html': j.get('html_lines', []),
                    'lines': j.get('lines', []),
                    'finished_at': j.get('finished_at'),
                })

        elif path == '/api/links':
            """Extrae enlaces encontrados en el output."""
            job_id = qs.get('id', [None])[0]
            if not job_id or job_id not in jobs:
                self._json({'links': []})
                return
            with jobs_lock:
                j = jobs.get(job_id, {})
                text = ' '.join(j.get('lines', []))
            clean = strip_ansi(text)
            links = re.findall(r'https?://[^\s<>"\')\]]+', clean)
            # Filtrar, deduplicar
            seen = set()
            unique = []
            for l in links:
                if l not in seen:
                    seen.add(l)
                    unique.append(l)
            self._json({'links': unique[:50]})

        elif path == '/api/history':
            with jobs_lock:
                items = [
                    {'id': jid, 'params': j.get('params', {}),
                     'status': j.get('status', 'unknown'),
                     'created_at': j.get('created_at', ''),
                     'finished_at': j.get('finished_at', '')}
                    for jid, j in jobs.items()
                ][-MAX_HISTORY:]
            self._json({'jobs': items})

        elif path == '/api/stats':
            with jobs_lock:
                total = len(jobs)
                running = sum(1 for j in jobs.values() if j.get('status') == 'running')
                completed = sum(1 for j in jobs.values() if j.get('status') == 'completed')
            self._json({'total': total, 'running': running, 'completed': completed})

        elif path == '/api/export':
            """Exporta resultados como texto plano."""
            job_id = qs.get('id', [None])[0]
            fmt = qs.get('format', ['txt'])[0]
            if not job_id or job_id not in jobs:
                self._json({'error': 'Job not found'}, 404)
                return
            with jobs_lock:
                j = jobs.get(job_id, {})
                raw = ''.join(j.get('lines', []))
            clean = strip_ansi(raw)
            if fmt == 'txt':
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Content-Disposition', f'attachment; filename="osint_{job_id}.txt"')
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(clean.encode('utf-8'))
            else:
                self._json({'error': 'Unsupported format'}, 400)
            return

        elif path == '/health':
            self._json({'status': 'ok', 'version': '3.0.0'})

        else:
            self._json({'error': 'Not found'}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == '/api/search':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            fd = urllib.parse.parse_qs(body)

            params = {}
            for key in ('-n', '-u', '-e', '-p', '-t', '-o', '--delay'):
                vals = fd.get(key, [])
                if vals and vals[0].strip():
                    params[key] = vals[0].strip()
            for flag in ('--all', '--dorks', '--tor', '--html', '--social-only', '--web-only', '-v'):
                if flag in fd:
                    params[flag] = '1'

            if not any(k in params for k in ('-n', '-u', '-e', '-p')):
                self._json({'error': 'Completa al menos un campo (-n, -u, -e, -p)'}, 400)
                return

            jid = create_job(params)
            self._json({'job_id': jid})

        elif path == '/api/cancel':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8') if length else ''
            fd = urllib.parse.parse_qs(body) if body else {}
            jid = fd.get('id', [None])[0]
            if not jid or jid not in jobs:
                self._json({'error': 'Job not found'}, 404)
                return
            ok = cancel_job(jid)
            self._json({'cancelled': ok})

        else:
            self._json({'error': 'Not found'}, 404)

    def _json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))

    def _html(self, html, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(html.encode('utf-8'))

    def log_message(self, fmt, *args):
        if args and args[0] in ('/health', '/favicon.ico'):
            return
        ts = datetime.now().strftime('%H:%M:%S')
        addr = self.client_address[0] if self.client_address else '?'
        print(f"[{ts}] {addr} {args[0] if args else '-'}")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()


# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

def run_server():
    if not os.path.exists(BINARY):
        print(f"ERROR: No se encuentra {BINARY}")
        sys.exit(1)
    if not os.access(BINARY, os.X_OK):
        os.chmod(BINARY, 0o755)

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = Server((HOST, PORT), Handler)
    print('\n' + '='*58)
    print('  🔍 buscapersona.sh — Web UI v3.0')
    print('  Búsqueda OSINT intensiva de personas')
    print('='*58)
    print(f'  📡 Servidor:  http://localhost:{PORT}')
    print(f'  🌐 Red:       http://{HOST}:{PORT}')
    print(f'  📁 Script:    {BINARY}')
    print(f'  ⏹️  Detener:  Ctrl+C')
    print('='*58 + '\n')
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n⏹️  Servidor detenido.')
        server.server_close()
        sys.exit(0)

if __name__ == '__main__':
    run_server()
