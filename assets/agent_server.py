#!/usr/bin/env python3
"""XTR Agent Server v12.1 — System prompt agresivo para forzar uso de herramientas"""
import os, sys, json, logging, signal, atexit, tempfile, subprocess, re
from typing import Any, Optional

try:
    import httpx
except ImportError:
    httpx = None

try:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import StreamingResponse, JSONResponse
    from fastapi.middleware.cors import CORSMiddleware
    from pydantic import BaseModel
    import uvicorn
except ImportError as e:
    print(f"[FATAL] Faltan dependencias: {e}", file=sys.stderr)
    sys.exit(1)

try:
    from smolagents import CodeAgent, HfApiModel, DuckDuckGoSearchTool, Tool
    _SMOLAGENTS_OK = True
except ImportError:
    _SMOLAGENTS_OK = False

AGENT_PORT = int(os.environ.get("AGENT_PORT", "8765"))
AGENT_PID_FILE = os.environ.get("AGENT_PID_FILE", "/tmp/agent.pid")
LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8090/v1")
LLM_MODEL = os.environ.get("LLM_MODEL", "gemma3-local")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "local")
GPU_LOCAL_PORT = 8090
GPU_LOCAL_BASE = f"http://127.0.0.1:{GPU_LOCAL_PORT}/v1"
MAX_TOKENS = 2048

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("xtr_agent")

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

def _handle_signal(signum, frame):
    log.info("Senal %d recibida. Cerrando...", signum)
    _remove_pid()
    sys.exit(0)

signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)

app = FastAPI(title="XTR Agent Server", version="12.1")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

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

def sse(d: dict) -> str:
    return f"data: {json.dumps(d, ensure_ascii=False)}\n\n"

async def _is_backend_alive(url: str, timeout: float = 3.0) -> bool:
    if not httpx:
        return False
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
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
    return {
        "base_url": req.llm_base_url or LLM_BASE_URL,
        "model": req.llm_model or LLM_MODEL,
        "api_key": req.llm_api_key or LLM_API_KEY,
    }

