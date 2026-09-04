#!/usr/bin/env python3
"""
XTR Terminal — agent_server.py v12.0
Servidor FastAPI para el agente IA — ejecuta dentro de proot Debian arm64
Puerto: 8765 | Venv: /root/agent-env

Endpoints:
  GET  /health        — Health check (incluye estado del backend)
  POST /run           — Ejecuta tarea (SSE streaming)
  POST /chat          — Alias de /run
  GET  /tools         — Lista tools disponibles
  GET  /gpu/status    — Estado del servidor GPU MediaPipe
"""

import os
import sys
import json
import logging
import signal
import atexit
import tempfile
import subprocess
import textwrap
from typing import Any, Optional
from datetime import datetime

# =============================================================================
#  MANEJO DE DEPENDENCIAS (con fallback a stdlib)
# =============================================================================

_MISSING_DEPS = []

try:
    import httpx
except ImportError:
    httpx = None
    _MISSING_DEPS.append("httpx")

try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import StreamingResponse, JSONResponse
    from fastapi.middleware.cors import CORSMiddleware
    from pydantic import BaseModel
    import uvicorn
except ImportError as e:
    print(f"[FATAL] Faltan dependencias criticas: {e}", file=sys.stderr)
    print("[FATAL] Ejecuta: pip install fastapi uvicorn pydantic httpx", file=sys.stderr)
    sys.exit(1)

# smolagents es opcional (solo si use_native_tools=True)
try:
    from smolagents import CodeAgent, HfApiModel, DuckDuckGoSearchTool, Tool
    _SMOLAGENTS_OK = True
except ImportError:
    _SMOLAGENTS_OK = False

# =============================================================================
#  CONFIGURACION
# =============================================================================

AGENT_PORT = int(os.environ.get("AGENT_PORT", "8765"))
AGENT_PID_FILE = os.environ.get("AGENT_PID_FILE", "/tmp/agent.pid")
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8090/v1")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemma3-local")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "local")
GPU_LOCAL_PORT = 8090
GPU_LOCAL_BASE = f"http://127.0.0.1:{GPU_LOCAL_PORT}/v1"
MAX_TOKENS = 2048

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger("xtr_agent")

# =============================================================================
#  PID FILE
# =============================================================================

