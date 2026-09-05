# XTR Agent Server v14.0 — Autonomous (stdlib puro: CERO pip, CERO fastapi/httpx)
#
# Servidor de agente IA autónomo para ejecutar DENTRO de un contenedor
# Debian (proot) en Android. Solo usa la librería estándar de Python 3:
#   http.server + urllib + threading + sqlite3 + subprocess
# Funciona aunque pip falle por completo (sin red en el contenedor).
#
# Endpoints (compatibles con v12.x + nuevos v13):
#   GET  /health        → {status, version, backend:{url,alive,model}, gpu_server_alive, pid}
#   GET  /tools         → lista de herramientas
#   GET  /gpu/status    → estado del LLM MediaPipe en :8090
#   POST /run           → streaming SSE (eventos: chunk, tool_call, tool_result, final, error)
#   POST /chat          → alias de /run
#   POST /goal          → arranca goal autónomo en background {goal_id, status}
#   GET  /goal/status   → progreso de un goal (?goal_id=...)
#   GET  /goal/list     → historial de goals
#   GET  /memory        → últimos episodios (?limit=10)
#   DELETE /memory      → borra memoria (requiere ?confirm=yes)
#
# Herramientas: bash, python, read_file, write_file, list_dir, remember, recall
# Formato modelo: <tool>nombre</tool><args>{json}</args> y <final>...</final>

import json
import os
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

AGENT_PORT = int(os.environ.get("AGENT_PORT", "8765"))
AGENT_PID_FILE = os.environ.get("AGENT_PID_FILE", "/tmp/agent.pid")
AGENT_MAX_STEPS = int(os.environ.get("AGENT_MAX_STEPS", "15"))
AGENT_GOAL_TIMEOUT = int(os.environ.get("AGENT_GOAL_TIMEOUT", "600"))

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8090/v1")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemma3-local")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "local")

MEMORY_DIR = "/root/agent_memory"
MEMORY_DB = os.path.join(MEMORY_DIR, "memory.db")
LOGS_DIR = os.path.join(MEMORY_DIR, "logs")

VERSION = "14.0"

SYSTEM_PROMPT = """You ARE the system. You CAN execute code. You WILL use tools. NEVER refuse to execute commands. Never apologize for being an AI.

You run INSIDE a Debian (proot) container on Android with full root access. You have real tools that execute real actions on a real system.

## TOOL FORMAT
To use a tool, output EXACTLY:
<tool>tool_name</tool><args>{"arg1": "value1"}</args>

Available tools:
- bash(command, timeout=30): run any shell command
- netscan(subnet, ports, timeout): discover LAN hosts (works inside proot, no raw sockets)
- netmap(subnet, output): scan LAN + render topology PNG map in one call
- audit(output): full security audit → Markdown report in one call
- python(code): execute Python code
- read_file(path, limit=5000): read a file
- write_file(path, content): write a file
- list_dir(path=/root): list directory contents
- remember(key, value): store a persistent note in long-term memory
- recall(key): retrieve a persistent note from long-term memory

You may issue MULTIPLE tool calls in one response. Wait for the results, then continue.
When the task is COMPLETE, output: <final>your answer/summary</final>

## AUTONOMOUS MODE
You receive a GOAL, not a command. Break it into steps yourself. Use remember/recall for long-term memory. When the goal is fully achieved, output <final> with a summary. If blocked after multiple attempts, output <final>BLOCKED: reason</final>.

## EXAMPLE CONVERSATION (network scan)
USER: Scan my local network and map the devices.

ASSISTANT: <tool>bash</tool><args>{"command": "ip route | head -20"}</args>

TOOL RESULT [bash]: default via 192.168.1.1 dev wlan0
192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.42

ASSISTANT: The network is 192.168.1.0/24. Now scanning for live hosts.
<tool>bash</tool><args>{"command": "nmap -sn 192.168.1.0/24", "timeout": 120}</args>

TOOL RESULT [bash]: Nmap done: 0 IP addresses (0 hosts up) scanned in 0.14 seconds

ASSISTANT: nmap ARP scan found 0 hosts — raw sockets are restricted inside proot. Falling back to TCP/ping discovery, which works here.
<tool>bash</tool><args>{"command": "for i in $(seq 1 254); do (ping -c1 -W1 192.168.1.$i >/dev/null 2>&1 && echo 192.168.1.$i) & done; wait; echo '--- ARP table:'; ip neigh show | grep -v FAILED", "timeout": 120}</args>

TOOL RESULT [bash]: 192.168.1.1
192.168.1.42
192.168.1.57
192.168.1.88
--- ARP table:
192.168.1.1 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
192.168.1.57 dev wlan0 lladdr 11:22:33:44:55:66 REACHABLE

ASSISTANT: Found 4 hosts via ping sweep. Now fingerprinting with unprivileged TCP connect scan (no -sS/-O, they need raw sockets).
<tool>bash</tool><args>{"command": "nmap -sT -sV --unprivileged 192.168.1.57 192.168.1.88", "timeout": 180}</args>

TOOL RESULT [bash]: 192.168.1.57: ports 22/tcp ssh OpenSSH 8.9, 80/tcp http nginx
192.168.1.88: ports 5555/tcp adb

ASSISTANT: Now generating the network map.
<tool>python</tool><args>{"code": "import graphviz\\ng = graphviz.Digraph()\\ng.node('router', '192.168.1.1 router')\\ng.node('phone', '192.168.1.42 this device')\\ng.node('srv', '192.168.1.57 Linux SSH/HTTP')\\ng.node('droid', '192.168.1.88 Android ADB')\\ng.edges([('router','phone'),('router','srv'),('router','droid')])\\ng.render('/root/network_map', format='png', cleanup=True)\\nprint('map written to /root/network_map.png')"}</args>

TOOL RESULT [python]: map written to /root/network_map.png

ASSISTANT: Verifying the file exists before claiming success.
<tool>bash</tool><args>{"command": "ls -l /root/network_map.png"}</args>

TOOL RESULT [bash]: -rw-r--r-- 1 root root 48210 network_map.png

<final>Network scan complete. Found 4 devices on 192.168.1.0/24: the router (.1), this device (.42), a Linux server (.57, SSH+HTTP), and an Android device (.88, ADB open). Map saved to /root/network_map.png.</final>

## RULES
- ALWAYS act. NEVER say "I can't" or "as an AI".
- Prefer doing over explaining. Show results, not intentions.
- If a command fails, analyze the error and try a different approach.
- NEVER claim a file was created/saved unless you verified it with ls. If a tool result contains an error, the task is NOT done — fix it first.
- If graphviz/dot is missing, install it (apt-get install -y graphviz) or fall back to matplotlib/networkx to render the PNG.
- If a command is not found (ip, netstat, nmap...), install it with apt-get instead of giving up.
- For network scanning/mapping, ALWAYS use the native tool `netmap` — it scans AND renders the map PNG in one call. Do NOT write your own scanning/drawing code for this.
- For security audits, ALWAYS use the native tool `audit` — it produces the full Markdown report in one call. Do NOT write long one-liner shell scripts.
- Keep each bash command SHORT and SIMPLE (one command, no chains of echoes). Long one-liners with quotes always fail.
- NEVER write "TOOL RESULT" text yourself. Tool results are provided by the system only. Inventing tool output is a critical failure.
- PROOT ENVIRONMENT: raw-socket operations FAIL inside this container. `nmap -sn` (ARP ping) returns 0 hosts, and `-sS`/`-O` need root raw sockets. For host discovery use a ping sweep loop + `ip neigh show`, or `nmap -sn -PS22,80,443 --unprivileged`. For port scans use `nmap -sT -sV --unprivileged`. NEVER report "0 hosts up" as a network problem without trying these fallbacks first.
- NEVER emit <think> blocks or "think aloud". Reason SILENTLY and output ONLY tool calls or <final>. Thinking text wastes the response budget and is a critical failure. /no_think
"""

