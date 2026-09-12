# XTR Agent Server v14.9 — Autonomous (stdlib puro: CERO pip, CERO fastapi/httpx)
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
AGENT_GOAL_TIMEOUT = int(os.environ.get("AGENT_GOAL_TIMEOUT", "420"))

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8090/v1")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemma3-local")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "local")

MEMORY_DIR = "/root/agent_memory"
MEMORY_DB = os.path.join(MEMORY_DIR, "memory.db")
LOGS_DIR = os.path.join(MEMORY_DIR, "logs")

VERSION = "14.13"

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

ASSISTANT: The native netscan tool discovers live hosts, open ports, hostnames and MAC vendors in one call (it auto-detects the real LAN).
<tool>netscan</tool><args>{"subnet": "auto"}</args>

TOOL RESULT [netscan]: {"subnet": "192.168.10.0/24", "hosts": [{"ip": "192.168.10.1", "ports": [80, 443], "name": "router.local", "vendor": "Espressif"}, {"ip": "192.168.10.42", "ports": [22], "name": "server", "vendor": "Intel"}], "alive": 2}

ASSISTANT: Found 2 hosts. Now rendering the topology map with the native netmap tool (it reuses the scan).
<tool>netmap</tool><args>{"output": "/root/network_map.png"}</args>

TOOL RESULT [netmap]: {"exit_code": 0, "image_path": "/root/network_map.png", "hosts": 2}

ASSISTANT: Verifying the file exists before claiming success.
<tool>bash</tool><args>{"command": "ls -l /root/network_map.png"}</args>

TOOL RESULT [bash]: -rw-r--r-- 1 root root 48210 network_map.png

<final>Network scan complete. Found 2 devices on 192.168.10.0/24: the router (192.168.10.1, Espressif, HTTP/HTTPS) and a server (192.168.10.42, SSH). Map saved to /root/network_map.png.</final>

## RULES
- ALWAYS act. NEVER say "I can't" or "as an AI".
- Prefer doing over explaining. Show results, not intentions.
- If a command fails, analyze the error and try a different approach.
- NEVER claim a file was created/saved unless you verified it with ls. If a tool result contains an error, the task is NOT done — fix it first.
- If graphviz/dot is missing, install it (apt-get install -y graphviz) or fall back to matplotlib/networkx to render the PNG.
- If a command is not found (ip, netstat, htop...), install it with apt-get instead of giving up.
- For network scanning/mapping, ALWAYS use the native tool `netmap` — it scans AND renders the map PNG in one call. Do NOT write your own scanning/drawing code for this.
- For security audits, ALWAYS use the native tool `audit` — it produces the full Markdown report in one call. Do NOT write long one-liner shell scripts.
- Keep each bash command SHORT and SIMPLE (one command, no chains of echoes). Long one-liners with quotes always fail.
- NEVER write "TOOL RESULT" text yourself. Tool results are provided by the system only. Inventing tool output is a critical failure.
- PROOT ENVIRONMENT: raw sockets and netlink are BLOCKED inside this container. nmap ALWAYS fails here ("setup_target: failed to determine route") and the server REJECTS nmap commands — never call it, not even with --unprivileged. For host discovery/port scans use the native tools `netscan`/`netmap` (ping + TCP connect, proot-safe). `ss` and `ip neigh` also fail — read /proc directly if needed.
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
2. "netmap" is OUR topology-map tool, NOT a package. If the user asks to INSTALL something (htop, git...), use bash with apt: <tool>bash</tool><args>{"command": "apt-get install -y htop"}</args> — never confuse the tool with the package. nmap is REJECTED by the server: it cannot work in proot (no raw sockets), so installing it is pointless.
2. For LAN scans/maps: call `netscan` (or `netmap` for the PNG) with NO subnet — the tool AUTO-DETECTS the real LAN (e.g. 192.168.10.0/24). NEVER invent 192.168.1.0/24. Do NOT hand-write nmap pipelines — raw sockets fail in proot.
3. For security audits ALWAYS use tool `audit`.
4. NEVER invent TOOL RESULT text. Verify created files with list_dir before claiming success.
5. write_file only writes TEXT — it CANNOT create images (.png/.jpg...). Images are generated with python + matplotlib (or the netmap tool for maps).
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
    # v14.13: nmap NUNCA funciona dentro de proot (raw sockets/netlink
    # capados) pero devuelve exit 0 con "failed to determine route", lo que
    # enganchaba al modelo en bucles de reintentos. Se bloquea SOLO cuando
    # se invoca como comando (inicio, tras pipe/;/&&/$(...) — mencionarlo
    # como argumento (apt-cache search nmap) no se bloquea.
    import re as _re_sh
    if _re_sh.search(r"(^|[|;&(]|\&\&|\|\|)\s*nmap\b", command):
        return {"exit_code": -1, "stdout": "", "stderr": "",
                "error": "nmap NO funciona dentro de proot (sin raw "
                         "sockets): usa la herramienta nativa netscan "
                         "(descubrir hosts/puertos) o netmap (mapa PNG)."}
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


def _is_real_image(path):
    """True si el fichero empieza por magic bytes de imagen reales."""
    try:
        with open(path, "rb") as fh:
            head = fh.read(12)
        return head.startswith((b"\x89PNG", b"\xff\xd8\xff", b"GIF8",
                                b"RIFF", b"BM"))
    except OSError:
        return False


