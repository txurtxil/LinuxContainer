import json, subprocess, urllib.request, os
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn
from smolagents import OpenAIServerModel, ToolCallingAgent, CodeAgent, tool

LLAMA_BASE = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8080")

@tool
def run_bash(command: str) -> str:
    """Ejecuta un comando de bash en este Debian y devuelve su salida."""
    try:
        r = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=30)
        out, err = (r.stdout or "").strip(), (r.stderr or "").strip()
        combined = out + (f"\n[stderr]: {err}" if err else "")
        return combined[:3000] if combined else "(sin salida)"
    except Exception as e:
        return f"Error ejecutando el comando: {e}"

def _recover_answer(error_msg): return f"Intento de recuperación activado. Error original: {error_msg}"
def _friendly_error(error_msg): return f"Ups, ha habido un problema remoto o de conexión: {error_msg}"

def build_agent():
    model = OpenAIServerModel(model_id="gemma3-4b-it", api_base=f"{LLAMA_BASE}/v1", api_key="not-needed")
    if "8090" in LLAMA_BASE:
        return CodeAgent(name="DebianAgent_LocalGPU", model=model, tools=[run_bash])
    else:
        return ToolCallingAgent(name="DebianAgent", model=model, tools=[run_bash])

app = FastAPI()

def sse(d: dict) -> str: return f"data: {json.dumps(d, ensure_ascii=False)}\n\n"

def serialize_step(step) -> dict:
    out = {"type": "step"}
    if hasattr(step, "step_number"): out["step"] = step.step_number
    if hasattr(step, "model_output"): out["thought"] = str(step.model_output)
    if hasattr(step, "tool_calls") and step.tool_calls:
        out["tool_calls"] = [{"name": getattr(tc, "name", None), "arguments": getattr(tc, "arguments", None)} for tc in step.tool_calls]
    if hasattr(step, "observations"): out["observation"] = str(step.observations)
    if hasattr(step, "error") and step.error: out["error"] = str(step.error)
    return out

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
                elif is_step: yield sse(serialize_step(item))
                else: final = item
            yield sse({"type": "final", "answer": str(final) if final is not None else ""})
        except Exception as e:
            error_msg = str(e)
            if "400" in error_msg or "503" in error_msg:
                yield sse({"type": "error", "error": _friendly_error(error_msg)})
                yield sse({"type": "final", "answer": _recover_answer(error_msg)})
            else:
                yield sse({"type": "error", "error": error_msg})

    return StreamingResponse(gen(), media_type="text/event-stream")

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765, log_level="info")