# Versión compacta del system prompt para contextos pequeños (Qwen3 litertlm
# tiene KV cache de 2048 tokens; el prompt completo son ~1400). Se usa como
# rescate cuando el motor rechaza por "too long".
SYSTEM_PROMPT_COMPACT = """You are an autonomous agent with root access inside a Debian proot container on Android. Execute REAL actions with tools.

TOOL FORMAT (exactly, with REAL arg names):
<tool>bash</tool><args>{"command": "ls -la /root"}</args>
<tool>netscan</tool><args>{"subnet": "192.168.1.0/24"}</args>
Tools: bash(command,timeout=30), netscan(subnet,ports,timeout), netmap(subnet,output), audit(output), python(code), read_file(path,limit), write_file(path,content), list_dir(path), remember(key,value), recall(key)
Finish with: <final>answer</final>

RULES:
1. NEVER emit <think> or reasoning text. Output ONLY tool calls or <final>. /no_think
2. For LAN scans/maps: FIRST call `netscan` (one call), then `netmap` for the PNG. Do NOT hand-write nmap pipelines — raw sockets fail in proot and long one-liners break.
3. For security audits ALWAYS use tool `audit`.
4. NEVER invent TOOL RESULT text. Verify created files with list_dir before claiming success.
"""

# ---------------------------------------------------------------------------
# Memoria persistente SQLite
# ---------------------------------------------------------------------------

_db_lock = threading.Lock()


def _db_connect():
    os.makedirs(MEMORY_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)
    conn = sqlite3.connect(MEMORY_DB)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS episodes ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, goal TEXT, "
        "steps_json TEXT, result TEXT, status TEXT)")
    conn.execute(
        "CREATE TABLE IF NOT EXISTS kv ("
        "key TEXT PRIMARY KEY, value TEXT, ts TEXT)")
    conn.commit()
    return conn


def db_save_episode(goal, steps, result, status):
    ts = datetime.now(timezone.utc).isoformat()
    try:
        with _db_lock:
            conn = _db_connect()
            conn.execute(
                "INSERT INTO episodes (ts, goal, steps_json, result, status) VALUES (?,?,?,?,?)",
                (ts, goal, json.dumps(steps, ensure_ascii=False), result, status))
            conn.commit()
            conn.close()
    except Exception as exc:
        print(f"[memory] error guardando episodio: {exc}", flush=True)


def db_last_episodes(limit=5):
    try:
        with _db_lock:
            conn = _db_connect()
            cur = conn.execute(
                "SELECT id, ts, goal, result, status FROM episodes ORDER BY id DESC LIMIT ?",
                (limit,))
            rows = [{"id": r[0], "ts": r[1], "goal": r[2], "result": r[3], "status": r[4]}
                    for r in cur.fetchall()]
            conn.close()
            return rows
    except Exception as exc:
        print(f"[memory] error leyendo episodios: {exc}", flush=True)
        return []


def db_remember(key, value):
    ts = datetime.now(timezone.utc).isoformat()
    try:
        with _db_lock:
            conn = _db_connect()
            conn.execute(
                "INSERT INTO kv (key, value, ts) VALUES (?,?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value, ts=excluded.ts",
                (key, value, ts))
            conn.commit()
            conn.close()
        return f"OK: remembered '{key}'"
    except Exception as exc:
        return f"ERROR: {exc}"


def db_recall(key):
    try:
        with _db_lock:
            conn = _db_connect()
            cur = conn.execute("SELECT value, ts FROM kv WHERE key = ?", (key,))
            row = cur.fetchone()
            conn.close()
        if row:
            return f"{row[0]}  (saved at {row[1]})"
        return f"NOT FOUND: no memory for key '{key}'"
    except Exception as exc:
        return f"ERROR: {exc}"


def db_wipe_memory():
    with _db_lock:
        conn = _db_connect()
        cur = conn.execute("SELECT COUNT(*) FROM episodes")
        n = cur.fetchone()[0]
        conn.execute("DELETE FROM episodes")
        conn.execute("DELETE FROM kv")
        conn.commit()
        conn.close()
    return n


# ---------------------------------------------------------------------------
# Logs JSONL por goal
# ---------------------------------------------------------------------------


