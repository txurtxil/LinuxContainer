<div align="center">

# 🤖 XTR Terminal

**Terminal Linux + agente de IA autónomo, 100% local por GPU, en el Samsung Galaxy Z Fold7.**

`v1.3.2` · Flutter + Kotlin · proot Debian arm64 · MediaPipe + LiteRT-LM (GPU Adreno)

[

![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)

](LICENSE)

</div>

---

## ¿Qué es?

Una app Android que junta una **terminal Debian completa** (vía proot, sin root) con un **agente de IA autónomo** que razona, ejecuta comandos reales y llama a APIs/servidores externos — usando un LLM que corre **enteramente en la GPU del teléfono**. Sin nube, sin cuentas, funciona en modo avión.

## Capacidades

**Inferencia local por GPU** con dos motores y detección automática de formato:
- `.task` → **MediaPipe** (Gemma 3, Gemma 3n)
- `.litertlm` → **LiteRT-LM** (Gemma 4, multimodal)

**Agente ReAct ligero** (diseñado para modelos pequeños locales, prompt de sistema ~300 tokens):
- `run_bash` — ejecuta comandos reales en el Debian
- `read_file` / `write_file` / `make_dir` / `list_files` — gestión de ficheros
- `http_request` — llama a cualquier API HTTP (GET/POST/PUT/DELETE/PATCH), resume JSON automáticamente para no saturar el contexto
- `ssh_exec` — ejecuta comandos en otros servidores por SSH, autenticación por clave (genera su propio par de claves la primera vez, sin contraseñas)

**Guardarraíles de seguridad**: bloquea comandos destructivos (`rm -rf /`, `mkfs`, `dd` sobre disco, `docker system prune -a --volumes`, `shutdown`/`reboot`) y escritura en rutas protegidas del sistema (`/etc`, `/boot`, `/bin`...).

**Fuentes remotas** opcionales: Groq, Gemini, Cerebras, OpenRouter, xAI, LAN/personalizado — usan `ToolCallingAgent` con function-calling real.

## Modelos soportados

| Formato | Motor | Modelos |
|---|---|---|
| `.task` | MediaPipe | Gemma 3 1B/270M, Gemma 3n E2B/E4B |
| `.litertlm` | LiteRT-LM | Gemma 3 1B, **Gemma 4 E2B/E4B** |

Repos: [litert-community](https://huggingface.co/litert-community) en Hugging Face (requiere aceptar licencia Gemma).

## Arquitectura del agente

Chat (Flutter) ──SSE──► agent_server.py (:8765)
│
¿fuente = GPU Local?
┌─────────┴─────────┐
Sí                   No
│                    │
Agente ReAct ligero      smolagents
(texto plano, sin        ToolCallingAgent
function-calling)       (function-calling
│             real vía API)
▼
127.0.0.1:8090 (GPU Adreno)


El agente ligero existe porque los servidores de inferencia locales (MediaPipe/LiteRT-LM) no implementan function-calling estructurado — el protocolo es texto plano (`PIENSO`/`ACCION`/`ARGS`/`FINAL`) parseado por regex, con guardarraíles contra bucles y alucinaciones de "tarea completada" sin ejecutar nada.

## Uso rápido

1. Instala el APK ([Releases](../../releases)).
2. Terminal → menú → **Setup Agente IA**.
3. **Prueba GPU** → importa un modelo `.task`/`.litertlm` → Cargar → Iniciar servidor.
4. **Agente** → **GPU Local 🔥** → arranca agent-server → escribe tu tarea.
5. Para SSH: la primera vez que uses `ssh_exec`, el agente te dará su clave pública — añádela al `authorized_keys` del servidor destino.

## Stack

Flutter · Kotlin (`tasks-genai:0.10.27`, `litertlm-android:0.13.1`) · proot Debian Bookworm arm64 · Python 3.11 + smolagents + FastAPI + httpx · Android SDK 35 / NDK 27 / Java 17 · Snapdragon 8 Elite / Adreno.

## Estado

**v1.3.2 — Agente con automatización real, verificado end-to-end** ✅

**Roadmap**: integración Home Assistant (ya viable con `http_request`), scheduler para tareas autónomas sin intervención, tool MQTT, function-calling nativo de LiteRT-LM (v1.5).

---

<div align="center">

*No afiliado a Google, Anthropic ni a los proveedores de modelos mencionados.*

</div>
