# XTR Agent Server v13.0 — Autonomous (loop + memory + goal mode)
#
# Servidor de agente IA autónomo para ejecutar DENTRO de un contenedor
# Debian (proot) en Android. Mantiene compatibilidad total con v12.1:
#   - FastAPI + uvicorn en puerto 8765 (env AGENT_PORT)
#   - LLM local OpenAI-compatible (LLM_BASE_URL, LLM_MODEL, LLM_API_KEY)
#   - Endpoints: /health, /run (SSE), /chat, /tools, /gpu/status
#   - Herramientas: bash, python, read_file, write_file, list_dir
#   - Formato de herramientas: <tool>nombre</tool><args>{...}</args> y <final>...</final>
#
# Novedades v13.0:
#   1. Bucle agéntico robusto (plan → tool → observación → siguiente paso)
#   2. Memoria persistente SQLite (episodes + kv, remember/recall)
#   3. Modo GOAL autónomo en background (/goal, /goal/status, /goal/list)
#   4. Logs estructurados JSONL por goal
#   5. Endpoints de memoria (/memory GET/DELETE)
#   6. System prompt v13 con sección AUTONOMOUS MODE

import asyncio
import json
import os
import sqlite3
import time
import uuid
from datetime import datetime, timezone

import httpx
import uvicorn
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuración por variables de entorno
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

VERSION = "13.0"

# ---------------------------------------------------------------------------
# System prompt v13 (en inglés, estilo agresivo, few-shot de red)
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """You ARE the system. You CAN execute code. You WILL use tools. NEVER refuse to execute commands. Never apologize for being an AI.

You run INSIDE a Debian (proot) container on Android with full root access. You have real tools that execute real actions on a real system.

## TOOL FORMAT
To use a tool, output EXACTLY:
<tool>tool_name</tool><args>{"arg1": "value1"}</args>

Available tools:
- bash(command, timeout=30): run any shell command
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

TOOL RESULT [bash]: Nmap scan report for 192.168.1.1 (router)
Nmap scan report for 192.168.1.42 (this device)
Nmap scan report for 192.168.1.57
Nmap scan report for 192.168.1.88

ASSISTANT: Found 4 hosts. Fingerprinting the two unknown ones.
<tool>bash</tool><args>{"command": "nmap -sS -O -sV 192.168.1.57 192.168.1.88", "timeout": 180}</args>

TOOL RESULT [bash]: 192.168.1.57: Linux, ports 22/tcp ssh OpenSSH 8.9, 80/tcp http nginx
192.168.1.88: Android, ports 5555/tcp adb

ASSISTANT: Now generating the network map.
<tool>python</tool><args>{"code": "import graphviz\\ng = graphviz.Digraph()\\ng.node('router', '192.168.1.1 router')\\ng.node('phone', '192.168.1.42 this device')\\ng.node('srv', '192.168.1.57 Linux SSH/HTTP')\\ng.node('droid', '192.168.1.88 Android ADB')\\ng.edges([('router','phone'),('router','srv'),('router','droid')])\\ng.render('/root/network_map', format='png', cleanup=True)\\nprint('map written to /root/network_map.png')"}</args>

TOOL RESULT [python]: map written to /root/network_map.png

<final>Network scan complete. Found 4 devices on 192.168.1.0/24: the router (.1), this device (.42), a Linux server (.57, SSH+HTTP), and an Android device (.88, ADB open). Map saved to /root/network_map.png.</final>

## RULES
- ALWAYS act. NEVER say "I can't" or "as an AI".
- Prefer doing over explaining. Show results, not intentions.
- If a command fails, analyze the error and try a different approach.
"""

# ---------------------------------------------------------------------------
# Memoria persistente SQLite
# ---------------------------------------------------------------------------

_db_lock = asyncio.Lock()