def tool_write_file(path, content):
    # Un .png escrito a mano con texto es un PNG FALSO (el modelo lo hace
    # cuando no sabe generar la imagen de verdad). Se rechaza: las imagenes
    # se generan con python+matplotlib o con las herramientas nativas.
    if os.path.splitext(str(path))[1].lower() in (
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"):
        return {"exit_code": -1,
                "error": "write_file solo escribe TEXTO; un archivo de "
                         "imagen creado asi es falso. Genera la imagen con "
                         "python + matplotlib (o usa netmap)."}
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


def _detect_local_subnet():
    """Subred /24 real del dispositivo (la IP local con ultimo octeto a 0)."""
    import socket
    s_ = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s_.connect(("8.8.8.8", 80))
        local_ip = s_.getsockname()[0]
    finally:
        s_.close()
    return ".".join(local_ip.split(".")[:3]) + ".0/24", local_ip


# --- Identificacion de hosts (nombres + fabricante + banners), proot-safe ---

# Prefijos OUI frecuentes en casa (primeros 3 bytes de la MAC).
_OUI = {
    "b8:27:eb": "Raspberry Pi", "dc:a6:32": "Raspberry Pi",
    "e4:5f:01": "Raspberry Pi",
    "00:1a:2b": "Cisco", "f4:03:2a": "Amazon", "44:65:0d": "Amazon",
    "a4:77:33": "Google", "f4:f5:d8": "Google", "54:60:09": "Google",
    "3c:5a:b4": "Google/Nest",
    "ac:63:be": "Amazon",
    "24:62:ab": "Espressif", "30:ae:a4": "Espressif", "24:6f:28": "Espressif",
    "84:f7:03": "Espressif", "a0:dd:6c": "Espressif", "10:52:1c": "Espressif",
    "8c:aa:b5": "Espressif", "ec:94:cb": "Espressif",
    "78:21:84": "Espressif", "48:3f:da": "Espressif",
    "00:0c:43": "Ralink/MediaTek",
    "50:c7:bf": "TP-Link", "30:b5:c2": "TP-Link", "f0:9f:c2": "TP-Link",
    "3c:46:d8": "TP-Link",
    "bc:71:58": "Netgear", "9c:3d:cf": "Netgear", "d0:54:2d": "Asus",
    "04:d4:c4": "Asus", "e0:3f:49": "Asus", "60:6c:66": "Intel",
    "b8:27:56": "Nintendo",
    "40:cb:c0": "Xiaomi", "64:09:80": "Xiaomi", "0c:1d:af": "Xiaomi",
    "34:ce:00": "Xiaomi", "50:8f:4c": "Xiaomi", "f8:a4:5f": "Xiaomi",
    "d4:d4:da": "Samsung", "cc:7a:ee": "Samsung", "e8:50:8b": "Samsung",
    "a0:82:1f": "Samsung", "88:32:9b": "Samsung", "c4:7a:8d": "Apple",
    "a4:83:e7": "Apple", "f0:18:98": "Apple", "dc:a9:04": "Apple",
    "88:63:df": "Apple", "64:5a:ed": "Apple", "f0:d1:a9": "Apple",
    "3c:a6:2f": "Apple", "bc:92:6b": "Apple", "d0:03:4b": "Apple",
    "78:67:0e": "Apple", "4c:32:75": "Apple", "2c:f0:ee": "Apple",
    "b8:64:91": "LG", "c4:42:02": "LG", "8c:3a:e3": "LG",
    "10:1f:74": "Sony", "30:52:cb": "Huawei", "ac:e2:15": "Huawei",
    "24:69:a5": "Huawei", "d0:9a:e0": "OnePlus", "c0:ee:fb": "OnePlus",
    "94:65:2d": "Motorola", "f8:2d:d7": "Motorola",
    "14:9f:3c": "Hon Hai/Foxconn", "74:d4:35": "Hon Hai/Foxconn",
    "00:15:5d": "Microsoft", "28:18:78": "Microsoft",
}


def _oui_vendor(mac):
    """Fabricante por prefijo OUI. 'random' si la MAC es local/randomizada."""
    if not mac:
        return ""
    mac = mac.lower()
    # MAC local/randomizada (bit 1 del primer octeto): tipica de iOS/Android
    try:
        first = int(mac.split(":")[0], 16)
        if first & 0x02:
            return "MAC aleatoria (privacidad)"
    except (ValueError, IndexError):
        pass
    return _OUI.get(":".join(mac.split(":")[:3]), "")


def _rdns(ip, timeout=1.5):
    """DNS inverso (el router suele tener nombres locales)."""
    import socket
    socket.setdefaulttimeout(timeout)
    try:
        return socket.gethostbyaddr(ip)[0]
    except Exception:
        return ""


def _netbios_name(ip, timeout=1.5):
    """NBSTAT por UDP 137: nombres Windows/SMB. Solo stdlib.
    Devuelve (nombre, mac): la respuesta de estado lleva el 'unit ID'
    (la MAC del adaptador) en los 6 bytes tras la tabla de nombres — muy
    util en Android 10+, donde /proc/net/arp esta capado por SELinux."""
    import socket
    import struct
    tid = 0xBEEF
    # Query NBSTAT '*': nombre codificado CKAAA... (32 chars) + tipo 0x0021
    pkt = struct.pack(">HHHHHH", tid, 0, 1, 0, 0, 0) + b"\x20" + \
        b"CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" + b"\x00\x00!\x00\x01"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(pkt, (ip, 137))
        data, _ = s.recvfrom(4096)
        name, mac = "", ""
        if len(data) > 57:
            names = []
            n = data[56]
            off = 57
            for _ in range(min(n, 10)):
                if off + 18 > len(data):
                    break
                nm = data[off:off + 15].decode("ascii", "replace").strip()
                typ = data[off + 15]
                if nm and typ == 0x00:
                    names.append(nm)
                off += 18
            name = names[0] if names else ""
            # estadisticas: primeros 6 bytes tras la tabla = unit ID (MAC)
            mac_off = 57 + 18 * n
            if mac_off + 6 <= len(data):
                raw = data[mac_off:mac_off + 6]
                if raw != b"\x00" * 6:
                    mac = ":".join("%02x" % b for b in raw)
        return name, mac
    except Exception:
        return "", ""
    finally:
        s.close()


def _mdns_name(ip, timeout=2.0):
    """mDNS (UDP 5353 multicast): nombres .local de iPhone/Android/IoT.
    Enviamos la query PTR de la IP y escuchamos respuestas unicast."""
    import socket
    import struct
    parts = ip.split(".")
    ptr = (".".join(reversed(parts)) + ".in-addr.arpa")
    q = b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    for part in ptr.split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00\x00\x0c\x00\x01"  # PTR, IN
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.settimeout(timeout)
    try:
        s.bind(("", 0))
        s.sendto(q, ("224.0.0.251", 5353))
        end = time.time() + timeout
        while time.time() < end:
            try:
                data, _ = s.recvfrom(4096)
            except socket.timeout:
                break
            # parsea respuestas buscando nombres .local
            txt = data
            i = 12
            while i < len(txt):
                if txt[i] == 0:
                    break
                if txt[i] & 0xC0:
                    i += 2
                    break
                i += txt[i] + 1
            # extraccion cruda pero robusta: cualquier cadena 'xxx.local'
            import re as _re_m
            m = _re_m.search(rb"([ -~]{2,63})\x05local\x00", data)
            if m:
                return m.group(1).decode("ascii", "replace")
    except Exception:
        return ""
    finally:
        s.close()


def _ping_supported():
    """True si el kernel permite ping-sockets a este proceso (Android si;
    algunos kernels endurecidos, no). Se prueba una vez por escaneo."""
    import socket
    try:
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM,
                      socket.IPPROTO_ICMP).close()
        return True
    except Exception:
        return False


