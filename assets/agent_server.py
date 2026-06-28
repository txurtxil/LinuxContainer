#!/usr/bin/env python3
"""
XTR Terminal — agent_server.py
Agente smolagents con FastAPI — ejecuta dentro de proot Debian arm64
Puerto: 8765 | Venv: /root/agent-env

Fuentes soportadas:
  - Groq         (llama-3.1-8b-instant — mejor tool-calling)
  - Gemini        (gemini-3.5-flash, gemini-2.5-flash — tier gratuito)
  - Cerebras
  - OpenRouter
  - GPU Local     (MediaPipe en 127.0.0.1:8090 — directo sin tool-calling)
  - Custom

NOTA: llama.cpp / CPU inference ELIMINADO.
      Inferencia local SIEMPRE via GPU MediaPipe (puerto 8090).
"""

import os
import json
import logging
import traceback
from typing import Any, Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# smolagents
from smolagents import (
    ToolCallingAgent,
    CodeAgent,
    OpenAIServerModel,
    tool,
)

# ── Logging ──────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("xtr_agent")

# ── FastAPI ──────────────────────────────────────────────────
app = FastAPI(title="XTR Agent Server", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Constantes ───────────────────────────────────────────────
GPU_LOCAL_PORT    = 8090
GPU_LOCAL_BASE    = f"http://127.0.0.1:{GPU_LOCAL_PORT}/v1"
AGENT_PORT        = 8765
MAX_STEPS         = 8
MAX_TOKENS        = 2048

# ── Modelos de request/response ──────────────────────────────
class AgentRequest(BaseModel):
    task:           str
    llm_base_url:   str  = ""
    llm_api_key:    str  = ""
    llm_model:      str  = "llama-3.1-8b-instant"
    history:        list = []
    system_prompt:  str  = ""

class AgentResponse(BaseModel):
    answer:   str
    thoughts: list  = []
    error:    bool  = False

# ─────────────────────────────────────────────────────────────
# TOOLS
# ─────────────────────────────────────────────────────────────

@tool
def run_bash(command: str) -> str:
    """
    Ejecuta un comando bash en el sistema Linux local (proot Debian).
    Args:
        command: Comando bash a ejecutar
    Returns:
        Salida stdout/stderr del comando
    """
    import subprocess
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=60,
            cwd="/root",
        )
        output = result.stdout + result.stderr
        return output[:4000] if len(output) > 4000 else output
    except subprocess.TimeoutExpired:
        return "Error: comando agotó el tiempo límite (60s)"
    except Exception as e:
        return f"Error ejecutando comando: {e}"


@tool
def write_file(path: str, content: str) -> str:
    """
    Escribe contenido en un fichero.
    Args:
        path:    Ruta del fichero (absoluta o relativa a /root)
        content: Contenido a escribir
    Returns:
        Mensaje de éxito o error
    """
    try:
        if not path.startswith("/"):
            path = f"/root/{path}"
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return f"Fichero escrito: {path} ({len(content)} caracteres)"
    except Exception as e:
        return f"Error escribiendo fichero: {e}"


@tool
def read_file(path: str) -> str:
    """
    Lee el contenido de un fichero.
    Args:
        path: Ruta del fichero
    Returns:
        Contenido del fichero o error
    """
    try:
        if not path.startswith("/"):
            path = f"/root/{path}"
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        return content[:8000] if len(content) > 8000 else content
    except FileNotFoundError:
        return f"Error: fichero no encontrado: {path}"
    except Exception as e:
        return f"Error leyendo fichero: {e}"


@tool
def make_dir(path: str) -> str:
    """
    Crea un directorio (y subdirectorios necesarios).
    Args:
        path: Ruta del directorio a crear
    Returns:
        Mensaje de éxito o error
    """
    try:
        if not path.startswith("/"):
            path = f"/root/{path}"
        os.makedirs(path, exist_ok=True)
        return f"Directorio creado: {path}"
    except Exception as e:
        return f"Error creando directorio: {e}"


@tool
def list_files(path: str = "/root") -> str:
    """
    Lista ficheros y directorios en una ruta.
    Args:
        path: Ruta a listar (por defecto /root)
    Returns:
        Lista de ficheros y directorios
    """
    try:
        if not path.startswith("/"):
            path = f"/root/{path}"
        items = os.listdir(path)
        items.sort()
        lines = []
        for item in items:
            full = os.path.join(path, item)
            is_dir  = os.path.isdir(full)
            size    = os.path.getsize(full) if not is_dir else 0
            marker  = "/" if is_dir else ""
            size_str = f"  ({size} B)" if not is_dir else ""
            lines.append(f"{'📁' if is_dir else '📄'} {item}{marker}{size_str}")
        return "\n".join(lines) if lines else "(vacío)"
    except Exception as e:
        return f"Error listando directorio: {e}"