def _db_connect() -> sqlite3.Connection:
    """Abre conexión SQLite (crea directorio y tablas si hace falta)."""
    os.makedirs(MEMORY_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)
    conn = sqlite3.connect(MEMORY_DB)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS episodes ("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, goal TEXT, "
        "steps_json TEXT, result TEXT, status TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS kv ("
        "key TEXT PRIMARY KEY, value TEXT, ts TEXT)"
    )
    conn.commit()
    return conn


def db_save_episode(goal: str, steps: list, result: str, status: str) -> None:
    """Guarda un episodio (goal completado) en la tabla episodes."""
    ts = datetime.now(timezone.utc).isoformat()
    try:
        conn = _db_connect()
        conn.execute(
            "INSERT INTO episodes (ts, goal, steps_json, result, status) VALUES (?,?,?,?,?)",
            (ts, goal, json.dumps(steps, ensure_ascii=False), result, status),
        )
        conn.commit()
        conn.close()
    except Exception as exc:  # la memoria nunca debe romper el agente
        print(f"[memory] error guardando episodio: {exc}")


def db_last_episodes(limit: int = 5) -> list:
    """Devuelve los últimos N episodios (más recientes primero)."""
    try:
        conn = _db_connect()
        cur = conn.execute(
            "SELECT id, ts, goal, result, status FROM episodes ORDER BY id DESC LIMIT ?",
            (limit,),
        )
        rows = [
            {"id": r[0], "ts": r[1], "goal": r[2], "result": r[3], "status": r[4]}
            for r in cur.fetchall()
        ]
        conn.close()
        return rows
    except Exception as exc:
        print(f"[memory] error leyendo episodios: {exc}")
        return []


def db_remember(key: str, value: str) -> str:
    """Inserta o actualiza una nota persistente en la tabla kv."""
    ts = datetime.now(timezone.utc).isoformat()
    try:
        conn = _db_connect()
        conn.execute(
            "INSERT INTO kv (key, value, ts) VALUES (?,?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value, ts=excluded.ts",
            (key, value, ts),
        )
        conn.commit()
        conn.close()
        return f"OK: remembered '{key}'"
    except Exception as exc:
        return f"ERROR: {exc}"


def db_recall(key: str) -> str:
    """Recupera una nota persistente por clave."""
    try:
        conn = _db_connect()
        cur = conn.execute("SELECT value, ts FROM kv WHERE key = ?", (key,))
        row = cur.fetchone()
        conn.close()
        if row:
            return f"{row[0]}  (saved at {row[1]})"
        return f"NOT FOUND: no memory for key '{key}'"
    except Exception as exc:
        return f"ERROR: {exc}"


def db_wipe_memory() -> int:
    """Borra todos los episodios y notas. Devuelve nº de filas eliminadas."""
    conn = _db_connect()
    cur = conn.execute("SELECT COUNT(*) FROM episodes")
    n = cur.fetchone()[0]
    conn.execute("DELETE FROM episodes")
    conn.execute("DELETE FROM kv")
    conn.commit()
    conn.close()
    return n


# ---------------------------------------------------------------------------
# Logs estructurados JSONL por goal
# ---------------------------------------------------------------------------