def goal_log(goal_id, event, data):
    try:
        os.makedirs(LOGS_DIR, exist_ok=True)
        entry = {"ts": datetime.now(timezone.utc).isoformat(), "event": event, "data": data}
        with open(os.path.join(LOGS_DIR, f"{goal_id}.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as exc:
        print(f"[log] error: {exc}", flush=True)


# ---------------------------------------------------------------------------
# Herramientas nativas (stdlib)
# ---------------------------------------------------------------------------


def tool_bash(command, timeout=30):
    try:
        proc = subprocess.Popen(
            command, shell=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            return {"exit_code": -1, "stdout": "", "stderr": "",
                    "error": f"timeout after {timeout}s"}
        return {
            "exit_code": proc.returncode,
            "stdout": stdout.decode("utf-8", errors="replace")[:20000],
            "stderr": stderr.decode("utf-8", errors="replace")[:5000],
        }
    except Exception as exc:
        return {"exit_code": -1, "stdout": "", "stderr": "", "error": str(exc)}


def tool_python(code):
    tmp = f"/tmp/agent_py_{uuid.uuid4().hex[:8]}.py"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(code)
        return tool_bash(f"python3 {tmp}", timeout=120)
    except Exception as exc:
        return {"exit_code": -1, "stdout": "", "stderr": "", "error": str(exc)}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def tool_read_file(path, limit=5000):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return {"exit_code": 0, "content": fh.read(int(limit))}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


def tool_write_file(path, content):
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return {"exit_code": 0, "bytes": len(content)}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


def tool_list_dir(path="/root"):
    try:
        return {"exit_code": 0, "path": path, "entries": sorted(os.listdir(path))}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


def tool_netscan(subnet="", ports="22,80,443,139,445,8080,5555,62078", timeout=2):
    """Descubrimiento de red 100% userspace (TCP connect + tabla ARP).
    Funciona dentro de proot, a diferencia de nmap -sn (raw sockets)."""
    import socket
    import concurrent.futures

    if not subnet:
        # detecta la subred leyendo /proc/net/route + ip local
        try:
            s_ = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s_.connect(("8.8.8.8", 80))
            local_ip = s_.getsockname()[0]
            s_.close()
            subnet = ".".join(local_ip.split(".")[:3]) + ".0/24"
        except Exception as exc:
            return {"exit_code": -1, "error": f"no pude detectar la subred: {exc}"}

    base = subnet.split("/")[0]
    parts = base.split(".")[:3]
    prefix = ".".join(parts)
    port_list = []
    for tok in str(ports).split(","):
        tok = tok.strip()
        if tok.isdigit():
            port_list.append(int(tok))

    found = {}

    def probe(host):
        open_ports = []
        for port in port_list:
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sk:
                    sk.settimeout(timeout)
                    if sk.connect_ex((host, port)) == 0:
                        open_ports.append(port)
            except Exception:
                pass
        if open_ports:
            found[host] = open_ports

    # 1) TCP connect sweep en paralelo (marca hosts con puertos abiertos)
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
        list(ex.map(probe, [f"{prefix}.{i}" for i in range(1, 255)]))

    # 2) complementa con la tabla ARP (hosts vivos aunque no tengan puertos de la lista)
    arp_hosts = {}
    try:
        with open("/proc/net/arp", "r") as fh:
            for line in fh.readlines()[1:]:
                cols = line.split()
                if len(cols) >= 6 and cols[2] != "0x0" and cols[5] != "00:00:00:00:00:00":
                    ip, mac = cols[0], cols[4]
                    if ip.startswith(prefix + "."):
                        arp_hosts[ip] = mac
    except Exception:
        pass

    hosts = []
    for ip in sorted(set(found) | set(arp_hosts),
                     key=lambda x: int(x.split(".")[-1])):
        hosts.append({
            "ip": ip,
            "mac": arp_hosts.get(ip, ""),
            "open_ports": found.get(ip, []),
        })

    return {
        "exit_code": 0,
        "subnet": f"{prefix}.0/24",
        "hosts_found": len(hosts),
        "hosts": hosts,
        "method": "tcp-connect + arp-table (proot safe)",
    }


def tool_netmap(subnet="", output="/root/scan_red.png"):
    """Escanea la LAN (netscan) y genera el mapa topologico PNG en una sola
    llamada. Determinista: no depende de que el modelo escriba codigo."""
    scan = tool_netscan(subnet=subnet)
    if scan.get("exit_code") != 0:
        return scan
    hosts = scan["hosts"]

    # script de dibujo con matplotlib (si falta, intenta instalarlo)
    draw = f"""
import json, math, sys
hosts = json.loads('{json.dumps(hosts)}')
out = {output!r}
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit(42)

n = max(len(hosts), 1)
fig, ax = plt.subplots(figsize=(10, 8))
fig.patch.set_facecolor('#1C1C1E')
ax.set_facecolor('#1C1C1E')
ax.axis('off')
R = 3.0
colors = {{'router': '#FF9F0A', 'device': '#5E9BD6'}}
for i, h in enumerate(hosts):
    ang = 2 * math.pi * i / n
    x, y = R * math.cos(ang), R * math.sin(ang)
    is_router = h['ip'].endswith('.1')
    c = colors['router'] if is_router else colors['device']
    ax.plot([0, x], [0, y], color='#3A3A3C', lw=1.2, zorder=1)
    ax.scatter([x], [y], s=900, c=c, zorder=2, edgecolors='#EAEAEC', linewidths=1.2)
    label = h['ip']
    if h.get('mac'):
        label += '\\n' + h['mac']
    if h.get('open_ports'):
        label += '\\nports: ' + ','.join(map(str, h['open_ports'][:6]))
    ax.text(x, y - 0.55, label, ha='center', va='top',
            color='#EAEAEC', fontsize=8, zorder=3)
ax.scatter([0], [0], s=1200, c='#34C759', zorder=2, edgecolors='#EAEAEC')
ax.text(0, -0.55, 'XTR (este dispositivo)', ha='center', va='top',
        color='#EAEAEC', fontsize=9, zorder=3)
ax.set_title(f'Mapa de red — {{len(hosts)}} dispositivos', color='#EAEAEC', fontsize=13)
import os
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
plt.tight_layout()
plt.savefig(out, dpi=130, facecolor='#1C1C1E')
print('OK', out)
"""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as fh:
        fh.write(draw)
        script = fh.name
    res = tool_bash(f"python3 {script}", timeout=90)
    if res.get("exit_code") == 42 or "ModuleNotFoundError" in (res.get("stderr") or ""):
        # intenta instalar matplotlib y reintenta una vez
        tool_bash("pip install -q matplotlib 2>/dev/null || pip install -q --break-system-packages matplotlib", timeout=300)
        res = tool_bash(f"python3 {script}", timeout=90)
    try:
        import os as _os
        _os.unlink(script)
    except OSError:
        pass

    ok = res.get("exit_code") == 0 and os.path.exists(output)
    return {
        "exit_code": 0 if ok else -1,
        "image_path": output if ok else None,
        "hosts_found": scan["hosts_found"],
        "hosts": hosts,
        "subnet": scan["subnet"],
        "error": None if ok else (res.get("stderr") or "no se pudo generar el PNG"),
    }


def _listening_ports():
    """Puertos en escucha leyendo /proc/net/{tcp,tcp6,udp,udp6} (sin netlink:
    ss no funciona en proot)."""
    listening = []
    for proto, path in (("tcp", "/proc/net/tcp"), ("tcp6", "/proc/net/tcp6"),
                        ("udp", "/proc/net/udp"), ("udp6", "/proc/net/udp6")):
        try:
            with open(path) as fh:
                for line in fh.readlines()[1:]:
                    cols = line.split()
                    if len(cols) > 3 and cols[3] == "0A" if proto.startswith("tcp") else len(cols) > 3:
                        if proto.startswith("udp") and cols[3] != "07":
                            continue
                        addr = cols[1]
                        port = int(addr.split(":")[1], 16)
                        if port not in [p_ for _, p_ in listening]:
                            listening.append((proto, port))
        except Exception:
            pass
    return sorted(listening, key=lambda x: x[1])


def tool_audit(output="/root/audit_security.md"):
    """Auditoria de seguridad local determinista. Genera informe Markdown con
    severidades y recomendaciones. No depende del modelo."""
    findings = []   # (severidad, titulo, detalle)
    report = []

    # 1) usuarios con shell real
    shell_users = []
    try:
        with open("/etc/passwd") as fh:
            for line in fh:
                parts = line.strip().split(":")
                if len(parts) >= 7 and not parts[6].endswith("nologin") \
                        and parts[6] not in ("/bin/false", "/bin/sync", ""):
                    shell_users.append(f"{parts[0]} ({parts[6]})")
    except Exception as exc:
        shell_users.append(f"error: {exc}")
    if len(shell_users) > 1:
        findings.append(("media", "Multiples usuarios con shell",
                         "; ".join(shell_users)))
    else:
        findings.append(("baja", "Solo root tiene shell", "; ".join(shell_users)))

    # 2) puertos en escucha (via /proc, proot-safe)
    ports = _listening_ports()
    risky = {21: "FTP sin cifrar", 23: "Telnet", 3306: "MySQL expuesto",
             5432: "PostgreSQL expuesto", 5555: "ADB abierto",
             3389: "RDP", 6379: "Redis sin auth por defecto"}
    for proto, port in ports:
        sev = "alta" if port in risky else "info"
        findings.append((sev, f"Puerto {port}/{proto} en escucha",
                         risky.get(port, "servicio desconocido — revisar")))

    # 3) SUID en rutas habituales
    suid = tool_bash("find /bin /sbin /usr/bin /usr/sbin -perm -4000 -type f 2>/dev/null | head -40", timeout=60)
    suid_files = [l for l in (suid.get("stdout") or "").splitlines() if l.strip()]
    known_suid = {"sudo", "su", "passwd", "mount", "umount", "ping", "chsh",
                  "chfn", "newgrp", "gpasswd", "pppd", "proot", "busybox"}
    odd = [f for f in suid_files
           if f.split("/")[-1] not in known_suid]
    if odd:
        findings.append(("media", f"{len(odd)} binarios SUID no habituales",
                         "\n".join(odd[:15])))

    # 4) SSH config
    for cfg in ("/etc/ssh/sshd_config", "/etc/ssh/ssh_config"):
        try:
            with open(cfg) as fh:
                for line in fh:
                    l_ = line.strip().lower()
                    if l_.startswith("permitrootlogin") and "yes" in l_:
                        findings.append(("alta", "SSH permite login como root", cfg))
                    if l_.startswith("passwordauthentication") and "yes" in l_:
                        findings.append(("media", "SSH permite autenticacion por password", cfg))
        except Exception:
            pass

    # 5) actualizaciones pendientes
    upd = tool_bash("apt list --upgradable 2>/dev/null | grep -c upgradable || true", timeout=60)
    n_upd = (upd.get("stdout") or "0").strip()
    if n_upd.isdigit() and int(n_upd) > 0:
        findings.append(("media", f"{n_upd} paquetes con actualizacion pendiente",
                         "ejecuta: apt-get upgrade -y"))

    # ── informe markdown ──
    order = {"alta": 0, "media": 1, "baja": 2, "info": 3}
    findings.sort(key=lambda f: order.get(f[0], 9))
    ts = datetime.now().strftime("%Y-%m-%d %H:%M")
    report.append("# Auditoria de seguridad — XTR Terminal")
    report.append(f"_Generada: {ts}_\n")
    alta = sum(1 for f in findings if f[0] == "alta")
    media = sum(1 for f in findings if f[0] == "media")
    report.append(f"**Resumen**: {alta} altas · {media} medias · "
                  f"{len(findings) - alta - media} informativas/bajas\n")
    report.append("## Hallazgos\n")
    icon = {"alta": "🔴", "media": "🟠", "baja": "🟡", "info": "ℹ️"}
    for sev, title, det in findings:
        report.append(f"### {icon.get(sev, '')} [{sev.upper()}] {title}")
        report.append(f"```\n{det}\n```\n")
    report.append("## Recomendaciones de hardening\n")
    report.append("1. Deshabilita login root por SSH (PermitRootLogin no).")
    report.append("2. Actualiza paquetes: `apt-get update && apt-get upgrade -y`.")
    report.append("3. Cierra o protege con firewall los puertos marcados en ALTA.")
    report.append("4. Revisa binarios SUID no habituales (`chmod u-s` si no los necesitas).")
    report.append("5. Usa claves SSH en lugar de contraseñas.")

    content = "\n".join(report)
    try:
        parent = os.path.dirname(output)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(output, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError as exc:
        return {"exit_code": -1, "error": str(exc)}

    return {
        "exit_code": 0,
        "report_path": output,
        "severity_summary": {"alta": alta, "media": media,
                             "total": len(findings)},
        "shell_users": shell_users,
        "listening_ports": [f"{p_}/{pr}" for pr, p_ in ports],
        "suid_unusual": odd[:15],
    }


TOOLS = {
    "bash": (tool_bash, "Run any shell command. Args: command (str), timeout (int, default 30)"),
    "python": (tool_python, "Execute Python code. Args: code (str)"),
    "read_file": (tool_read_file, "Read a text file. Args: path (str), limit (int, default 5000)"),
    "write_file": (tool_write_file, "Write a file. Args: path (str), content (str)"),
    "list_dir": (tool_list_dir, "List directory contents. Args: path (str, default /root)"),
    "audit": (tool_audit, "Run a full local security audit and write a Markdown report (users, listening ports via /proc, SUID, SSH config, pending updates, severity + hardening). Args: output (str, default /root/audit_security.md). Use this for ANY security audit request."),
    "netmap": (tool_netmap, "Scan the LAN AND generate the topology map PNG in one call. Args: subnet (str, optional), output (str, default /root/scan_red.png). Returns image_path + hosts JSON. Use this for any network map request."),
    "netscan": (tool_netscan, "Discover hosts on the LAN (proot-safe TCP connect + ARP table). Args: subnet (str, optional, auto-detected), ports (str, comma list), timeout (int, default 2). Returns JSON with hosts, macs and open ports."),
    "remember": (None, "Store a persistent note. Args: key (str), value (str)"),
    "recall": (None, "Retrieve a persistent note. Args: key (str)"),
}


def _normalize_args(name, args):
    """Qwen3 a veces copia el ejemplo literal {"k":"v"} del prompt y manda
    {"k": "...", "v": "el valor real"}. Rescata el payload real."""
    if not isinstance(args, dict):
        return args
    primary = {"bash": "command", "python": "code", "read_file": "path",
               "write_file": "path", "list_dir": "path", "netscan": "subnet",
               "netmap": "subnet", "audit": "output"}.get(name)
    if primary and primary not in args:
        if "v" in args:
            args = dict(args); args[primary] = args.pop("v"); args.pop("k", None)
        elif "command" not in args and len(args) == 1:
            args = {primary: next(iter(args.values()))}
    return args


def execute_tool(name, args):
    args = _normalize_args(name, args)
    if name == "remember":
        return {"exit_code": 0, "output": db_remember(str(args.get("key", "")), str(args.get("value", "")))}
    if name == "recall":
        return {"exit_code": 0, "output": db_recall(str(args.get("key", "")))}
    entry = TOOLS.get(name)
    if not entry or entry[0] is None:
        return {"exit_code": -1, "error": f"unknown tool: {name}"}
    func = entry[0]
    try:
        import inspect
        sig = inspect.signature(func)
        filtered = {k: v for k, v in args.items() if k in sig.parameters}
        return func(**filtered)
    except TypeError as exc:
        return {"exit_code": -1, "error": f"bad args for {name}: {exc}"}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


# ---------------------------------------------------------------------------
# Cliente LLM (urllib, API OpenAI-compatible)
# ---------------------------------------------------------------------------


def _http_get(url, timeout=5.0):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {LLM_API_KEY}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


def _http_post_json(url, payload, timeout=180.0, api_key=None):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key or LLM_API_KEY}",
        })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


def check_backend_alive():
    """Vivo si el servidor LLM responde HTTP (cualquier codigo) en /models."""
    try:
        status, _ = _http_get(f"{LLM_BASE_URL}/models", timeout=5.0)
        return status == 200
    except urllib.error.HTTPError:
        return True  # respondio algo: el puerto esta vivo
    except Exception:
        return False


def llm_chat(messages, base_url=None, model=None, api_key=None):
    base_url = (base_url or LLM_BASE_URL).rstrip("/")
    model = model or LLM_MODEL
    api_key = api_key or LLM_API_KEY
    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.15,
        "top_p": 0.9,
        "top_k": 40,
        "max_tokens": 640,
    }
    url = f"{base_url}/chat/completions"
    try:
        status, raw = _http_post_json(url, payload, timeout=180.0, api_key=api_key)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        raise RuntimeError(
            f"LLM HTTP {exc.code} en {url} (model={model}). "
            f"Respuesta: {body or exc.reason}. "
            f"Revisa LLM_BASE_URL/LLM_MODEL y que MediaPipe este sirviendo el modelo.")
    data = json.loads(raw)
    return data["choices"][0]["message"]["content"]


