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

import re
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
        out = "\n".join(lines) if lines else "(vacío)"
        if len(out) > 2000:
            out = out[:2000] + f"\n... ({len(lines)} items en total, salida truncada)"
        return out
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

        # CodeAgent: basado en texto puro, funciona con cualquier servidor
        # de chat simple (MediaPipe/LiteRT-LM local no soportan tool-calling
        # estructurado). ToolCallingAgent: para backends remotos con function-
        # calling real (Groq, OpenAI-compatible serios).
        AgentClass = CodeAgent if _is_gpu_local(req) else ToolCallingAgent
        agent = AgentClass(
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
# Agente ReAct ligero (SOLO para GPU local / modelos pequeños)
# Prompt de sistema ~300 tokens vs ~2600 de CodeAgent.
# Formato de texto plano: PIENSO / ACCION / ARGS / FINAL
# ─────────────────────────────────────────────────────────────

_TOOL_MAP = {t.name: t for t in TOOLS}

_LIGHT_TOOLS_BRIEF = """Herramientas disponibles:
- run_bash: ejecuta un comando bash en Debian. ARGS = el comando.
- read_file: lee un fichero. ARGS = la ruta.
- write_file: escribe un fichero. ARGS = ruta|||contenido (ruta, tres barras, contenido).
- make_dir: crea un directorio. ARGS = la ruta.
- list_files: lista ficheros. ARGS = la ruta (vacio = /root)."""

_LIGHT_SYSTEM = (
    "Eres XTR, un agente que ejecuta tareas en un sistema Debian Linux local.\n\n"
    + _LIGHT_TOOLS_BRIEF +
    "\n\nResponde SIEMPRE en uno de estos dos formatos exactos:\n\n"
    "Si necesitas una herramienta:\n"
    "PIENSO: (una frase)\n"
    "ACCION: (nombre exacto de la herramienta)\n"
    "ARGS: (el argumento)\n\n"
    "Cuando tengas la respuesta final:\n"
    "PIENSO: (una frase)\n"
    "FINAL: (tu respuesta)\n\n"
    "Reglas: NUNCA digas FINAL ni afirmes haber creado, escrito, leido "
    "o ejecutado algo si no lo has hecho antes con una ACCION real. "
    "Usa solo las herramientas listadas con su nombre exacto. "
    "UNA SOLA accion por respuesta: escribe PIENSO, ACCION y ARGS, y PARA. "
    "No escribas mas texto ni otra ACCION despues de ARGS. "
    "Cada run_bash debe ser UN comando simple, sin comillas anidadas ni "
    "$(...) complejos. Si necesitas varios datos, ejecuta varios run_bash "
    "simples por separado. Para escribir un fichero, compon tu el texto "
    "final y pasalo a write_file directamente, no lo construyas con echo. "
    "Se conciso."
)


def _light_parse(text: str) -> dict:
    """Parsea la salida del modelo: final / action / unparseable.

    Si ACCION: aparece DESPUES de FINAL: en el mismo texto, el modelo
    afirmo haber terminado pero siguio queriendo actuar (alucinacion
    tipica: dice haber hecho algo sin haberlo ejecutado). En ese caso
    se prioriza la ACCION real sobre el FINAL prematuro, para que el
    bucle ejecute la tool de verdad y el resultado real (p.ej. un
    error de fichero no encontrado) fuerce al modelo a autocorregirse.
    """
    thought = ""
    m_think = re.search(r"PIENSO:\s*(.+?)(?=\n(?:ACCION|ACCI\u00d3N|FINAL):|$)",
                        text, re.IGNORECASE | re.DOTALL)
    if m_think:
        thought = m_think.group(1).strip()

    m_final = re.search(r"FINAL:", text, re.IGNORECASE)
    m_tool  = re.search(r"ACCI[O\u00d3]N:\s*(\w+)", text, re.IGNORECASE)

    if m_tool and (not m_final or m_tool.start() > m_final.start()):
        tool = m_tool.group(1).strip()
        m_args = re.search(r"ARGS:\s*(.*?)(?=\n(?:PIENSO|ACCI[O\u00d3]N|FINAL):|\Z)", text, re.IGNORECASE | re.DOTALL)
        args = m_args.group(1).strip() if m_args else ""
        return {"kind": "action", "thought": thought, "tool": tool, "args": args}

    if m_final:
        m_ans = re.search(r"FINAL:\s*(.+?)(?=\n(?:PIENSO|ACCI[O\u00d3]N):|\Z)", text, re.IGNORECASE | re.DOTALL)
        answer = m_ans.group(1).strip() if m_ans else text[m_final.end():].strip()
        return {"kind": "final", "thought": thought, "answer": answer}

    return {"kind": "unparseable", "raw": text.strip()}


def _light_exec_tool(tool_name: str, args: str) -> str:
    """Ejecuta una tool con el argumento parseado."""
    fn = _TOOL_MAP.get(tool_name)
    if fn is None:
        return f"Error: herramienta '{tool_name}' no existe. Disponibles: {', '.join(_TOOL_MAP.keys())}"
    try:
        if tool_name == "write_file":
            if "|||" in args:
                path, content = args.split("|||", 1)
                return fn(path.strip(), content)
            return "Error: write_file necesita 'ruta|||contenido'"
        elif tool_name == "list_files":
            return fn(args.strip() or "/root")
        else:
            return fn(args.strip())
    except Exception as e:
        return f"Error ejecutando {tool_name}: {e}"


async def _light_call_model(req: AgentRequest, messages: list) -> str:
    """Una llamada al servidor GPU MediaPipe. Devuelve el texto generado."""
    payload = {
        "model": "gemma",
        "messages": messages,
        "max_tokens": MAX_TOKENS,
        "temperature": 0.4,
        "stream": False,
    }
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{GPU_LOCAL_BASE}/chat/completions",
            json=payload,
            headers={"Content-Type": "application/json"},
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]