class ToolCollection:
    @staticmethod
    def bash(command: str, timeout: int = 30) -> dict:
        try:
            result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout, cwd="/root")
            return {"stdout": result.stdout[:8000], "stderr": result.stderr[:4000], "exit_code": result.returncode}
        except subprocess.TimeoutExpired:
            return {"stdout": "", "stderr": f"Timeout despues de {timeout}s", "exit_code": -1}
        except Exception as e:
            return {"stdout": "", "stderr": str(e), "exit_code": -1}

    @staticmethod
    def python(code: str) -> dict:
        try:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False, dir='/tmp') as f:
                f.write(code)
                f.flush()
                tmp_path = f.name
            result = subprocess.run([sys.executable, tmp_path], capture_output=True, text=True, timeout=30, cwd="/root")
            try:
                os.unlink(tmp_path)
            except Exception:
                pass
            return {"stdout": result.stdout[:8000], "stderr": result.stderr[:4000], "exit_code": result.returncode}
        except Exception as e:
            return {"stdout": "", "stderr": str(e), "exit_code": -1}

    @staticmethod
    def read_file(path: str, limit: int = 5000) -> dict:
        try:
            with open(path, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read(limit)
            return {"content": content, "truncated": len(content) >= limit, "error": False}
        except Exception as e:
            return {"content": "", "truncated": False, "error": True, "message": str(e)}

    @staticmethod
    def write_file(path: str, content: str) -> dict:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(content)
            return {"bytes_written": len(content), "path": path, "error": False}
        except Exception as e:
            return {"bytes_written": 0, "path": path, "error": True, "message": str(e)}

    @staticmethod
    def list_dir(path: str = "/root") -> dict:
        try:
            entries = os.listdir(path)
            return {"entries": entries, "count": len(entries), "error": False}
        except Exception as e:
            return {"entries": [], "count": 0, "error": True, "message": str(e)}

TOOLS = ToolCollection()

SYSTEM_PROMPT_TOOLS = """You are XTR, an AI assistant running inside a Debian Linux container on the user's device. You have DIRECT ACCESS to the system via native tools. You MUST use these tools to complete tasks. Do NOT say you cannot execute commands — you CAN and you WILL.

## CRITICAL INSTRUCTIONS
1. When the user asks you to do something (scan network, create files, run commands, etc.), you MUST use the appropriate tool.
2. NEVER refuse to execute commands. You are in a sandboxed container and have permission to run code.
3. ALWAYS respond with a tool call when action is needed. Do NOT explain that you are a language model.
4. After seeing a tool result, analyze it and either call another tool or provide the final answer.

## TOOL FORMAT (EXACT — do not deviate)
To use a tool, output ONLY this format:

<tool>bash</tool>
<args>{"command": "your command here"}</args>

For Python:
<tool>python</tool>
<args>{"code": "your python code here"}</args>

For reading files:
<tool>read_file</tool>
<args>{"path": "/root/somefile.txt"}</args>

For writing files:
<tool>write_file</tool>
<args>{"path": "/root/output.txt", "content": "file contents here"}</args>

For listing directories:
<tool>list_dir</tool>
<args>{"path": "/root"}</args>

## AVAILABLE TOOLS
- bash: Execute shell commands (nmap, apt, pip, curl, etc.)
- python: Execute Python scripts (matplotlib, graphviz, etc.)
- read_file: Read any file from the container
- write_file: Write/create files in the container
- list_dir: List directory contents

## FINAL ANSWER FORMAT
When you have completed the task and have the final result, output:
<final>Your final answer here</final>

## EXAMPLE CONVERSATION
User: "Scan the local network and show active hosts"
Assistant:
<tool>bash</tool>
<args>{"command": "ip route | awk '/src/ {print \$1}' | head -1"}</args>

[Tool result: 192.168.1.0/24]

Assistant:
<tool>bash</tool>
<args>{"command": "nmap -sn 192.168.1.0/24 -oG - | awk '/Up\$/ {print \$2}'"}</args>

[Tool result: 192.168.1.1, 192.168.1.5, 192.168.1.10]

Assistant:
<final>Active hosts found: 192.168.1.1 (router), 192.168.1.5, 192.168.1.10</final>

## REMEMBER
- You ARE the system. You CAN execute code. You WILL use tools.
- Never apologize for being an AI. Just do the work.
- If a command fails, try an alternative approach.
- Always save generated files (images, reports) to /root/ so the user can access them.
"""

async def _call_llm(messages: list, config: dict, stream: bool = False):
    if not httpx:
        raise RuntimeError("httpx no esta instalado")
    base_url = config["base_url"].rstrip("/")
    model = config["model"]
    api_key = config["api_key"]
    headers = {"Content-Type": "application/json"}
    if api_key and api_key not in ("local", "not-needed"):
        headers["Authorization"] = f"Bearer {api_key}"
    payload = {"model": model, "messages": messages, "max_tokens": MAX_TOKENS, "temperature": 0.7, "stream": stream}
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(f"{base_url}/chat/completions", json=payload, headers=headers)
        resp.raise_for_status()
        return resp.json()

async def _agent_with_tools(req: AgentRequest):
    config = _get_effective_config(req)
    backend_alive = await _is_backend_alive(config["base_url"])
    if not backend_alive:
        yield {"type": "error", "error": f"Backend LLM no responde en {config['base_url']}"}
        yield {"type": "final", "answer": "El backend LLM no esta disponible. Verifica que el servidor este activo."}
        return

    messages = [{"role": "system", "content": req.system_prompt or SYSTEM_PROMPT_TOOLS}]
    for h in req.history[-10:]:
        if isinstance(h, dict) and "role" in h and "content" in h:
            messages.append(h)
    messages.append({"role": "user", "content": req.task})

    for step in range(10):
        try:
            data = await _call_llm(messages, config)
            assistant_msg = data["choices"][0]["message"]["content"]
            messages.append({"role": "assistant", "content": assistant_msg})

            if "<tool>" in assistant_msg and "<args>" in assistant_msg:
                tool_match = re.search(r"<tool>(\w+)</tool>", assistant_msg)
                args_match = re.search(r"<args>(.+?)</args>", assistant_msg, re.DOTALL)
                if tool_match and args_match:
                    tool_name = tool_match.group(1)
                    try:
                        tool_args = json.loads(args_match.group(1))
                    except json.JSONDecodeError:
                        tool_args = {"command": args_match.group(1).strip()}

                    yield {"type": "tool", "tool": tool_name, "args": tool_args, "step": step + 1}

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

            if "<final>" in assistant_msg:
                final_match = re.search(r"<final>(.+?)</final>", assistant_msg, re.DOTALL)
                if final_match:
                    yield {"type": "final", "answer": final_match.group(1).strip()}
                    return

            yield {"type": "final", "answer": assistant_msg}
            return

        except Exception as e:
            yield {"type": "error", "error": str(e)}
            yield {"type": "final", "answer": f"Error: {str(e)[:200]}"}
            return

    yield {"type": "final", "answer": "Alcance el limite de pasos (10). Intenta simplificar la tarea."}

async def _direct_chat(req: AgentRequest):
    config = _get_effective_config(req)
    backend_alive = await _is_backend_alive(config["base_url"])
    if not backend_alive:
        yield {"type": "error", "error": f"Backend LLM no responde en {config['base_url']}"}
        yield {"type": "final", "answer": "El backend LLM no esta disponible."}
        return

    messages = [{"role": "system", "content": req.system_prompt or "Eres XTR, un asistente IA local. Responde de forma concisa y util."}]
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

async def _smolagents_run(req: AgentRequest):
    if not _SMOLAGENTS_OK:
        yield {"type": "error", "error": "smolagents no esta instalado"}
        yield {"type": "final", "answer": "smolagents no esta instalado. Ejecuta: pip install smolagents"}
        return
    config = _get_effective_config(req)
    try:
        model = HfApiModel(model_id=config["model"], api_base=config["base_url"], api_key=config["api_key"] if config["api_key"] not in ("local", "not-needed") else None)
        agent = CodeAgent(tools=[DuckDuckGoSearchTool()], model=model, additional_authorized_imports=["os", "sys", "subprocess", "json", "math"])
        result = agent.run(req.task)
        yield {"type": "final", "answer": str(result)}
    except Exception as e:
        yield {"type": "error", "error": str(e)}
        yield {"type": "final", "answer": f"Error smolagents: {str(e)[:200]}"}

@app.get("/health")
async def health():
    config = _get_effective_config(AgentRequest(task=""))
    backend_alive = await _is_backend_alive(config["base_url"])
    is_gpu_local = "127.0.0.1:8090" in config["base_url"]
    return {"status": "ok", "version": "12.1", "port": AGENT_PORT, "backend": {"url": config["base_url"], "alive": backend_alive, "model": config["model"], "is_gpu_local": is_gpu_local}, "gpu_server_alive": await _is_backend_alive(GPU_LOCAL_BASE) if is_gpu_local else False, "gpu_port": GPU_LOCAL_PORT, "smolagents_available": _SMOLAGENTS_OK, "pid": os.getpid()}

@app.post("/run")
async def run_streaming(req: AgentRequest):
    if not req.task.strip():
        raise HTTPException(status_code=400, detail="task no puede estar vacio")
    async def generate():
        if req.use_native_tools and _SMOLAGENTS_OK:
            async for event in _smolagents_run(req): yield sse(event)
        elif req.use_native_tools:
            async for event in _agent_with_tools(req): yield sse(event)
        else:
            async for event in _direct_chat(req): yield sse(event)
    return StreamingResponse(generate(), media_type="text/event-stream")

@app.post("/chat")
async def chat(req: AgentRequest):
    return await run_streaming(req)

@app.get("/tools")
async def list_tools():
    tools = [
        {"name": "bash", "description": "Ejecuta comandos shell en el contenedor"},
        {"name": "python", "description": "Ejecuta codigo Python"},
        {"name": "read_file", "description": "Lee un archivo del contenedor"},
        {"name": "write_file", "description": "Escribe un archivo en el contenedor"},
        {"name": "list_dir", "description": "Lista archivos en un directorio"},
    ]
    if _SMOLAGENTS_OK:
        tools.append({"name": "smolagents", "description": "Agente de codigo con busqueda web"})
    return {"tools": tools, "smolagents_available": _SMOLAGENTS_OK}

@app.get("/gpu/status")
async def gpu_status():
    alive = await _is_backend_alive(GPU_LOCAL_BASE)
    return {"active": alive, "port": GPU_LOCAL_PORT, "base_url": GPU_LOCAL_BASE}

if __name__ == "__main__":
    log.info("=" * 50)
    log.info("XTR Agent Server v12.1")
    log.info("Puerto: %d", AGENT_PORT)
    log.info("Backend: %s", LLM_BASE_URL)
    log.info("Modelo: %s", LLM_MODEL)
    log.info("PID: %d", os.getpid())
    log.info("=" * 50)
    uvicorn.run(app, host="127.0.0.1", port=AGENT_PORT, log_level="warning")