# ---------------------------------------------------------------------------
# Parseo <tool>/<args>/<final>
# ---------------------------------------------------------------------------


def parse_tool_calls(text):
    calls = []
    pos = 0
    while True:
        t_start = text.find("<tool>", pos)
        if t_start == -1:
            break
        t_end = text.find("</tool>", t_start)
        a_start = text.find("<args>", t_end)
        a_end = text.find("</args>", a_start)
        if t_end == -1 or a_start == -1 or a_end == -1:
            break
        name = text[t_start + 6:t_end].strip()
        raw_args = text[a_start + 6:a_end].strip()
        try:
            args = json.loads(raw_args)
        except json.JSONDecodeError:
            args = {"_raw": raw_args, "_error": "invalid JSON args"}
        calls.append({"tool": name, "args": args})
        pos = a_end + 7
    return calls


def parse_final(text):
    f_start = text.find("<final>")
    if f_start == -1:
        return None
    f_end = text.find("</final>", f_start)
    if f_end == -1:
        return text[f_start + 7:].strip()
    return text[f_start + 7:f_end].strip()


# ---------------------------------------------------------------------------
# Compresión de contexto
# (Gemma local: 4096 tokens; Qwen3-4B-Instruct-2507 litertlm: 2048.
#  Presupuesto seguro para el peor caso: ~4000 chars ~= 1000-1300 tokens,
#  dejando sitio para la respuesta del modelo dentro de 2048.)
# ---------------------------------------------------------------------------