def _write_pid():
    try:
        with open(AGENT_PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except Exception as e:
        log.warning("No se pudo escribir PID file: %s", e)

def _remove_pid():
    try:
        if os.path.exists(AGENT_PID_FILE):
            os.remove(AGENT_PID_FILE)
    except Exception:
        pass

_write_pid()
atexit.register(_remove_pid)

# =============================================================================
#  MANEJO DE SENALES
# =============================================================================

def _handle_signal(signum, frame):
    log.info("Senal %d recibida. Cerrando agente...", signum)
    _remove_pid()
    sys.exit(0)

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

# =============================================================================
#  FASTAPI APP
# =============================================================================

app = FastAPI(title="XTR Agent Server", version="12.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# =============================================================================
#  MODELOS Pydantic
# =============================================================================

class AgentRequest(BaseModel):
    task: str
    llm_base_url: str = ""
    llm_api_key: str = ""
    llm_model: str = ""
    history: list = []
    system_prompt: str = ""
    image_base64: str = ""
    use_native_tools: bool = False

class AgentResponse(BaseModel):
    answer: str
    thoughts: list = []
    error: bool = False

# =============================================================================
#  UTILIDADES
# =============================================================================

def sse(d: dict) -> str:
    return f"data: {json.dumps(d, ensure_ascii=False)}\n\n"

async def _is_backend_alive(url: str, timeout: float = 3.0) -> bool:
    """Health-check generico para cualquier backend (GPU local o remoto)."""
    if not httpx:
        return False
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            # Intenta /models (OpenAI-compatible) o /health
            for endpoint in ["/models", "/health", "/"]:
                try:
                    resp = await client.get(f"{url.rstrip('/')}{endpoint}")
                    if resp.status_code in (200, 404):
                        return True
                except Exception:
                    continue
            return False
    except Exception:
        return False

def _get_effective_config(req: AgentRequest) -> dict:
    """Resuelve la configuracion efectiva (env vars > request body > defaults)."""
    return {
        "base_url": req.llm_base_url or LLM_BASE_URL,
        "model": req.llm_model or LLM_MODEL,
        "api_key": req.llm_api_key or LLM_API_KEY,
    }

# =============================================================================
#  HERRAMIENTAS NATIVAS (bash, python, file ops)
# =============================================================================

class ToolCollection:
    """Coleccion de herraminas que el agente puede usar nativamente."""

    @staticmethod
    def bash(command: str, timeout: int = 30) -> dict:
        """Ejecuta un comando bash y devuelve stdout/stderr/exit_code."""
        try:
            result = subprocess.run(
                command,
                shell=True,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd="/root"
            )
            return {
                "stdout": result.stdout[:8000],
                "stderr": result.stderr[:4000],
                "exit_code": result.returncode,
            }
        except subprocess.TimeoutExpired:
            return {"stdout": "", "stderr": f"Timeout despues de {timeout}s", "exit_code": -1}
        except Exception as e:
            return {"stdout": "", "stderr": str(e), "exit_code": -1}

    @staticmethod
    def python(code: str) -> dict:
        """Ejecuta codigo Python y devuelve stdout/resultado."""
        try:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False, dir='/tmp') as f:
                f.write(code)
                f.flush()
                tmp_path = f.name
            result = subprocess.run(
                [sys.executable, tmp_path],
                capture_output=True,
                text=True,
                timeout=30,
                cwd="/root"
            )
            try:
                os.unlink(tmp_path)
            except Exception:
                pass
            return {
                "stdout": result.stdout[:8000],
                "stderr": result.stderr[:4000],
                "exit_code": result.returncode,
            }
        except Exception as e:
            return {"stdout": "", "stderr": str(e), "exit_code": -1}

    @staticmethod
    def read_file(path: str, limit: int = 5000) -> dict:
        """Lee un archivo del contenedor."""
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read(limit)
            return {"content": content, "truncated": len(content) >= limit, "error": False}
        except Exception as e:
            return {"content": "", "truncated": False, "error": True, "message": str(e)}

    @staticmethod
    def write_file(path: str, content: str) -> dict:
        """Escribe un archivo en el contenedor."""
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(content)
            return {"bytes_written": len(content), "path": path, "error": False}
        except Exception as e:
            return {"bytes_written": 0, "path": path, "error": True, "message": str(e)}

    @staticmethod
    def list_dir(path: str = "/root") -> dict:
        """Lista archivos en un directorio."""
        try:
            entries = os.listdir(path)
            return {"entries": entries, "count": len(entries), "error": False}
        except Exception as e:
            return {"entries": [], "count": 0, "error": True, "message": str(e)}

TOOLS = ToolCollection()

# =============================================================================
#  LLM CLIENT (OpenAI-compatible)
# =============================================================================

async def _call_llm(messages: list, config: dict, stream: bool = False):
    """Llama al backend LLM (GPU local o remoto) via OpenAI API."""
    if not httpx:
        raise RuntimeError("httpx no esta instalado. Ejecuta: pip install httpx")

    base_url = config["base_url"].rstrip("/")
    model = config["model"]
    api_key = config["api_key"]

    headers = {"Content-Type": "application/json"}
    if api_key and api_key != "local" and api_key != "not-needed":
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "temperature": 0.7,
        "stream": stream,
    }

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{base_url}/chat/completions",
            json=payload,
            headers=headers,
        )
        resp.raise_for_status()
        return resp.json()

# =============================================================================
#  AGENTE CON HERRAMIENTAS NATIVAS (modo ReAct simple)
# =============================================================================

SYSTEM_PROMPT_TOOLS = """Eres XTR, un asistente IA que se ejecuta completamente en local.
Tienes acceso a herramientas nativas del sistema. Para usar una herramienta, responde EXACTAMENTE en este formato:

<tool>bash</tool>
<args>{"command": "ls -la /root"}</args>

O para Python:
<tool>python</tool>
<args>{"code": "print(2+2)"}</args>

Herramientas disponibles:
- bash: ejecuta comandos shell
- python: ejecuta codigo Python
- read_file: lee un archivo
- write_file: escribe un archivo
- list_dir: lista directorio

Despues de ver el resultado de una herramienta, analizalo y decide si necesitas otra herramienta o si puedes dar la respuesta final.
Cuando tengas la respuesta final, escribe:
<final>Tu respuesta aqui</final>
"""