async def _run_light_agent(req: AgentRequest):
    """
    Bucle ReAct ligero. Es un GENERADOR ASINCRONO que emite eventos dict
    para el streaming SSE: {'type':'step',...} y {'type':'final',...}.
    """
    import json as _json

    if not await _is_gpu_server_alive():
        yield {"type": "final", "answer":
               "\u26a0 El servidor GPU no esta activo. Carga un modelo en 'Prueba GPU'."}
        return

    messages = [
        {"role": "system", "content": _LIGHT_SYSTEM},
        {"role": "user", "content": req.task},
    ]

    last_result = None
    last_action = None
    tools_used = 0
    warned_no_tools = False
    last_result = None
    last_action = None
    tools_used = 0
    tools_used_names = set()
    warned_no_tools = False
    expected_tools = {t.name for t in TOOLS if t.name in req.task}
    for step in range(MAX_STEPS):
        try:
            raw = await _light_call_model(req, messages)
            for _tok in ("<end_of_turn>", "<eos>", "<|im_end|>", "</s>"):
                raw = raw.replace(_tok, "")
            raw = raw.strip()
            for _tok in ("<end_of_turn>", "<eos>", "<|im_end|>", "</s>"):
                raw = raw.replace(_tok, "")
            raw = raw.strip()
        except httpx.HTTPStatusError as e:
            # ERROR REAL al chat (no generico)
            yield {"type": "step", "thought":
                   f"\u26a0 Error del modelo (HTTP {e.response.status_code}): {e.response.text[:300]}"}
            yield {"type": "final", "answer":
                   f"El modelo devolvio un error: {e.response.text[:200]}"}
            return
        except Exception as e:
            yield {"type": "step", "thought": f"\u26a0 Error: {str(e)[:300]}"}
            yield {"type": "final", "answer": f"Error al contactar el modelo: {str(e)[:200]}"}
            return

        parsed = _light_parse(raw)

        if parsed["kind"] == "final":
            if tools_used == 0 and not warned_no_tools:
                warned_no_tools = True
                messages.append({"role": "assistant", "content": raw})
                messages.append({"role": "user", "content":
                    "No has ejecutado ninguna ACCION todavia en esta "
                    "conversacion. Si tu tarea requiere crear, leer, "
                    "escribir o ejecutar algo, hazlo ahora con ACCION "
                    "real (no des nada por hecho). Si de verdad no "
                    "necesitas ninguna herramienta, repite tu FINAL."
                })
                yield {"type": "step", "thought":
                       "\u26a0 Posible respuesta sin ejecutar herramientas. Pidiendo confirmacion..."}
                continue
            if parsed.get("thought"):
                yield {"type": "step", "thought": parsed["thought"]}
            yield {"type": "final", "answer": parsed["answer"]}
            return

        if parsed["kind"] == "unparseable":
            # El modelo no siguio el formato: devolvemos su texto como respuesta.
            yield {"type": "final", "answer": parsed["raw"]}
            return

        # Es una accion: ejecutar la tool
        thought = parsed.get("thought", "")
        tool = parsed["tool"]
        args = parsed["args"]
        if thought:
            yield {"type": "step", "thought": thought}
        yield {"type": "step", "thought": f"\U0001f527 {tool}({args[:120]})"}

        if (tool, args) == last_action:
            yield {"type": "step", "thought":
                   "\u26a0 Repitiendo la misma accion que ya fallo. Cambiando de enfoque..."}
            messages.append({"role": "assistant", "content": raw})
            messages.append({"role": "user", "content":
                f"Ya intentaste exactamente esto y fallo: {tool}({args[:200]}). "
                "NO lo repitas igual. Usa UN comando bash simple (sin comillas "
                "anidadas ni $(...) complejos) o compon el texto tu mismo y "
                "usa write_file directamente."})
            continue

        result = _light_exec_tool(tool, args)
        last_result = result
        last_action = (tool, args)
        tools_used += 1
        yield {"type": "step", "thought": f"\u2192 {result[:400]}"}

        messages.append({"role": "assistant", "content": raw})
        messages.append({"role": "user", "content": f"Resultado de {tool}:\n{result}\n\nContinua."})

    # Agotados los pasos
    yield {"type": "final", "answer": (
        f"Se alcanzo el limite de {MAX_STEPS} pasos. Ultimo resultado obtenido:\n{last_result}"
        if last_result else
        f"No pude completar la tarea en {MAX_STEPS} pasos. Prueba a reformularla o dividirla."
    )}


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
            # Agente ligero: prompt corto, sin CodeAgent, evita
            # desbordar el contexto de modelos pequeños locales.
            async for event in _run_light_agent(req):
                yield f"data: {_json.dumps(event)}\n\n"
            return

        # Fuentes remotas: smolagents con ToolCallingAgent (soportan
        # function-calling real de verdad, p.ej. Groq).
        result = await _run_agent(req)
        if result.thoughts:
            for t in result.thoughts:
                yield f"data: {_json.dumps({'type': 'step', 'thought': t})}\n\n"
        yield f"data: {_json.dumps({'type': 'final', 'answer': result.answer})}\n\n"

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