TOOLS = [run_bash, write_file, read_file, make_dir, list_files]

# ─────────────────────────────────────────────────────────────
# Detección de GPU local
# ─────────────────────────────────────────────────────────────

def _is_gpu_local(req: AgentRequest) -> bool:
    """True si la petición va dirigida al servidor MediaPipe local."""
    url = req.llm_base_url.lower()
    return (
        str(GPU_LOCAL_PORT) in url or
        "8090" in url or
        req.llm_model in ("gemma3-local-gpu", "gemma", "gemma3") or
        req.llm_api_key == "local"
    )


async def _is_gpu_server_alive() -> bool:
    """Comprueba si el servidor MediaPipe está activo."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{GPU_LOCAL_BASE}/models")
            return resp.status_code == 200
    except Exception:
        return False

# ─────────────────────────────────────────────────────────────
# Chat directo (GPU local — sin tool-calling)
# ─────────────────────────────────────────────────────────────

async def _direct_chat_gpu(req: AgentRequest) -> AgentResponse:
    """
    Chat directo contra MediaPipe GPU (puerto 8090).
    Gemma 3 1B/4B no soporta tool-calling — modo conversacional puro.
    """
    if not await _is_gpu_server_alive():
        return AgentResponse(
            answer="⚠ El servidor GPU MediaPipe no está activo.\n"
                   "Ve a 'Prueba GPU' en la app para cargar un modelo .task.",
            error=True,
        )

    messages = []

    # System prompt
    system = req.system_prompt or (
        "Eres XTR, un asistente IA que se ejecuta completamente en local "
        "en el dispositivo del usuario. Responde de forma concisa y útil."
    )
    messages.append({"role": "system", "content": system})

    # Historial
    for h in req.history[-10:]:  # últimos 10 turnos
        if isinstance(h, dict) and "role" in h and "content" in h:
            messages.append(h)

    # Tarea actual
    messages.append({"role": "user", "content": req.task})

    payload = {
        "model":       "gemma",  # MediaPipe ignora el nombre, usa el .task cargado
        "messages":    messages,
        "max_tokens":  MAX_TOKENS,
        "temperature": 0.7,
        "stream":      False,
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
            return AgentResponse(answer=answer, thoughts=["[GPU local — MediaPipe]"])
    except httpx.HTTPStatusError as e:
        return _friendly_error(f"Error GPU {e.response.status_code}: {e.response.text[:200]}")
    except Exception as e:
        return _friendly_error(str(e))

# ─────────────────────────────────────────────────────────────
# Agente smolagents (fuentes remotas con tool-calling)
# ─────────────────────────────────────────────────────────────

def _build_model(req: AgentRequest) -> OpenAIServerModel:
    """Construye el modelo LLM para smolagents."""
    base_url = req.llm_base_url or _default_base_url(req.llm_model)

    return OpenAIServerModel(
        model_id=req.llm_model,
        api_base=base_url,
        api_key=req.llm_api_key or "no-key",
    )


def _default_base_url(model: str) -> str:
    """Infiere la URL base según el nombre del modelo."""
    m = model.lower()
    if "gemini" in m:
        return "https://generativelanguage.googleapis.com/v1beta/openai"
    if "llama" in m or "mixtral" in m or "gemma2" in m:
        return "https://api.groq.com/openai/v1"
    if "cerebras" in m:
        return "https://api.cerebras.ai/v1"
    return "https://api.groq.com/openai/v1"


async def _run_agent(req: AgentRequest) -> AgentResponse:
    """Ejecuta el agente smolagents con tool-calling."""
    try:
        model = _build_model(req)

        # Construir contexto desde historial
        context = ""
        if req.history:
            recent = req.history[-6:]
            context = "\n".join(
                f"{'Usuario' if h.get('role') == 'user' else 'Asistente'}: {h.get('content', '')}"
                for h in recent
                if isinstance(h, dict)
            )

        task_with_context = req.task
        if context:
            task_with_context = f"Contexto previo:\n{context}\n\nTarea actual: {req.task}"

        agent = ToolCallingAgent(
            tools=TOOLS,
            model=model,
            max_steps=MAX_STEPS,
        )

        result = agent.run(task_with_context)

        thoughts = []
        if hasattr(agent, 'logs'):
            for entry in agent.logs:
                if hasattr(entry, 'llm_output') and entry.llm_output:
                    thoughts.append(str(entry.llm_output)[:500])

        return AgentResponse(
            answer=str(result),
            thoughts=thoughts[:5],
        )

    except Exception as e:
        log.error("Error en agente: %s", traceback.format_exc())
        return await _recover_answer(req, str(e))


async def _recover_answer(req: AgentRequest, error_msg: str) -> AgentResponse:
    """
    Fallback: si el agente falla (ej. error 400 remoto), intenta
    chat directo sin tools.
    """
    log.warning("Recuperando respuesta tras error: %s", error_msg[:100])

    try:
        base_url = req.llm_base_url or _default_base_url(req.llm_model)
        payload  = {
            "model":      req.llm_model,
            "messages":   [
                {"role": "system",
                 "content": "Eres XTR, un asistente IA. Responde de forma concisa."},
                {"role": "user", "content": req.task},
            ],
            "max_tokens": 1024,
        }
        headers = {
            "Content-Type":  "application/json",
            "Authorization": f"Bearer {req.llm_api_key}",
        }

        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                f"{base_url}/chat/completions",
                json=payload,
                headers=headers,
            )
            if resp.status_code == 200:
                data   = resp.json()
                answer = data["choices"][0]["message"]["content"]
                return AgentResponse(
                    answer=answer,
                    thoughts=["[fallback — sin tools]"],
                )
    except Exception as e2:
        log.error("Fallback también falló: %s", e2)

    return _friendly_error(error_msg)


def _friendly_error(msg: str) -> AgentResponse:
    """Convierte un error técnico en respuesta amigable."""
    if "401" in msg or "authentication" in msg.lower():
        text = "⚠ API key inválida o expirada. Revisa la configuración de la fuente."
    elif "429" in msg or "rate" in msg.lower():
        text = "⚠ Límite de peticiones alcanzado. Espera un momento e intenta de nuevo."
    elif "503" in msg or "unavailable" in msg.lower():
        text = "⚠ Servicio temporalmente no disponible. Intenta con otra fuente."
    elif "timeout" in msg.lower() or "timed out" in msg.lower():
        text = "⚠ Tiempo de espera agotado. El servidor tardó demasiado en responder."
    elif "connection" in msg.lower():
        text = "⚠ Sin conexión al servidor. Verifica tu conexión a internet."
    else:
        text = f"⚠ Error inesperado: {msg[:200]}"

    return AgentResponse(answer=text, error=True)

# ─────────────────────────────────────────────────────────────
# Endpoints FastAPI
# ─────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """Health check del servidor."""
    gpu_alive = await _is_gpu_server_alive()
    return {
        "status":          "ok",
        "version":         "2.0.0",
        "gpu_server_alive": gpu_alive,
        "gpu_port":        GPU_LOCAL_PORT,
        "tools":           [t.name for t in TOOLS],
    }


@app.post("/run", response_model=AgentResponse)
async def run_task(req: AgentRequest):
    """Endpoint principal — ejecuta una tarea en el agente."""
    if not req.task.strip():
        raise HTTPException(status_code=400, detail="task no puede estar vacío")

    log.info(
        "Tarea recibida | fuente: %s | modelo: %s | gpu_local: %s",
        req.llm_base_url[:40] if req.llm_base_url else "auto",
        req.llm_model,
        _is_gpu_local(req),
    )

    if _is_gpu_local(req):
        return await _direct_chat_gpu(req)
    else:
        return await _run_agent(req)


@app.post("/chat", response_model=AgentResponse)
async def chat(req: AgentRequest):
    """Alias de /run para compatibilidad."""
    return await run_task(req)


@app.get("/tools")
async def list_tools():
    """Lista las tools disponibles."""
    return {
        "tools": [
            {"name": t.name, "description": t.description}
            for t in TOOLS
        ]
    }


@app.get("/gpu/status")
async def gpu_status():
    """Estado del servidor GPU MediaPipe."""
    alive = await _is_gpu_server_alive()
    if alive:
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(f"{GPU_LOCAL_BASE}/models")
                models = resp.json()
            return {"active": True, "port": GPU_LOCAL_PORT, "models": models}
        except Exception:
            pass
    return {"active": False, "port": GPU_LOCAL_PORT}


# ─────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────

@app.post("/run")
async def run_streaming(req: AgentRequest):
    """Endpoint SSE para el cliente Flutter — emite data: {...} líneas."""
    import json as _json
    if not req.task.strip():
        raise HTTPException(status_code=400, detail="task no puede estar vacio")

    async def generate():
        if _is_gpu_local(req):
            result = await _direct_chat_gpu(req)
        else:
            result = await _run_agent(req)

        # Emitir como SSE
        yield f"data: {_json.dumps({'type': 'answer', 'text': result.answer})}\n\n"
        if result.thoughts:
            for t in result.thoughts:
                yield f"data: {_json.dumps({'type': 'thought', 'text': t})}\n\n"
        yield f"data: {_json.dumps({'type': 'done'})}\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    import uvicorn
    log.info("Iniciando XTR Agent Server en puerto %d", AGENT_PORT)
    log.info("GPU MediaPipe esperado en puerto %d", GPU_LOCAL_PORT)
    uvicorn.run(
        "agent_server:app",
        host="127.0.0.1",
        port=AGENT_PORT,
        workers=1,
        log_level="warning",
    )