def _ping_host(ip, timeout=0.7):
    """Ping ICMP por 'ping socket' (SOCK_DGRAM + IPPROTO_ICMP): Linux lo
    permite sin root ni raw sockets (net.ipv4.ping_group_range), asi que
    funciona en proot/Termux. Descubre hosts vivos AUNQUE no tengan
    ningun puerto TCP abierto (p.ej. el router HaLow 192.168.10.14)."""
    import socket
    import struct
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM,
                           socket.IPPROTO_ICMP) as sk:
            sk.settimeout(timeout)
            payload = b"XTRPING\x00\x01\x02\x03"
            def _cs(data):
                if len(data) % 2:
                    data += b"\x00"
                acc = 0
                for i in range(0, len(data), 2):
                    acc += (data[i] << 8) + data[i + 1]
                acc = (acc >> 16) + (acc & 0xFFFF)
                acc += acc >> 16
                return ~acc & 0xFFFF
            pid = os.getpid() & 0xFFFF
            hdr = struct.pack("!BBHHH", 8, 0, 0, pid, 1)
            pkt = struct.pack("!BBHHH", 8, 0, _cs(hdr + payload),
                              pid, 1) + payload
            t0 = time.time()
            sk.sendto(pkt, (ip, 0))
            while time.time() - t0 < timeout:
                try:
                    data, _addr = sk.recvfrom(64)
                except socket.timeout:
                    break
                if data and data[0] == 0:  # ICMP echo reply
                    return True
    except Exception:
        return False
    return False


def _ssdp_discover(timeout=2.0):
    """UPnP/SSDP M-SEARCH al multicast 239.255.255.250:1900: routers, TVs,
    consolas e IoT contestan con cabeceras SERVER y LOCATION (XML con
    friendlyName/manufacturer). Una sola escucha global de ~2 s."""
    import socket
    req = ("M-SEARCH * HTTP/1.1\r\n"
           "HOST: 239.255.255.250:1900\r\n"
           'MAN: "ssdp:discover"\r\n'
           "MX: 1\r\n"
           "ST: ssdp:all\r\n\r\n").encode()
    out = {}
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sk:
            sk.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sk.settimeout(timeout)
            sk.sendto(req, ("239.255.255.250", 1900))
            end = time.time() + timeout
            while time.time() < end:
                try:
                    data, (ip, _p) = sk.recvfrom(4096)
                except socket.timeout:
                    break
                txt = data.decode("latin-1", "replace")
                info = {}
                for line in txt.split("\r\n"):
                    if ":" not in line:
                        continue
                    k, v = line.split(":", 1)
                    k = k.strip().upper()
                    if k in ("SERVER", "LOCATION", "ST", "USN"):
                        info[k.lower()] = v.strip()[:120]
                if info and ip not in out:
                    out[ip] = info
    except Exception:
        pass
    return out