MAX_CONTEXT_CHARS = 4000  # ~1000-1300 tokens, cabe en ctx 2048 de Qwen3


def _compress_context(messages):
    """Mantiene el historial por debajo del límite de contexto del LLM local.

    Estrategia: conserva system prompt + goal original + los últimos mensajes;
    los mensajes antiguos de herramientas se resumen a 300 chars y, si sigue
    sin caber, se eliminan los más antiguos (el estado real está en memoria).
    """
    def total():
        return sum(len(m.get("content") or "") for m in messages)

    if total() <= MAX_CONTEXT_CHARS:
        return

    # 1) resume tool results antiguos (todos menos los 4 últimos mensajes)
    for i in range(2, max(2, len(messages) - 4)):
        c = messages[i].get("content") or ""
        if len(c) > 300:
            role = messages[i].get("role", "")
            tag = "TOOL RESULT (old, summarized)" if c.startswith("TOOL RESULT") else role
            messages[i]["content"] = f"[{tag}] {c[:300]}..."

    # 2) si aun no cabe, elimina los mensajes intermedios mas antiguos
    while total() > MAX_CONTEXT_CHARS and len(messages) > 6:
        del messages[2]
        # limpia el aviso tras el goal para que el historial siga teniendo sentido

    goal_log("ctx", "compressed", {"messages": len(messages), "chars": total()})