async def _agent_with_tools(req: AgentRequest):
    """Agente ReAct con herramientas nativas (bash, python, file ops)."""
    config = _get_effective_config(req)
    backend_alive = await _is_backend_alive(config["base_url"])
    if not backend_alive:
        yield {"type": "error", "error": f"Backend LLM no responde en {config['base_url']}"}
        yield {"type": "final", "answer": "⚠ El backend LLM no esta disponible. Verifica que el servidor este activo."}
        return

    messages = []
    system = req.system_prompt or SYSTEM_PROMPT_TOOLS
    messages.append({"role": "system", "content": system})
    for h in req.history[-10:]:
        if isinstance(h, dict) and "role" in h and "content" in h:
            messages.append(h)
    messages.append({"role": "user", "content": req.task})

    max_steps = 10
    for step in range(max_steps):
        try:
            data = await _call_llm(messages, config)
            assistant_msg = data["choices"][0]["message"]["content"]
            messages.append({"role": "assistant", "content": assistant_msg})

            # Buscar tool call
            if "<tool>" in assistant_msg and "<args>" in assistant_msg:
                import re
                tool_match = re.search(r"<tool>(\w+)</tool>", assistant_msg)
                args_match = re.search(r"<args>(.+?)</args>", assistant_msg, re.DOTALL)
                if tool_match and args_match:
                    tool_name = tool_match.group(1)
                    try:
                        tool_args = json.loads(args_match.group(1))
                    except json.JSONDecodeError:
                        tool_args = {"command": args_match.group(1).strip()}

                    yield {"type": "tool", "tool": tool_name, "args": tool_args, "step": step + 1}

                    # Ejecutar herramienta
                    result = {"error": "Herramienta desconocida"}
                    if tool_name == "bash":
                        result = TOOLS.bash(tool_args.get("command", ""))
                    elif tool_name == "python":
                        result = TOOLS.python(tool_args.get("code", ""))
                    elif tool_name == "read_file":
                        result = TOOLS.read_file(tool_args.get("path", ""))
                    elif tool_name == "write_file":
                        result = TOOLS.write_file(tool_args.get("path", ""), tool_args.get("content", ""))
                    elif tool_name == "list_dir":
                        result = TOOLS.list_dir(tool_args.get("path", "/root"))

                    obs = json.dumps(result, ensure_ascii=False)[:4000]
                    yield {"type": "observation", "observation": obs, "step": step + 1}
                    messages.append({"role": "user", "content": f"Resultado de {tool_name}: {obs}"})
                    continue

            # Buscar respuesta final
            if "<final>" in assistant_msg:
                final_match = re.search(r"<final>(.+?)</final>", assistant_msg, re.DOTALL)
                if final_match:
                    answer = final_match.group(1).strip()
                    yield {"type": "final", "answer": answer}
                    return

            # Si no hay tool ni final, asumir que es la respuesta
            yield {"type": "final", "answer": assistant_msg}
            return

        except Exception as e:
            yield {"type": "error", "error": str(e)}
            yield {"type": "final", "answer": f"Error: {str(e)[:200]}"}
            return

    yield {"type": "final", "answer": "Alcance el limite de pasos (10). Intenta simplificar la tarea."}

# =============================================================================
#  CHAT DIRECTO (sin herramientas)
# =============================================================================

async def _direct_chat(req: AgentRequest):
    """Chat directo con el LLM sin herramientas intermedias."""
    config = _get_effective_config(req)
    backend_alive = await _is_backend_alive(config["base_url"])
    if not backend_alive:
        yield {"type": "error", "error": f"Backend LLM no responde en {config['base_url']}"}
        yield {"type": "final", "answer": "⚠ El backend LLM no esta disponible. Verifica que el servidor este activo."}
        return

    messages = []
    system = req.system_prompt or (
        "Eres XTR, un asistente IA que se ejecuta completamente en local "
        "en el dispositivo del usuario. Responde de forma concisa y util."
    )
    messages.append({"role": "system", "content": system})
    for h in req.history[-10:]:
        if isinstance(h, dict) and "role" in h and "content" in h:
            messages.append(h)
    messages.append({"role": "user", "content": req.task})

    try:
        data = await _call_llm(messages, config)
        answer = data["choices"][0]["message"]["content"]
        yield {"type": "step", "thought": "Procesando..."}
        yield {"type": "final", "answer": answer}
    except Exception as e:
        yield {"type": "error", "error": str(e)}
        yield {"type": "final", "answer": f"Error: {str(e)[:200]}"}