def _ssdp_fetch_info(location, timeout=1.2):
    """Descarga el XML de descripcion UPnP y extrae friendlyName +
    manufacturer (regex simple: el XML de estos aparatos es basico)."""
    import re as _re_s
    try:
        req = urllib.request.Request(
            location, headers={"User-Agent": "XTR/14.9"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            xml = r.read(20000).decode("utf-8", "replace")
        def _tag(name):
            m = _re_s.search(r"<%s>(.*?)</%s>" % (name, name), xml, _re_s.S)
            return m.group(1).strip()[:80] if m else ""
        return {"friendly": _tag("friendlyName"),
                "manufacturer": _tag("manufacturer")}
    except Exception:
        return {}


def _banner(ip, port, timeout=1.5):
    """Banner grabbing: lo que el servicio saluda. SSH/HTTP se identifican."""
    import socket
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sk:
            sk.settimeout(timeout)
            if sk.connect_ex((ip, port)) != 0:
                return ""
            if port in (80, 8080, 8000, 8888):
                sk.sendall(b"HEAD / HTTP/1.0\r\n\r\n")
            data = sk.recv(120).decode("ascii", "replace").strip()
            first = data.split("\n")[0].strip().replace("\r", "")[:80]
            return first
    except Exception:
        return ""


def identify_host(ip, mac="", ports=(), deep=True):
    """Resuelve nombre (mDNS > NetBIOS > DNS inverso) + fabricante OUI +
    banners de servicios. NetBIOS se consulta SIEMPRE en modo deep porque
    su respuesta tambien trae la MAC (unit ID), oro cuando Android capa
    la tabla ARP. Todo con timeouts cortos, en paralelo por host."""
    name = ""
    nb_mac = ""
    if deep:
        name = _mdns_name(ip)
        nb_name, nb_mac = _netbios_name(ip)
        if not name:
            name = nb_name
        if not name:
            name = _rdns(ip)
    mac = mac or nb_mac
    banners = {}
    if deep:
        for p in list(ports)[:4]:  # max 4 puertos por host para no eternizar
            b = _banner(ip, p)
            if b:
                banners[str(p)] = b
    return {"hostname": name, "mac": mac,
            "vendor": _oui_vendor(mac), "banners": banners}



# Cache de escaneos: netmap y netscan repetidos (el modelo suele llamarlos
# seguidos) reutilizan el resultado fresco en vez de re-barrer la LAN.
_SCAN_CACHE = {}
_SCAN_CACHE_TTL = 240.0  # segundos


def tool_netscan(subnet="", ports="22,80,443,139,445,554,1883,8080,8008,8009,8443,5555,62078,9100", timeout=2, deep=True):
    """Descubrimiento de red 100% userspace, en 3 fases:
    A) vida: ping ICMP (ping-socket, sin root) + sondas TCP rapidas — asi
       aparecen tambien hosts SIN puertos abiertos (router HaLow, etc).
    B) puertos: la lista completa SOLO contra los vivos (no 254 IPs).
    C) identificacion en paralelo: mDNS/NetBIOS(+MAC)/rDNS, OUI, banners
       y SSDP/UPnP (friendlyName + manufacturer).
    Funciona dentro de proot, a diferencia de nmap -sn (raw sockets)."""
    import socket
    import concurrent.futures

    note = ""
    # El modelo manda a veces subnet="auto" (palabra literal): equivale a "".
    if subnet and str(subnet).strip().lower() in ("auto", "auto-detect", "detect"):
        subnet = ""
    try:
        detected, local_ip = _detect_local_subnet()
    except Exception:
        detected, local_ip = "", ""
    if not subnet:
        if not detected:
            return {"exit_code": -1, "error": "no pude detectar la subred"}
        subnet = detected
    elif (detected and subnet != detected
          and subnet.startswith(("192.168.1.", "192.168.0."))):
        # El modelo INVENTA la subred estandar 192.168.1.0/24 (o .0.0/24)
        # aunque la LAN real sea otra (p.ej. 192.168.10.0/24). Solo se
        # corrige ese caso tipico; si el usuario pide otra red explicita,
        # se respeta.
        note = (f"subnet corregida: pediste {subnet} pero la IP local es "
                f"{local_ip} -> escaneo {detected}")
        subnet = detected

    base = subnet.split("/")[0]
    prefix = ".".join(base.split(".")[:3])
    port_list = []
    for tok in str(ports).split(","):
        tok = tok.strip()
        if tok.isdigit():
            port_list.append(int(tok))
    port_list = sorted(set(port_list))

    # Cache: mismo escaneo hecho hace < TTL -> respuesta inmediata.
    ckey = (prefix, tuple(port_list), bool(deep))
    ent = _SCAN_CACHE.get(ckey)
    if ent and time.time() - ent["time"] < _SCAN_CACHE_TTL:
        cached = json.loads(json.dumps(ent["result"]))  # copia
        cached["note"] = (cached.get("note", "") + " [cache]").strip()
        return cached

    # ---- FASE A: descubrimiento de vivos (~15-20 s en el peor caso) ----
    # ping ICMP (sin root) + sondas TCP cortas. Cada intento TCP ademas
    # puebla la cache ARP del kernel.
    probe_ports = [80, 443, 22, 445, 139, 8080, 21, 554, 62078]
    alive = {}
    icmp_ok = _ping_supported()

    def discover(host):
        up = _ping_host(host, 0.7) if icmp_ok else False
        open_probe = []
        for p in probe_ports:
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sk:
                    sk.settimeout(0.5)
                    if sk.connect_ex((host, p)) == 0:
                        up = True
                        open_probe.append(p)
            except Exception:
                pass
        if up:
            alive[host] = open_probe

    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
        list(ex.map(discover, [f"{prefix}.{i}" for i in range(1, 255)]))

    # Vecinos del kernel (si Android deja leerlos) + gateway + nosotros.
    arp_hosts = {}
    try:
        with open("/proc/net/arp", "r") as fh:
            for line in fh.readlines()[1:]:
                cols = line.split()
                # Formato real: IP  HWtype  Flags  HWaddress  Mask  Device
                # (la MAC es la COLUMNA 3, no la 4: la 4 es la Mask)
                if len(cols) >= 6 and cols[2] != "0x0":
                    ip, mac = cols[0], cols[3].lower()
                    if (mac != "00:00:00:00:00:00"
                            and ip.startswith(prefix + ".")):
                        arp_hosts[ip] = mac
                        alive.setdefault(ip, [])
    except Exception:
        pass
    try:
        out = subprocess.run(["ip", "neigh", "show"], capture_output=True,
                             text=True, timeout=10).stdout
        import re as _re_neigh
        for mip in _re_neigh.findall(
                r"^(" + _re_neigh.escape(prefix) + r"\.\d+)\s+.*lladdr\s+"
                r"([0-9a-f:]{17})", out, _re_neigh.M):
            arp_hosts.setdefault(mip[0], mip[1])
            alive.setdefault(mip[0], [])
    except Exception:
        pass
    gateway = ""
    try:
        with open("/proc/net/route", "r") as fh:
            for line in fh.readlines()[1:]:
                cols = line.split("\t")
                if len(cols) > 2 and cols[1] == "00000000":
                    gw = socket.inet_ntoa(bytes.fromhex(cols[2])[::-1])
                    if gw.startswith(prefix + "."):
                        gateway = gw
                        alive.setdefault(gw, [])
    except Exception:
        pass
    if local_ip:
        alive.setdefault(local_ip, [])

    # ---- FASE B: puertos completos SOLO contra los vivos (~2-5 s) ----
    found = {}
    full_list = sorted(set(port_list) | set(probe_ports))
    port_timeout = min(float(timeout), 1.5)

    def scan_ports(host):
        open_ = set(alive.get(host, []))
        for p in full_list:
            if p in open_:
                continue
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sk:
                    sk.settimeout(port_timeout)
                    if sk.connect_ex((host, p)) == 0:
                        open_.add(p)
            except Exception:
                pass
        found[host] = sorted(open_)

    with concurrent.futures.ThreadPoolExecutor(max_workers=48) as ex:
        list(ex.map(scan_ports, list(alive)))

    hosts = []
    for ip in sorted(alive, key=lambda x: int(x.split(".")[-1])):
        hosts.append({
            "ip": ip,
            "mac": arp_hosts.get(ip, ""),
            "open_ports": found.get(ip, []),
        })
    if local_ip:
        for h in hosts:
            if h["ip"] == local_ip:
                h["self"] = True

    # ---- FASE C: identificacion profunda en paralelo + SSDP global ----
    if deep and hosts:
        with concurrent.futures.ThreadPoolExecutor(max_workers=17) as ex:
            fut_ssdp = ex.submit(_ssdp_discover, 2.0)
            futures = {
                ex.submit(identify_host, h["ip"], h["mac"],
                          h["open_ports"], True): h
                for h in hosts}
            for fut in concurrent.futures.as_completed(futures):
                try:
                    futures[fut].update(fut.result())
                except Exception:
                    pass
            try:
                ssdp = fut_ssdp.result(timeout=4)
            except Exception:
                ssdp = {}
        # Enriquecer con SSDP: banner 'upnp' y, si faltan nombre/fabricante,
        # descargar el XML de descripcion (en paralelo, solo donde haga falta).
        need = []
        for h in hosts:
            info = ssdp.get(h["ip"])
            if not info:
                continue
            if info.get("server"):
                h.setdefault("banners", {})["upnp"] = info["server"]
            if info.get("location") and (not h.get("hostname")
                                         or not h.get("vendor")):
                need.append((h, info["location"]))
        if need:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                futs = {ex.submit(_ssdp_fetch_info, loc): h
                        for h, loc in need[:12]}
                for fut in concurrent.futures.as_completed(futs):
                    try:
                        xml = fut.result()
                    except Exception:
                        xml = {}
                    h = futs[fut]
                    if xml.get("friendly") and not h.get("hostname"):
                        h["hostname"] = xml["friendly"]
                    if xml.get("manufacturer") and not h.get("vendor"):
                        h["vendor"] = xml["manufacturer"]

    for h in hosts:
        h.setdefault("hostname", "")
        h.setdefault("mac", "")
        h.setdefault("vendor", _oui_vendor(h.get("mac", "")))
        h.setdefault("banners", {})
        if h.get("self") and not h["hostname"]:
            h["hostname"] = "XTR (este dispositivo)"

    result = {
        "exit_code": 0,
        "subnet": f"{prefix}.0/24",
        "gateway": gateway,
        "icmp": icmp_ok,
        "hosts_found": len(hosts),
        "hosts": hosts,
        "method": ("icmp-ping + " if icmp_ok else "")
                  + "tcp-connect + mdns/netbios/ssdp (proot safe)",
    }
    if note:
        result["note"] = note
    _SCAN_CACHE[ckey] = {"time": time.time(), "result": result}
    return result


def tool_netmap(subnet="", output="/root/scan_red.png"):
    """Escanea la LAN (netscan) y genera el mapa topologico PNG en una sola
    llamada. Determinista: no depende de que el modelo escriba codigo.
    Reutiliza el cache de netscan: si el modelo llamo antes a netscan,
    NO se re-barre la red (ahorra ~2 min)."""
    import tempfile
    # Fuerza ruta absoluta: el modelo a veces manda "netmap.png" a secas y
    # luego la galeria no encuentra el archivo.
    if output and not output.startswith("/"):
        output = "/root/" + output
    # Reutiliza cualquier netscan fresco de la misma subred.
    prefix_hint = ""
    if subnet and str(subnet).strip().lower() not in ("auto", "auto-detect", "detect"):
        prefix_hint = ".".join(str(subnet).split("/")[0].split(".")[:3])
    scan = None
    now = time.time()
    for (pfx, _pl, _deep), ent in list(_SCAN_CACHE.items()):
        if now - ent["time"] < _SCAN_CACHE_TTL and (not prefix_hint
                                                    or pfx == prefix_hint):
            scan = ent["result"]
            break
    if scan is None:
        scan = tool_netscan(subnet=subnet)
    if scan.get("exit_code") != 0:
        return scan
    hosts = scan["hosts"]

    # Los hosts viajan en un fichero JSON aparte. Antes se incrustaban en
    # el codigo fuente con json.loads('...') y cualquier banner con \r o
    # comilla simple rompia el script de dibujo entero.
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as jf:
        json.dump(hosts, jf)
        hosts_json = jf.name

    # script de dibujo con matplotlib (si falta, intenta instalarlo)
    draw = f"""
import json, math, sys
hosts = json.load(open({hosts_json!r}))
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
colors = {{'router': '#FF9F0A', 'device': '#5E9BD6',
           'iot': '#BF5AF2', 'phone': '#34C759'}}
for i, h in enumerate(hosts):
    ang = 2 * math.pi * i / n
    x, y = R * math.cos(ang), R * math.sin(ang)
    vend = (h.get('vendor') or '').lower()
    is_router = h['ip'].endswith('.1') or 'tp-link' in vend or 'netgear' in vend or 'asus' in vend or 'cisco' in vend
    if is_router:
        c = colors['router']
    elif 'espressif' in vend or 'xiaomi' in vend or 'nest' in vend:
        c = colors['iot']
    elif 'apple' in vend or 'samsung' in vend or 'oneplus' in vend or 'motorola' in vend or 'huawei' in vend or 'aleatoria' in vend:
        c = colors['phone']
    else:
        c = colors['device']
    ax.plot([0, x], [0, y], color='#3A3A3C', lw=1.2, zorder=1)
    ax.scatter([x], [y], s=900, c=c, zorder=2, edgecolors='#EAEAEC', linewidths=1.2)
    label = h['ip']
    if h.get('hostname'):
        label = h['hostname'] + '\\n' + label
    if h.get('vendor'):
        label += '\\n' + h['vendor']
    elif h.get('mac'):
        label += '\\n' + h['mac']
    if h.get('open_ports'):
        label += '\\nports: ' + ','.join(map(str, h['open_ports'][:6]))
    ax.text(x, y - 0.55, label, ha='center', va='top',
            color='#EAEAEC', fontsize=8, zorder=3)
ax.scatter([0], [0], s=1200, c='#34C759', zorder=2, edgecolors='#EAEAEC')
ax.text(0, -0.55, 'XTR (este dispositivo)', ha='center', va='top',
        color='#EAEAEC', fontsize=9, zorder=3)
ax.set_title(f'Mapa de red — {{len(hosts)}} dispositivos (naranja=router, morado=IoT, verde=movil)', color='#EAEAEC', fontsize=11)
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
        _os.unlink(hosts_json)
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

# v14.12: proveedores remotos (Groq, OpenRouter...) van detras de Cloudflare,
# que BLOQUEA el User-Agent por defecto de Python ("Python-urllib/3.x") con
# HTTP 403 "error code: 1010" ANTES de llegar a la API. Navegador real => pasa.
_UA_BROWSER = ("Mozilla/5.0 (Linux; Android 15; SM-F966B Build/AP3A.240905.015.A2) "
               "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.122 "
               "Mobile Safari/537.36")


def _is_local_url(url):
    return url.startswith(("http://127.0.0.1", "http://localhost",
                           "http://10.0.2.2", "http://[::1]"))


def _http_get(url, timeout=5.0):
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {LLM_API_KEY}",
        "User-Agent": _UA_BROWSER,
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode("utf-8", errors="replace")


def _http_post_json(url, payload, timeout=180.0, api_key=None):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key or LLM_API_KEY}",
            "User-Agent": _UA_BROWSER,
            "Accept": "application/json",
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


def detect_small_ctx_model(base_url=None, api_key=None):
    """True si el modelo servido es de contexto pequeno (Qwen3 litertlm,
    ctx 2048). Pregunta a /models: el servidor local devuelve el nombre
    del fichero cargado (p.ej. qwen3_4b_instruct_2507....litertlm)."""
    base = (base_url or LLM_BASE_URL).rstrip("/")
    try:
        status, raw = _http_get(f"{base}/models", timeout=5.0)
        if status == 200:
            data = json.loads(raw)
            ids = " ".join(str(m.get("id", "")) for m in data.get("data", []))
            return "qwen" in ids.lower()
    except Exception:
        pass
    return False


# Palabras que indican TAREA real (necesita el bucle agéntico con tools).
_TASK_HINTS = (
    "escanea", "scan", "audita", "audit", "crea", "create", "genera",
    "generate", "ejecuta", "run", "instala", "install", "borra", "delete",
    "lee ", "read ", "escribe", "write ", "archivo", "file", "fichero",
    "carpeta", "directorio", "red", "network", "puerto", "port", "host",
    "servicio", "service", "proceso", "process", "usuario", "user ",
    "password", "ssh", "suid", "firewall", "actualiza", "update", "upgrade",
    "descarga", "download", "imagen", "image", "mapa", "topology",
    "script", "codigo", "code", "python", "bash", "comando", "command",
    "lista ", "list ", "muestra ", "show ", "busca", "find ", "grep",
    "analiza", "analyze", "verifica", "check ", "revisa", "monitor",
    "/", ".py", ".sh", ".png", ".md", ".txt",
)


def is_trivial_chat(message):
    """True si el mensaje es conversacion (saludo, preunta general) y NO
    necesita herramientas. Evita que un 'hola' dispare 3 pasos de agente
    con list_dir + bash en un modelo de 4B (lento y calienta el SoC)."""
    m = message.strip().lower()
    if len(m) > 220:
        return False
    return not any(h in m for h in _TASK_HINTS)


def quick_chat(message, llm_overrides=None, stats=None):
    """Respuesta directa sin bucle agéntico ni system prompt pesado."""
    ov = llm_overrides or {}
    messages = [
        {"role": "system", "content": (
            "Eres el asistente de XTR Terminal (Debian proot en Android). "
            "Responde en espanol, breve y directo (1-3 frases). Si el "
            "usuario pide una accion del sistema, di que la describa con "
            "detalle. /no_think")},
        {"role": "user", "content": message},
    ]
    reply = llm_chat(messages, base_url=ov.get("base_url"),
                     model=ov.get("model"), api_key=ov.get("api_key"),
                     stats=stats)
    import re as _re
    reply = _re.sub(r"<think>.*?</think>", " ", reply, flags=_re.DOTALL)
    reply = _re.sub(r"<think>.*$", " ", reply, flags=_re.DOTALL).strip()
    return reply or "..."


def llm_chat(messages, base_url=None, model=None, api_key=None, stats=None):
    base_url = (base_url or LLM_BASE_URL).rstrip("/")
    model = model or LLM_MODEL
    api_key = api_key or LLM_API_KEY
    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.15,
        "top_p": 0.9,
        # 448 y no mas: a ~19 tok/s cada 100 tokens extra son 5s de espera.
        # El <think> se genera aunque luego se recorte — cuanto menor el
        # techo, menos tiempo muerto.
        "max_tokens": 448,
    }
    # top_k NO es estandar OpenAI: lo acepta el servidor local (MediaPipe)
    # pero proveedores remotos (Groq...) pueden rechazar el payload con 400.
    if _is_local_url(base_url):
        payload["top_k"] = 40
    url = f"{base_url}/chat/completions"
    t0 = time.time()
    try:
        status, raw = _http_post_json(url, payload, timeout=180.0, api_key=api_key)
    except urllib.error.HTTPError as exc:
        body = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")[:300]
        except Exception:
            pass
        # Diagnostico segun endpoint: local (MediaPipe) vs remoto (Groq...).
        if _is_local_url(base_url):
            hint = ("Revisa LLM_BASE_URL/LLM_MODEL y que MediaPipe este "
                    "sirviendo el modelo.")
        elif exc.code in (401, 403) and "1010" not in body:
            hint = ("Autenticacion rechazada: revisa la API key del "
                    "proveedor en Ajustes > Fuente de inferencia.")
        elif "1010" in body:
            hint = ("Cloudflare bloqueo la peticion (error 1010): "
                    "User-Agent no aceptado por el proveedor.")
        elif exc.code == 404 or "model" in body.lower():
            hint = (f"El modelo '{model}' no existe en ese proveedor: "
                    "revisa el ID exacto en su consola.")
        else:
            hint = "Revisa LLM_BASE_URL/LLM_MODEL del proveedor."
        raise RuntimeError(
            f"LLM HTTP {exc.code} en {url} (model={model}). "
            f"Respuesta: {body or exc.reason}. {hint}")
    elapsed = time.time() - t0
    data = json.loads(raw)
    text = data["choices"][0]["message"]["content"]
    # Telemetria: tokens (usage OpenAI si el server lo da; si no, estimacion
    # ~4 chars/token) y segundos de la llamada. stats es un dict acumulador.
    if stats is not None:
        usage = data.get("usage") or {}
        ptok = usage.get("prompt_tokens") or sum(
            len(m.get("content") or "") for m in messages) // 4
        ctok = usage.get("completion_tokens") or max(1, len(text) // 4)
        stats["calls"] = stats.get("calls", 0) + 1
        stats["prompt_tokens"] = stats.get("prompt_tokens", 0) + int(ptok)
        stats["completion_tokens"] = stats.get("completion_tokens", 0) + int(ctok)
        stats["llm_seconds"] = stats.get("llm_seconds", 0.0) + elapsed
        stats["last_call_seconds"] = elapsed
    return text


def fmt_stats(stats, total_seconds):
    """Línea de telemetria para adjuntar a la respuesta final."""
    if not stats or not stats.get("calls"):
        return ""
    mins = int(total_seconds // 60)
    secs = int(total_seconds % 60)
    tstr = f"{mins} min {secs} s" if mins else f"{secs} s"
    return (f"\n\n---\n⏱ {tstr} · {stats['calls']} llamadas LLM "
            f"({stats['llm_seconds']:.0f} s) · "
            f"tokens ↑{stats['prompt_tokens']} ↓{stats['completion_tokens']}")


# ---------------------------------------------------------------------------
# Parseo <tool>/<args>/<final>
# ---------------------------------------------------------------------------


def _loads_tool_args(raw_args):
    """JSON tolerante con las chapuzas del modelo local:
    - quita fences ```json ... ```
    - acepta basura tras el objeto ("};", texto suelto) tomando el primer
      objeto JSON balanceado con raw_decode.
    """
    s = (raw_args or "").strip()
    if s.startswith("```"):
        s = s.strip("`").strip()
        if s[:4].lower() == "json":
            s = s[4:].strip()
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        pass
    dec = json.JSONDecoder()
    for i, ch in enumerate(s):
        if ch == "{":
            try:
                obj, _end = dec.raw_decode(s[i:])
                if isinstance(obj, dict):
                    return obj
            except json.JSONDecodeError:
                continue
    return {"_raw": raw_args, "_error": "invalid JSON args"}


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
        args = _loads_tool_args(raw_args)
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

    # Con modelos de contexto pequeno (Qwen3, ctx 2048) arranca DIRECTO con
    # el prompt compacto: el completo (~1400 tok) ya desborda en el paso 1.
    small_ctx = detect_small_ctx_model(ov.get("base_url"), ov.get("api_key"))
    base_prompt = SYSTEM_PROMPT_COMPACT if small_ctx else _build_system_prompt()
    if small_ctx:
        goal_log("ctx", "compact_prompt_from_start", {"model": "qwen"})

    messages = [
        {"role": "system", "content": base_prompt},
        {"role": "user", "content": f"GOAL: {goal}"},
    ]

    def emit(event, data):
        goal_log(goal_id, event, data)
        if event_cb:
            event_cb(event, data)

    emit("goal_start", {"goal": goal, "max_steps": max_steps})

    final_text = None
    status = "failed"
    stats = {}
    t_start = time.time()

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
                             model=ov.get("model"), api_key=ov.get("api_key"),
                             stats=stats)
            # Latido por paso: la UI ve que el agente esta VIVO y cuanto
            # tardo el LLM en responder (nada de silencio hasta el BLOCKED).
            emit("llm_done", {"step": step_num,
                              "seconds": round(stats.get("last_call_seconds", 0), 1),
                              "prompt_tokens": stats.get("prompt_tokens", 0),
                              "completion_tokens": stats.get("completion_tokens", 0)})
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

        # Qwen3 "piensa en voz alta" con <think>…</think> y se gasta todo el
        # presupuesto de respuesta sin llegar a la herramienta. Se recorta
        # TODO el razonamiento ANTES de emitir nada a la UI: el usuario no
        # quiere ver pensamientos en el chat.
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

        emit("chunk", {"step": step_num, "text": reply})
        messages.append({"role": "assistant", "content": reply})

        final_text = parse_final(reply)
        if final_text is not None:
            # El modelo a veces remata con un final vacio o trivial
            # ("answer", "done"): NUNCA vale como cierre, ni siquiera tras
            # haber ejecutado herramientas (el usuario se queda sin resumen).
            if len(final_text.strip()) < 8:
                messages.append({"role": "system", "content": (
                    "That final was empty/useless. Give a REAL summary of the "
                    "tool results in <final>…</final> (2-4 sentences with the "
                    "actual data found).")})
                emit("nudge", {"step": step_num, "reason": "trivial_final"})
                continue
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
        fake = [m for m in set(mentioned)
                if os.path.exists(m) and not _is_real_image(m)]
        if missing:
            final_text += ("\n\n[aviso: estos archivos NO se llegaron a crear: "
                           + ", ".join(missing) + "]")
            if status == "done":
                status = "failed"  # afirmo exito sin evidencia
        if fake:
            final_text += ("\n\n[aviso: estos 'archivos de imagen' son FALSOS "
                           "(contienen texto, no una imagen real): "
                           + ", ".join(fake) + "]")
            if status == "done":
                status = "failed"

    # Verificacion cruzada de ESCANEOS: si en la meta se ejecuto netscan/
    # netmap, el resultado REAL de la herramienta es la unica verdad. El
    # modelo tiende a inventar hosts ("8 devices en 192.168.10.x") cuando
    # el scan encontro 0. Se adjunta la tabla real y se marcan las IPs
    # alucinadas.
    scan_hosts = None
    scan_subnet = ""
    for st in state["steps"]:
        if st["tool"] in ("netscan", "netmap") and st["result"].get("exit_code") == 0:
            scan_hosts = st["result"].get("hosts", [])
            scan_subnet = st["result"].get("subnet", "")
    if final_text and scan_hosts is not None:
        import re as _re3
        real_ips = {h["ip"] for h in scan_hosts}
        claimed = set(_re3.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", final_text))
        hallucinated = sorted(ip for ip in claimed - real_ips
                              if ip.split(".")[0] != "127")
        if hallucinated:
            final_text += ("\n\n[VERIFICACION: el modelo menciono IPs que el "
                           "escaneo NO encontro: " + ", ".join(hallucinated)
                           + ". Esos datos son inventados.]")
            if status == "done":
                status = "failed"
        # Tabla REAL, determinista, adjunta siempre: el usuario ve los
        # datos del escaneo aunque el modelo haya resumido mal.
        lines = [f"\n\nEscaneo real ({scan_subnet}): {len(scan_hosts)} hosts"]
        for h in scan_hosts[:20]:
            ports = ",".join(str(p) for p in h.get("open_ports", [])) or "-"
            name = h.get("hostname") or ""
            vend = h.get("vendor") or h.get("mac") or ""
            tag = " ".join(x for x in (name, vend) if x)
            lines.append(f"  {h['ip']:16} {ports:22} {tag}".rstrip())
            for p, b in list((h.get("banners") or {}).items())[:3]:
                lines.append(f"      :{p} -> {b}")
        if not scan_hosts:
            lines.append("  (ningun host vivo: ni ping, ni puertos TCP, "
                         "ni vecinos en la tabla ARP)")
        final_text += "\n".join(lines)

    # Telemetria final: tiempo total + llamadas + tokens en la respuesta.
    if final_text:
        final_text += fmt_stats(stats, time.time() - t_start)

    state["status"] = status
    state["result"] = final_text
    state["finished_at"] = datetime.now(timezone.utc).isoformat()
    state["stats"] = stats

    db_save_episode(goal, state["steps"], final_text or "", status)
    emit("final", {"status": status, "result": final_text, "stats": stats})
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
        elif path == "/goal/log":
            # Log JSONL crudo de una meta (o de la mas reciente).
            goal_id = qs.get("goal_id", "")
            if not goal_id:
                try:
                    files = sorted(
                        (f for f in os.listdir(LOGS_DIR) if f.endswith(".jsonl")),
                        key=lambda f: os.path.getmtime(os.path.join(LOGS_DIR, f)),
                        reverse=True)
                    goal_id = files[0][:-6] if files else ""
                except OSError:
                    goal_id = ""
            fp = os.path.join(LOGS_DIR, f"{goal_id}.jsonl")
            if not goal_id or not os.path.exists(fp):
                self._send_json({"error": "sin logs", "goal_id": goal_id},
                                status=404)
                return
            try:
                with open(fp, encoding="utf-8") as fh:
                    lines = [json.loads(l) for l in fh if l.strip()]
                self._send_json({"goal_id": goal_id, "events": lines[-200:]})
            except (OSError, json.JSONDecodeError) as exc:
                self._send_json({"error": str(exc)}, status=500)
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
        if path == "/file":
            # Borrado de archivos generados (imagenes de la galeria).
            # Misma restriccion que do_GET /file: solo /root y /tmp.
            target = qs.get("path", "")
            if not target.startswith(("/root/", "/tmp/")):
                self._send_json({"error": "path fuera de /root,/tmp"}, status=403)
                return
            try:
                os.remove(target)
                self._send_json({"status": "deleted", "path": target})
            except FileNotFoundError:
                self._send_json({"error": "no existe"}, status=404)
            except OSError as exc:
                self._send_json({"error": str(exc)}, status=500)
        elif path == "/memory":
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
            elif event == "llm_done":
                # Latido: el LLM respondio en N segundos. La UI lo muestra
                # como "pensamiento" para que no haya silencios largos.
                send({"type": "step", "step": data.get("step"),
                      "thought": f"⚡ LLM respondió en {data.get('seconds')}s "
                                 f"(tokens ↑{data.get('prompt_tokens')} "
                                 f"↓{data.get('completion_tokens')})"})
            elif event == "error":
                send({"type": "error", "error": data.get("error", "error")})
            elif event == "final":
                send({"type": "final", "answer": data.get("result") or ""})

        def run_agent():
            try:
                # Via rapida: charla trivial NO entra al bucle agéntico
                # (un "hola" no necesita tools, system prompt ni 15 pasos).
                if is_trivial_chat(message):
                    send({"type": "step", "step": 1,
                          "thought": "Respuesta directa (sin herramientas)"})
                    stats = {}
                    t0 = time.time()
                    answer = quick_chat(message, llm_overrides=overrides,
                                        stats=stats)
                    answer += fmt_stats(stats, time.time() - t0)
                    send({"type": "final", "answer": answer})
                    with _goals_lock:
                        GOALS[goal_id]["status"] = "done"
                        GOALS[goal_id]["result"] = answer
                    return
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
