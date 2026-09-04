#!/usr/bin/env python3
"""
XTR Terminal — agent_server.py v10.1
Servidor FastAPI para el agente IA — ejecuta dentro de proot Debian arm64
Puerto: 8765 | Venv: /root/agent-env

Endpoints:
  GET  /health        — Health check
  POST /run           — Ejecuta tarea (SSE streaming)
  POST /chat          — Alias de /run
  GET  /tools         — Lista tools disponibles
  GET  /gpu/status    — Estado del servidor GPU MediaPipe
"""

import os
import sys
import json
import logging
from typing import Any

try:
    import httpx
    from fastapi import FastAPI, HTTPException
    from fastapi.responses import StreamingResponse
    from fastapi.middleware.cors import CORSMiddleware
    from pydantic import BaseModel
    import uvicorn
except ImportError as e:
    print(f"[FATAL] Faltan dependencias: {e}", file=sys.stderr)
    print("[FATAL] Ejecuta: /root/agent-env/bin/pip install fastapi uvicorn pydantic httpx", file=sys.stderr)
    sys.exit(1)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("xtr_agent")

app = FastAPI(title="XTR Agent Server", version="10.1")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

GPU_LOCAL_PORT = 8090
GPU_LOCAL_BASE = f"http://127.0.0.1:{GPU_LOCAL_PORT}/v1"
AGENT_PORT = int(os.environ.get("AGENT_PORT", "8765"))
MAX_TOKENS = 2048

class AgentRequest(BaseModel):
    task: str
    llm_base_url: str = ""
    llm_api_key: str = ""
    llm_model: str = "gemma3-local"
    history: list = []
    system_prompt: str = ""
    image_base64: str = ""
    use_native_tools: bool = False

class AgentResponse(BaseModel):
    answer: str
    thoughts: list = []
    error: bool = False

async def _is_gpu_server_alive() -> bool:
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{GPU_LOCAL_BASE}/models")
            return resp.status_code == 200
    except Exception:
        return False

def sse(d: dict) -> str:
    return f"data: {json.dumps(d, ensure_ascii=False)}\n\n"

async def _direct_chat_gpu(req: AgentRequest):
    if not await _is_gpu_server_alive():
        yield {"type": "final", "answer": "⚠ El servidor GPU MediaPipe no está activo. Ve a 'Prueba GPU' en la app para cargar un modelo .task."}
        return

    messages = []
    system = req.system_prompt or (
        "Eres XTR, un asistente IA que se ejecuta completamente en local "
        "en el dispositivo del usuario. Responde de forma concisa y útil."
    )
    messages.append({"role": "system", "content": system})
    for h in req.history[-10:]:
        if isinstance(h, dict) and "role" in h and "content" in h:
            messages.append(h)
    messages.append({"role": "user", "content": req.task})

    payload = {
        "model": "gemma",
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "temperature": 0.7,
        "stream": False,
    }
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                f"{GPU_LOCAL_BASE}/chat/completions",
                json=payload,
                headers={"Content-Type": "application/json"},
            )
            resp.raise_for_status()
            data = resp.json()
            answer = data["choices"][0]["message"]["content"]
            yield {"type": "step", "thought": "Procesando..."}
            yield {"type": "final", "answer": answer}
    except Exception as e:
        yield {"type": "error", "error": str(e)}
        yield {"type": "final", "answer": f"Error: {str(e)[:200]}"}

@app.get("/health")
async def health():
    gpu_alive = await _is_gpu_server_alive()
    return {"status": "ok", "version": "10.1", "gpu_server_alive": gpu_alive, "gpu_port": GPU_LOCAL_PORT}

@app.post("/run")
async def run_streaming(req: AgentRequest):
    if not req.task.strip():
        raise HTTPException(status_code=400, detail="task no puede estar vacio")
    async def generate():
        async for event in _direct_chat_gpu(req):
            yield sse(event)
    return StreamingResponse(generate(), media_type="text/event-stream")

@app.post("/chat")
async def chat(req: AgentRequest):
    async def generate():
        async for event in _direct_chat_gpu(req):
            yield sse(event)
    return StreamingResponse(generate(), media_type="text/event-stream")

@app.get("/tools")
async def list_tools():
    return {"tools": [{"name": "gpu_chat", "description": "Chat directo con el modelo GPU cargado"}]}

@app.get("/gpu/status")
async def gpu_status():
    alive = await _is_gpu_server_alive()
    return {"active": alive, "port": GPU_LOCAL_PORT}

if __name__ == "__main__":
    log.info("Iniciando XTR Agent Server v10.1 en puerto %d", AGENT_PORT)
    log.info("GPU MediaPipe esperado en puerto %d", GPU_LOCAL_PORT)
    uvicorn.run(app, host="127.0.0.1", port=AGENT_PORT, log_level="warning")