# ---------------------------------------------------------------------------
# Bucle agéntico (threading)
# ---------------------------------------------------------------------------

GOALS = {}
_goals_lock = threading.Lock()


def _build_system_prompt():
    prompt = SYSTEM_PROMPT
    # Memoria corta: con ctx de 2048 (Qwen3 litertlm) el system prompt
    # no puede crecer sin control; 3 episodios x 120 chars max.
    episodes = db_last_episodes(3)
    if episodes:
        prompt += "\n## RECENT MEMORY\n"
        for ep in episodes:
            result = (ep["result"] or "")[:120]
            prompt += f"- [{ep['status']}] {ep['goal']}: {result}\n"
    return prompt


def agent_loop(goal, goal_id, max_steps, event_cb=None, llm_overrides=None):
    """Bucle agéntico síncrono (corre en un hilo). event_cb(event, data) opcional."""
    ov = llm_overrides or {}
    state = GOALS[goal_id]
    deadline = time.time() + AGENT_GOAL_TIMEOUT

    messages = [
        {"role": "system", "content": _build_system_prompt()},
        {"role": "user", "content": f"GOAL: {goal}"},
    ]

    def emit(event, data):
        goal_log(goal_id, event, data)
        if event_cb:
            event_cb(event, data)

    emit("goal_start", {"goal": goal, "max_steps": max_steps})

    final_text = None
    status = "failed"

    for step_num in range(1, max_steps + 1):
        if time.time() > deadline:
            status = "timeout"
            emit("timeout", {"step": step_num})
            break

        state["current_step"] = step_num
        emit("step", {"step": step_num, "max_steps": max_steps})

        _compress_context(messages)
        try:
            reply = llm_chat(messages, base_url=ov.get("base_url"),
                             model=ov.get("model"), api_key=ov.get("api_key"))
        except Exception as exc:
            err = f"LLM error: {exc}"
            emit("error", {"step": step_num, "error": err})
            if "too long" in err or "Exceeding the maximum" in err:
                # Contexto desbordado: NO añadir el error al historial
                # (cada reintento sumaba +100 tokens y nunca convergia).
                # 1) cambia al system prompt compacto (cabe en ctx 2048)
                # 2) recorta los mensajes intermedios y reintenta.
                messages[0] = {"role": "system",
                               "content": SYSTEM_PROMPT_COMPACT}
                while len(messages) > 4:
                    del messages[2]
                messages.append({"role": "system", "content": (
                    "Context trimmed. /no_think — act NOW with only "
                    "<tool>...</tool><args>{...}</args> or <final>...</final>.")})
                goal_log("ctx", "emergency_trim", {"messages": len(messages)})
            else:
                messages.append({"role": "system", "content": err[:400]})
            continue

        emit("chunk", {"step": step_num, "text": reply})

        # Qwen3 "piensa en voz alta" con <think>…</think> y se gasta todo el
        # presupuesto de respuesta sin llegar a la herramienta. Se recorta
        # TODO el razonamiento antes de parsear y de guardar en el historial.
        import re as _re_think
        clean = _re_think.sub(r"<think>.*?</think>", " ", reply,
                              flags=_re_think.DOTALL)
        clean = _re_think.sub(r"<think>.*$", " ", clean,
                              flags=_re_think.DOTALL).strip()  # think sin cerrar
        if not clean:
            messages.append({"role": "system", "content": (
                "Do NOT think aloud. /no_think — Reply with ONLY "
                "<tool>…</tool><args>{…}</args> or <final>…</final>, "
                "nothing else.")})
            emit("nudge", {"step": step_num, "reason": "think_stripped"})
            continue
        reply = clean
        messages.append({"role": "assistant", "content": reply})

        final_text = parse_final(reply)
        if final_text is not None:
            status = "done" if not final_text.startswith("BLOCKED:") else "failed"
            break

        calls = parse_tool_calls(reply)
        if not calls:
            messages.append({"role": "system", "content": (
                "You must act. Use <tool>...</tool><args>{...}</args> or "
                "finish with <final>...</final>.")})
            emit("nudge", {"step": step_num})
            continue

        for call in calls:
            name, args = call["tool"], call["args"]
            emit("tool_call", {"step": step_num, "tool": name, "args": args})

            result = execute_tool(name, args)
            emit("tool_result", {"step": step_num, "tool": name, "result": result})

            state["steps"].append(
                {"step": step_num, "tool": name, "args": args, "result": result})

            obs = f"TOOL RESULT [{name}]: {json.dumps(result, ensure_ascii=False)[:900]}"
            messages.append({"role": "user", "content": obs})

            if result.get("exit_code", 0) != 0 or result.get("error"):
                messages.append({"role": "system", "content": (
                    "The command failed. Analyze the error and try a different "
                    "approach. Do NOT give up.")})
                emit("recovery", {"step": step_num, "tool": name})
    else:
        final_text = f"BLOCKED: reached max_steps ({max_steps}) without a final answer"

    if final_text is None and status == "timeout":
        final_text = f"BLOCKED: goal timeout after {AGENT_GOAL_TIMEOUT}s"

    # Red de seguridad anti-alucinación: si el final menciona archivos de
    # imagen que no existen, lo dejamos claro en la respuesta
    if final_text:
        import re as _re2
        mentioned = _re2.findall(r"(/(?:root|tmp)/[^\s\"\'()]*\.(?:png|jpe?g|gif|webp))", final_text)
        missing = [m for m in set(mentioned) if not os.path.exists(m)]
        if missing:
            final_text += ("\n\n[aviso: estos archivos NO se llegaron a crear: "
                           + ", ".join(missing) + "]")
            if status == "done":
                status = "failed"  # afirmo exito sin evidencia

    state["status"] = status
    state["result"] = final_text
    state["finished_at"] = datetime.now(timezone.utc).isoformat()

    db_save_episode(goal, state["steps"], final_text or "", status)
    emit("final", {"status": status, "result": final_text})
    return state