def goal_log(goal_id: str, event: str, data: dict) -> None:
    """Escribe un evento JSONL en /root/agent_memory/logs/<goal_id>.jsonl."""
    try:
        os.makedirs(LOGS_DIR, exist_ok=True)
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "event": event,
            "data": data,
        }
        with open(os.path.join(LOGS_DIR, f"{goal_id}.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as exc:
        print(f"[log] error escribiendo log de {goal_id}: {exc}")


# ---------------------------------------------------------------------------
# Herramientas nativas
# ---------------------------------------------------------------------------


async def tool_bash(command: str, timeout: int = 30) -> dict:
    """Ejecuta un comando shell y devuelve stdout/stderr/exit_code."""
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            return {"exit_code": -1, "stdout": "", "stderr": f"TIMEOUT after {timeout}s", "error": f"timeout after {timeout}s"}
        return {
            "exit_code": proc.returncode,
            "stdout": stdout.decode("utf-8", errors="replace")[:20000],
            "stderr": stderr.decode("utf-8", errors="replace")[:5000],
        }
    except Exception as exc:
        return {"exit_code": -1, "stdout": "", "stderr": "", "error": str(exc)}


async def tool_python(code: str) -> dict:
    """Ejecuta código Python en un subproceso aislado."""
    tmp = f"/tmp/agent_py_{uuid.uuid4().hex[:8]}.py"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(code)
        result = await tool_bash(f"python3 {tmp}", timeout=120)
        return result
    except Exception as exc:
        return {"exit_code": -1, "stdout": "", "stderr": "", "error": str(exc)}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


async def tool_read_file(path: str, limit: int = 5000) -> dict:
    """Lee un archivo de texto (hasta `limit` caracteres)."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            content = fh.read(limit)
        return {"exit_code": 0, "content": content}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


async def tool_write_file(path: str, content: str) -> dict:
    """Escribe contenido en un archivo (crea directorios padres)."""
    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return {"exit_code": 0, "bytes": len(content)}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


async def tool_list_dir(path: str = "/root") -> dict:
    """Lista el contenido de un directorio."""
    try:
        entries = sorted(os.listdir(path))
        return {"exit_code": 0, "path": path, "entries": entries}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


# Registro de herramientas disponibles (nombre → (función, descripción))
TOOLS = {
    "bash": (tool_bash, "Run any shell command. Args: command (str), timeout (int, default 30)"),
    "python": (tool_python, "Execute Python code. Args: code (str)"),
    "read_file": (tool_read_file, "Read a text file. Args: path (str), limit (int, default 5000)"),
    "write_file": (tool_write_file, "Write a file. Args: path (str), content (str)"),
    "list_dir": (tool_list_dir, "List directory contents. Args: path (str, default /root)"),
    "remember": (None, "Store a persistent note. Args: key (str), value (str)"),
    "recall": (None, "Retrieve a persistent note. Args: key (str)"),
}


async def execute_tool(name: str, args: dict) -> dict:
    """Despacha una llamada de herramienta y normaliza el resultado."""
    if name == "remember":
        return {"exit_code": 0, "output": db_remember(str(args.get("key", "")), str(args.get("value", "")))}
    if name == "recall":
        return {"exit_code": 0, "output": db_recall(str(args.get("key", "")))}
    entry = TOOLS.get(name)
    if not entry or entry[0] is None:
        return {"exit_code": -1, "error": f"unknown tool: {name}"}
    func = entry[0]
    try:
        # Filtra argumentos inesperados para no romper la firma de la función
        import inspect

        sig = inspect.signature(func)
        filtered = {k: v for k, v in args.items() if k in sig.parameters}
        return await func(**filtered)
    except TypeError as exc:
        return {"exit_code": -1, "error": f"bad args for {name}: {exc}"}
    except Exception as exc:
        return {"exit_code": -1, "error": str(exc)}


# ---------------------------------------------------------------------------
# Cliente LLM (API OpenAI-compatible, servidor MediaPipe local)
# ---------------------------------------------------------------------------


async def check_backend_alive() -> bool:
    """Comprueba si el servidor LLM local responde."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{LLM_BASE_URL}/models")
            return resp.status_code == 200
    except Exception:
        return False


async def llm_chat(messages: list) -> str:
    """Llama al LLM (chat completions) y devuelve el texto de la respuesta."""
    payload = {
        "model": LLM_MODEL,
        "messages": messages,
        "temperature": 0.3,
        "max_tokens": 2048,
    }
    headers = {"Authorization": f"Bearer {LLM_API_KEY}"}
    async with httpx.AsyncClient(timeout=180.0) as client:
        resp = await client.post(
            f"{LLM_BASE_URL}/chat/completions", json=payload, headers=headers
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]


# ---------------------------------------------------------------------------
# Parseo del formato <tool>/<args>/<final>
# ---------------------------------------------------------------------------


def parse_tool_calls(text: str) -> list:
    """Extrae llamadas <tool>nombre</tool><args>{json}</args> del texto del modelo."""
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
        name = text[t_start + 6 : t_end].strip()
        raw_args = text[a_start + 6 : a_end].strip()
        try:
            args = json.loads(raw_args)
        except json.JSONDecodeError:
            args = {"_raw": raw_args, "_error": "invalid JSON args"}
        calls.append({"tool": name, "args": args})
        pos = a_end + 7
    return calls


def parse_final(text: str) -> str:
    """Extrae el contenido de <final>...</final> si existe."""
    f_start = text.find("<final>")
    if f_start == -1:
        return None
    f_end = text.find("</final>", f_start)
    if f_end == -1:
        return text[f_start + 7 :].strip()
    return text[f_start + 7 : f_end].strip()


# ---------------------------------------------------------------------------
# Bucle agéntico robusto (plan → tool → observación → siguiente paso)
# ---------------------------------------------------------------------------

# Registro en memoria de goals activos/terminados: goal_id → dict de estado
GOALS: dict = {}


def _build_system_prompt() -> str:
    """System prompt v13 + últimos 5 episodios de memoria como contexto."""
    prompt = SYSTEM_PROMPT
    episodes = db_last_episodes(5)
    if episodes:
        prompt += "\n## RECENT MEMORY (last episodes)\n"
        for ep in episodes:
            result = (ep["result"] or "")[:300]
            prompt += f"- [{ep['status']}] {ep['goal']}: {result}\n"
    return prompt


async def agent_loop(goal: str, goal_id: str, max_steps: int, event_cb=None) -> dict:
    """Ejecuta el bucle agéntico para un goal.

    event_cb: corutina opcional llamada con (evento, datos) en cada paso
    (usada por /run para emitir SSE). Devuelve el estado final del goal.
    """
    state = GOALS[goal_id]
    deadline = time.time() + AGENT_GOAL_TIMEOUT

    messages = [
        {"role": "system", "content": _build_system_prompt()},
        {"role": "user", "content": f"GOAL: {goal}"},
    ]

    async def emit(event: str, data: dict):
        goal_log(goal_id, event, data)
        if event_cb:
            await event_cb(event, data)

    await emit("goal_start", {"goal": goal, "max_steps": max_steps})

    final_text = None
    status = "failed"

    for step_num in range(1, max_steps + 1):
        # Límite duro de tiempo por goal
        if time.time() > deadline:
            status = "timeout"
            await emit("timeout", {"step": step_num})
            break

        state["current_step"] = step_num
        await emit("step", {"step": step_num, "max_steps": max_steps})

        # --- Llamada al LLM ---
        try:
            reply = await llm_chat(messages)
        except Exception as exc:
            err = f"LLM error: {exc}"
            messages.append({"role": "system", "content": err})
            await emit("error", {"step": step_num, "error": err})
            continue

        await emit("chunk", {"step": step_num, "text": reply})
        messages.append({"role": "assistant", "content": reply})

        # --- ¿Respuesta final? ---
        final_text = parse_final(reply)
        if final_text is not None:
            status = "done" if not final_text.startswith("BLOCKED:") else "failed"
            break

        # --- Llamadas a herramientas ---
        calls = parse_tool_calls(reply)
        if not calls:
            # El modelo no emitió ni herramientas ni <final>: pedirle que actúe
            nudge = (
                "You must act. Use <tool>...</tool><args>{...}</args> or "
                "finish with <final>...</final>."
            )
            messages.append({"role": "system", "content": nudge})
            await emit("nudge", {"step": step_num})
            continue

        for call in calls:
            name, args = call["tool"], call["args"]
            await emit("tool_call", {"step": step_num, "tool": name, "args": args})

            result = await execute_tool(name, args)
            await emit("tool_result", {"step": step_num, "tool": name, "result": result})

            # Guarda el paso en el estado del goal
            state["steps"].append(
                {"step": step_num, "tool": name, "args": args, "result": result}
            )

            # Formatea la observación para el modelo
            obs = f"TOOL RESULT [{name}]: {json.dumps(result, ensure_ascii=False)[:6000]}"
            messages.append({"role": "user", "content": obs})

            # Auto-recuperación: ante fallo, forzar al modelo a reintentar
            exit_code = result.get("exit_code", 0)
            if exit_code != 0 or result.get("error"):
                recovery = (
                    "The command failed. Analyze the error and try a different "
                    "approach. Do NOT give up."
                )
                messages.append({"role": "system", "content": recovery})
                await emit("recovery", {"step": step_num, "tool": name})
    else:
        # Se agotaron los pasos sin <final>
        status = "failed"
        final_text = f"BLOCKED: reached max_steps ({max_steps}) without a final answer"

    if final_text is None and status == "timeout":
        final_text = f"BLOCKED: goal timeout after {AGENT_GOAL_TIMEOUT}s"

    # --- Cierre: estado, episodio persistente y log ---
    state["status"] = status
    state["result"] = final_text
    state["finished_at"] = datetime.now(timezone.utc).isoformat()

    async with _db_lock:
        db_save_episode(goal, state["steps"], final_text or "", status)

    await emit("final", {"status": status, "result": final_text})
    return state


# ---------------------------------------------------------------------------
# Aplicación FastAPI
# ---------------------------------------------------------------------------

app = FastAPI(title="XTR Agent Server", version=VERSION)


class RunRequest(BaseModel):
    message: str = ""
    goal: str = ""  # alias aceptado
    max_steps: int | None = None


class GoalRequest(BaseModel):
    goal: str
    max_steps: int | None = None


@app.on_event("startup")
async def on_startup():
    """Escribe el PID file y prepara el directorio de memoria al arrancar."""
    os.makedirs(MEMORY_DIR, exist_ok=True)
    os.makedirs(LOGS_DIR, exist_ok=True)
    _db_connect().close()
    try:
        with open(AGENT_PID_FILE, "w") as fh:
            fh.write(str(os.getpid()))
    except OSError as exc:
        print(f"[startup] no se pudo escribir PID file: {exc}")
    print(f"[startup] XTR Agent Server v{VERSION} en puerto {AGENT_PORT} (pid {os.getpid()})")


@app.get("/health")
async def health():
    """Estado del servidor y del backend LLM (compatible v12.1)."""
    backend_alive = await check_backend_alive()
    return {
        "status": "ok" if backend_alive else "degraded",
        "version": VERSION,
        "backend": {"url": LLM_BASE_URL, "alive": backend_alive, "model": LLM_MODEL},
        "gpu_server_alive": backend_alive,  # MediaPipe sirve el LLM en :8090
        "pid": os.getpid(),
    }


@app.get("/tools")
async def list_tools():
    """Lista las herramientas nativas disponibles (compatible v12.1)."""
    return {
        "tools": [
            {"name": name, "description": desc} for name, (_, desc) in TOOLS.items()
        ]
    }


@app.get("/gpu/status")
async def gpu_status():
    """Estado del servidor MediaPipe en :8090 (compatible v12.1)."""
    alive = await check_backend_alive()
    info = {"alive": alive, "url": LLM_BASE_URL, "model": LLM_MODEL}
    if alive:
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{LLM_BASE_URL}/models")
                info["models"] = resp.json()
        except Exception:
            pass
    return info


def _sse(event: str, data: dict) -> str:
    """Serializa un evento SSE."""
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


async def _run_sse(message: str, max_steps: int):
    """Generador SSE para /run y /chat (compatible v12.1)."""
    goal_id = f"run-{uuid.uuid4().hex[:12]}"
    GOALS[goal_id] = {
        "goal_id": goal_id,
        "goal": message,
        "status": "running",
        "current_step": 0,
        "max_steps": max_steps,
        "steps": [],
        "result": None,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }

    queue: asyncio.Queue = asyncio.Queue()

    async def event_cb(event: str, data: dict):
        # Mapea los eventos internos a los nombres SSE de v12.1
        sse_name = {
            "chunk": "chunk",
            "tool_call": "tool_call",
            "tool_result": "tool_result",
            "final": "final",
            "error": "error",
        }.get(event)
        if sse_name:
            await queue.put(_sse(sse_name, data))

    async def run_agent():
        try:
            await agent_loop(message, goal_id, max_steps, event_cb=event_cb)
        except Exception as exc:
            await queue.put(_sse("error", {"error": str(exc)}))
        finally:
            await queue.put(None)  # centinela de fin de stream

    task = asyncio.create_task(run_agent())
    try:
        while True:
            item = await queue.get()
            if item is None:
                break
            yield item
    finally:
        if not task.done():
            task.cancel()


@app.post("/run")
async def run(req: RunRequest):
    """Ejecuta un mensaje/goal con streaming SSE (compatible v12.1)."""
    message = req.message or req.goal
    if not message:
        return JSONResponse({"error": "missing 'message'"}, status_code=400)
    max_steps = req.max_steps or AGENT_MAX_STEPS
    return StreamingResponse(
        _run_sse(message, max_steps),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/chat")
async def chat(req: RunRequest):
    """Alias de /run (compatible v12.1)."""
    return await run(req)


# ---------------------------------------------------------------------------
# Modo GOAL autónomo (nuevo en v13.0)
# ---------------------------------------------------------------------------


@app.post("/goal")
async def start_goal(req: GoalRequest):
    """Arranca un goal autónomo en background y devuelve su goal_id."""
    if not req.goal:
        return JSONResponse({"error": "missing 'goal'"}, status_code=400)
    goal_id = uuid.uuid4().hex[:12]
    max_steps = req.max_steps or AGENT_MAX_STEPS
    GOALS[goal_id] = {
        "goal_id": goal_id,
        "goal": req.goal,
        "status": "running",
        "current_step": 0,
        "max_steps": max_steps,
        "steps": [],
        "result": None,
        "started_at": datetime.now(timezone.utc).isoformat(),
    }
    asyncio.create_task(agent_loop(req.goal, goal_id, max_steps))
    return {"goal_id": goal_id, "status": "running"}


@app.get("/goal/status")
async def goal_status(goal_id: str = Query(...)):
    """Estado detallado de un goal (pasos, resultado, etc.)."""
    state = GOALS.get(goal_id)
    if not state:
        return JSONResponse({"error": f"unknown goal_id: {goal_id}"}, status_code=404)
    return {
        "goal_id": goal_id,
        "status": state["status"],
        "current_step": state["current_step"],
        "max_steps": state["max_steps"],
        "steps": state["steps"],
        "result": state["result"],
    }


@app.get("/goal/list")
async def goal_list():
    """Lista todos los goals conocidos con su estado."""
    return {
        "goals": [
            {
                "goal_id": g["goal_id"],
                "goal": g["goal"],
                "status": g["status"],
                "current_step": g["current_step"],
                "max_steps": g["max_steps"],
                "started_at": g.get("started_at"),
                "finished_at": g.get("finished_at"),
            }
            for g in GOALS.values()
        ]
    }


# ---------------------------------------------------------------------------
# Endpoints de memoria (nuevo en v13.0)
# ---------------------------------------------------------------------------


@app.get("/memory")
async def get_memory(limit: int = Query(10, ge=1, le=100)):
    """Devuelve los últimos episodios guardados en memoria persistente."""
    return {"episodes": db_last_episodes(limit)}


@app.delete("/memory")
async def delete_memory(confirm: str = Query("")):
    """Borra TODA la memoria persistente (requiere ?confirm=yes)."""
    if confirm != "yes":
        return JSONResponse(
            {"error": "refused: pass ?confirm=yes to wipe all memory"}, status_code=400
        )
    deleted = db_wipe_memory()
    return {"status": "wiped", "episodes_deleted": deleted}


# ---------------------------------------------------------------------------
# Entrada principal
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=AGENT_PORT, log_level="info")