# =============================================================================
#  SMOLAGENTS (opcional)
# =============================================================================

async def _smolagents_run(req: AgentRequest):
    """Ejecuta tarea usando smolagents (si esta instalado)."""
    if not _SMOLAGENTS_OK:
        yield {"type": "error", "error": "smolagents no esta instalado"}
        yield {"type": "final", "answer": "⚠ smolagents no esta instalado. Ejecuta: pip install smolagents"}
        return

    config = _get_effective_config(req)
    try:
        model = HfApiModel(
            model_id=config["model"],
            api_base=config["base_url"],
            api_key=config["api_key"] if config["api_key"] not in ("local", "not-needed") else None,
        )
        agent = CodeAgent(
            tools=[DuckDuckGoSearchTool()],
            model=model,
            additional_authorized_imports=["os", "sys", "subprocess", "json", "math"],
        )
        result = agent.run(req.task)
        yield {"type": "final", "answer": str(result)}
    except Exception as e:
        yield {"type": "error", "error": str(e)}
        yield {"type": "final", "answer": f"Error smolagents: {str(e)[:200]}"}

# =============================================================================
#  ENDPOINTS
# =============================================================================

@app.get("/health")
async def health():
    """Health check completo con estado del backend."""
    config = _get_effective_config(AgentRequest(task=""))
    backend_alive = await _is_backend_alive(config["base_url"])
    is_gpu_local = "127.0.0.1:8090" in config["base_url"]
    return {
        "status": "ok",
        "version": "12.0",
        "port": AGENT_PORT,
        "backend": {
            "url": config["base_url"],
            "alive": backend_alive,
            "model": config["model"],
            "is_gpu_local": is_gpu_local,
        },
        "gpu_server_alive": await _is_backend_alive(GPU_LOCAL_BASE) if is_gpu_local else False,
        "gpu_port": GPU_LOCAL_PORT,
        "smolagents_available": _SMOLAGENTS_OK,
        "pid": os.getpid(),
    }

@app.post("/run")
async def run_streaming(req: AgentRequest):
    """Ejecuta tarea con streaming SSE."""
    if not req.task.strip():
        raise HTTPException(status_code=400, detail="task no puede estar vacio")

    async def generate():
        if req.use_native_tools and _SMOLAGENTS_OK:
            async for event in _smolagents_run(req):
                yield sse(event)
        elif req.use_native_tools:
            # Fallback a herramientas nativas si smolagents no esta
            async for event in _agent_with_tools(req):
                yield sse(event)
        else:
            async for event in _direct_chat(req):
                yield sse(event)

    return StreamingResponse(generate(), media_type="text/event-stream")

@app.post("/chat")
async def chat(req: AgentRequest):
    """Alias de /run para compatibilidad."""
    return await run_streaming(req)

@app.get("/tools")
async def list_tools():
    """Lista herramientas disponibles."""
    tools = [
        {"name": "bash", "description": "Ejecuta comandos shell en el contenedor"},
        {"name": "python", "description": "Ejecuta codigo Python"},
        {"name": "read_file", "description": "Lee un archivo del contenedor"},
        {"name": "write_file", "description": "Escribe un archivo en el contenedor"},
        {"name": "list_dir", "description": "Lista archivos en un directorio"},
    ]
    if _SMOLAGENTS_OK:
        tools.append({"name": "smolagents", "description": "Agente de codigo con busqueda web (smolagents)"})
    return {"tools": tools, "smolagents_available": _SMOLAGENTS_OK}

@app.get("/gpu/status")
async def gpu_status():
    """Estado del servidor GPU MediaPipe."""
    alive = await _is_backend_alive(GPU_LOCAL_BASE)
    return {"active": alive, "port": GPU_LOCAL_PORT, "base_url": GPU_LOCAL_BASE}

# =============================================================================
#  MAIN
# =============================================================================

if __name__ == "__main__":
    log.info("=" * 50)
    log.info("XTR Agent Server v12.0")
    log.info("Puerto: %d", AGENT_PORT)
    log.info("Backend: %s", LLM_BASE_URL)
    log.info("Modelo: %s", LLM_MODEL)
    log.info("PID: %d", os.getpid())
    log.info("=" * 50)
    uvicorn.run(app, host="127.0.0.1", port=AGENT_PORT, log_level="warning")