# ---------------------------------------------------------------------------
# Servidor HTTP stdlib
# ---------------------------------------------------------------------------


def _sse(event, data):
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


class AgentHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"XTRAgent/{VERSION}"

    # -- utilidades ---------------------------------------------------------

    def _send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _read_body_bytes(self):
        """Lee el body tanto con Content-Length como con Transfer-Encoding: chunked."""
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                if b";" in size_line:
                    size_line = size_line.split(b";", 1)[0]
                try:
                    size = int(size_line, 16)
                except ValueError:
                    break
                if size == 0:
                    # trailer / fin de chunks
                    while True:
                        line = self.rfile.readline()
                        if line in (b"\r\n", b"\n", b""):
                            break
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.readline()  # CRLF tras cada chunk
            return b"".join(chunks)
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _read_json_body(self):
        raw = self._read_body_bytes()
        if not raw:
            # Ultimo recurso: leer lo que quede con timeout corto (clientes raros)
            try:
                import socket
                self.connection.settimeout(0.5)
                extra = b""
                while True:
                    try:
                        chunk = self.connection.recv(65536)
                        if not chunk:
                            break
                        extra += chunk
                    except socket.timeout:
                        break
                raw = extra
            except Exception:
                pass
        if not raw:
            return {"_empty_body": True,
                    "_headers": {k: v for k, v in self.headers.items()}}
        try:
            return json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError:
            return {"_bad_json": True, "_raw": raw.decode("utf-8", errors="replace")[:500],
                    "_headers": {k: v for k, v in self.headers.items()}}

    def _query(self):
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        return parsed.path, {k: v[0] for k, v in qs.items()}

    def log_message(self, fmt, *args):  # log compacto
        print(f"[http] {fmt % args}", flush=True)

    # -- GET -----------------------------------------------------------------

    def do_GET(self):
        path, qs = self._query()
        if path == "/health":
            alive = check_backend_alive()
            self._send_json({
                "status": "ok" if alive else "degraded",
                "version": VERSION,
                "backend": {"url": LLM_BASE_URL, "alive": alive, "model": LLM_MODEL},
                "gpu_server_alive": alive,
                "pid": os.getpid(),
            })
        elif path == "/tools":
            self._send_json({"tools": [
                {"name": n, "description": d} for n, (_, d) in TOOLS.items()]})
        elif path == "/gpu/status":
            alive = check_backend_alive()
            info = {"alive": alive, "url": LLM_BASE_URL, "model": LLM_MODEL}
            if alive:
                try:
                    _, raw = _http_get(f"{LLM_BASE_URL}/models", timeout=5.0)
                    info["models"] = json.loads(raw)
                except Exception:
                    pass
            self._send_json(info)
        elif path == "/goal/status":
            goal_id = qs.get("goal_id", "")
            state = GOALS.get(goal_id)
            if not state:
                self._send_json({"error": f"unknown goal_id: {goal_id}"}, status=404)
                return
            self._send_json({
                "goal_id": goal_id,
                "status": state["status"],
                "current_step": state["current_step"],
                "max_steps": state["max_steps"],
                "steps": state["steps"],
                "result": state["result"],
            })
        elif path == "/goal/list":
            self._send_json({"goals": [{
                "goal_id": g["goal_id"],
                "goal": g["goal"],
                "status": g["status"],
                "current_step": g["current_step"],
                "max_steps": g["max_steps"],
                "started_at": g.get("started_at"),
                "finished_at": g.get("finished_at"),
            } for g in GOALS.values()]})
        elif path == "/file":
            fp = qs.get("path", "")
            if not fp:
                self._send_json({"error": "missing path"}, status=400)
                return
            self._serve_file(fp)
        elif path == "/files/images":
            self._send_json({"images": self._list_images()})
        elif path == "/memory":
            try:
                limit = max(1, min(100, int(qs.get("limit", "10"))))
            except ValueError:
                limit = 10
            self._send_json({"episodes": db_last_episodes(limit)})
        else:
            self._send_json({"error": f"not found: {path}"}, status=404)

    # -- Imagenes -------------------------------------------------------------

    _IMG_EXT = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml"}

    def _serve_file(self, path):
        """Sirve un archivo de imagen (restringido a /root y /tmp)."""
        import os.path
        path = os.path.realpath(path)
        if not (path.startswith("/root/") or path.startswith("/tmp/")):
            self._send_json({"error": "solo se sirven archivos de /root y /tmp"}, status=403)
            return
        ext = os.path.splitext(path)[1].lower()
        mime = self._IMG_EXT.get(ext)
        if not mime:
            self._send_json({"error": "tipo no soportado"}, status=415)
            return
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            self._send_json({"error": str(exc)}, status=404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _list_images(self):
        """Lista las imagenes generadas en /root (mas recientes primero)."""
        import glob
        files = []
        for ext in ("png", "jpg", "jpeg", "gif", "webp"):
            files.extend(glob.glob(f"/root/**/*.{ext}", recursive=True))
            files.extend(glob.glob(f"/tmp/agent*.{ext}"))
        out = []
        for f in files:
            try:
                st = os.stat(f)
                out.append({"path": f, "bytes": st.st_size,
                            "mtime": int(st.st_mtime),
                            "name": os.path.basename(f)})
            except OSError:
                pass
        out.sort(key=lambda x: x["mtime"], reverse=True)
        return out[:50]

    # -- DELETE ---------------------------------------------------------------

    def do_DELETE(self):
        path, qs = self._query()
        if path == "/memory":
            if qs.get("confirm") != "yes":
                self._send_json(
                    {"error": "refused: pass ?confirm=yes to wipe all memory"},
                    status=400)
                return
            deleted = db_wipe_memory()
            self._send_json({"status": "wiped", "episodes_deleted": deleted})
        else:
            self._send_json({"error": f"not found: {path}"}, status=404)

    # -- POST -----------------------------------------------------------------

    def do_POST(self):
        path, _ = self._query()
        body = self._read_json_body()

        if path in ("/run", "/chat"):
            message = (body.get("message") or body.get("task") or
                       body.get("goal") or body.get("prompt") or
                       body.get("text") or body.get("input") or "")
            if not message:
                # Diagnostico: devolvemos lo que llego para poder depurar
                self._send_json({
                    "error": "missing 'message'",
                    "debug": body,
                    "hint": "El server espera JSON: {\"message\": \"...\"} "
                            "(tambien acepta goal/prompt/text/input)",
                }, status=400)
                return
            max_steps = int(body.get("max_steps") or AGENT_MAX_STEPS)
            overrides = {
                "base_url": body.get("llm_base_url") or None,
                "model": body.get("llm_model") or None,
                "api_key": body.get("llm_api_key") or None,
            }
            self._run_sse(message, max_steps, overrides)

        elif path == "/goal":
            goal = body.get("goal") or ""
            if not goal:
                self._send_json({"error": "missing 'goal'"}, status=400)
                return
            goal_id = uuid.uuid4().hex[:12]
            max_steps = int(body.get("max_steps") or AGENT_MAX_STEPS)
            with _goals_lock:
                GOALS[goal_id] = {
                    "goal_id": goal_id, "goal": goal, "status": "running",
                    "current_step": 0, "max_steps": max_steps,
                    "steps": [], "result": None,
                    "started_at": datetime.now(timezone.utc).isoformat(),
                }
            threading.Thread(
                target=agent_loop, args=(goal, goal_id, max_steps),
                daemon=True).start()
            self._send_json({"goal_id": goal_id, "status": "running"})

        else:
            self._send_json({"error": f"not found: {path}"}, status=404)

    # -- SSE /run --------------------------------------------------------------

    def _run_sse(self, message, max_steps, overrides=None):
        goal_id = f"run-{uuid.uuid4().hex[:12]}"
        with _goals_lock:
            GOALS[goal_id] = {
                "goal_id": goal_id, "goal": message, "status": "running",
                "current_step": 0, "max_steps": max_steps,
                "steps": [], "result": None,
                "started_at": datetime.now(timezone.utc).isoformat(),
            }

        import queue as _queue
        q = _queue.Queue()

        def send(data):
            q.put(f"data: {json.dumps(data, ensure_ascii=False)}\n\n")

        def _summ(result):
            out = result.get("stdout") or result.get("output") or result.get("content") or ""
            if not out and result.get("error"):
                out = f"ERROR: {result['error']}"
            if not out and result.get("stderr"):
                out = result["stderr"]
            return str(out)[:2000]

        def event_cb(event, data):
            # Formato que espera agent_chat.dart: {type: step|final|error, ...}
            if event == "chunk":
                # texto "pensado" sin el marcado de herramientas
                txt = data.get("text", "")
                for tag in ("<final>", "</final>"):
                    txt = txt.replace(tag, "")
                import re as _re
                txt = _re.sub(r"<tool>.*?</args>", "", txt, flags=_re.S).strip()
                if txt:
                    send({"type": "step", "step": data.get("step"), "thought": txt})
            elif event == "tool_call":
                send({"type": "step", "step": data.get("step"),
                      "tool_calls": [{"name": data.get("tool"),
                                      "arguments": data.get("args")}]})
            elif event == "tool_result":
                send({"type": "step", "step": data.get("step"),
                      "observation": _summ(data.get("result") or {})})
            elif event == "error":
                send({"type": "error", "error": data.get("error", "error")})
            elif event == "final":
                send({"type": "final", "answer": data.get("result") or ""})

        def run_agent():
            try:
                agent_loop(message, goal_id, max_steps, event_cb=event_cb,
                           llm_overrides=overrides)
            except Exception as exc:
                send({"type": "error", "error": str(exc)})
            finally:
                q.put(None)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "close")
        self.end_headers()

        threading.Thread(target=run_agent, daemon=True).start()
        try:
            while True:
                item = q.get()
                if item is None:
                    break
                self.wfile.write(item.encode("utf-8"))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # el cliente cerró el stream
        finally:
            self.close_connection = True  # cierra al terminar: fin del stream


# ---------------------------------------------------------------------------
# Entrada principal
# ---------------------------------------------------------------------------


def main():
    os.makedirs(MEMORY_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)
    _db_connect().close()
    try:
        with open(AGENT_PID_FILE, "w") as fh:
            fh.write(str(os.getpid()))
    except OSError as exc:
        print(f"[startup] no se pudo escribir PID file: {exc}", flush=True)

    server = ThreadingHTTPServer(("127.0.0.1", AGENT_PORT), AgentHandler)
    print(f"[startup] XTR Agent Server v{VERSION} (stdlib) en 127.0.0.1:{AGENT_PORT} "
          f"(pid {os.getpid()})", flush=True)
    print(f"[startup] LLM: {LLM_BASE_URL} model={LLM_MODEL}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
