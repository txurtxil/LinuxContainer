#!/usr/bin/env python3
import sys, os, traceback

# Sistema de pánico: atrapar errores críticos antes de que el servidor muera
LOG_FILE = "/root/agent_server_crash.log"
def write_log(msg):
    with open(LOG_FILE, "w") as f: f.write(msg)

try:
    import json, subprocess, urllib.request
    from fastapi import FastAPI
    from fastapi.responses import StreamingResponse
    from pydantic import BaseModel
    import uvicorn
    from smolagents import OpenAIServerModel, ToolCallingAgent, CodeAgent, tool
    
    # Si todo carga bien, limpiamos logs antiguos
    if os.path.exists(LOG_FILE): os.remove(LOG_FILE)
except ImportError as e:
    write_log(f"FALTAN DEPENDENCIAS DE PYTHON (pip install).\nError: {e}\n\nSolución: Ejecuta en la terminal de la app:\npip install --break-system-packages fastapi uvicorn smolagents pydantic\n")
    sys.exit(1)
except Exception as e:
    write_log(f"Error grave al iniciar:\n{traceback.format_exc()}")
    sys.exit(1)

LLAMA_BASE = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8080")

@tool
def run_bash(command: str) -> str:
    """Ejecuta un comando bash y devuelve la salida. Úsalo para interactuar con Debian."""
    try:
        r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=30)
        out, err = (r.stdout or "").strip(), (r.stderr or "").strip()
        combined = out + (f"\n[stderr]: {err}" if err else "")
        return combined[:3000] if combined else "(sin salida)"
    except Exception as e:
        return f"Error ejecutando el comando: {e}"

def _recover_answer(err): return f"Fallo remoto detectado. Error: {err}"
def _friendly_error(err): return f"Ups, error de red o de la IA: {err}"

def build_agent():
    model = OpenAIServerModel(model_id="gemma3-4b-it", api_base=f"{LLAMA_BASE}/v1", api_key="not-needed")
    if "8090" in LLAMA_BASE:
        # Modo CodeAgent para GPU Local (bucle puro de texto)
        return CodeAgent(name="DebianAgent_LocalGPU", model=model, tools=[run_bash])
    else:
        # Modo ToolCalling para APIs compatibles o llama.cpp
        return ToolCallingAgent(name="DebianAgent", model=model, tools=[run_bash])

app = FastAPI()

def sse(d: dict) -> str: return f"data: {json.dumps(d, ensure_ascii=False)}\n\n"
class RunReq(BaseModel): prompt: str

@app.post("/run")
def run(req: RunReq):
    def gen():
        try:
            agent = build_agent()
            yield sse({"type": "start", "prompt": req.prompt})
            final = None
            for item in agent.run(req.prompt, stream=True):
                fa = getattr(item, "final_answer", None)
                is_step = any(hasattr(item, a) for a in ("tool_calls", "model_output", "observations"))
                if fa is not None: final = fa
                elif is_step:
                    # Serialización segura del paso
                    out = {"type": "step"}
                    if hasattr(item, "model_output"): out["thought"] = str(item.model_output)
                    if hasattr(item, "observations"): out["observation"] = str(item.observations)
                    yield sse(out)
                else: final = item
            yield sse({"type": "final", "answer": str(final) if final is not None else ""})
        except Exception as e:
            msg = str(e)
            yield sse({"type": "error", "error": _friendly_error(msg)})
            yield sse({"type": "final", "answer": _recover_answer(msg)})
    return StreamingResponse(gen(), media_type="text/event-stream")

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="error")
