<div align="center">

# 🤖 XTR Terminal

**Terminal Linux + agente de IA autónomo, 100% local por GPU, en el Samsung Galaxy Z Fold7.**

`v1.3` · Flutter + Kotlin · proot Debian arm64 · MediaPipe + LiteRT-LM (GPU Adreno)

</div>

---

## ¿Qué es?

Una app Android que junta una **terminal Debian completa** (vía proot, sin root) con un **agente de IA autónomo** ([smolagents](https://github.com/huggingface/smolagents)) que razona y ejecuta herramientas reales (bash, ficheros) usando un LLM que corre **enteramente en la GPU del teléfono** — sin nube, sin cuentas, funciona en modo avión.

## Capacidades

- **Agente ReAct**: piensa, usa herramientas (`run_bash`, `write_file`, `read_file`, `make_dir`, `list_files`), itera hasta resolver.
- **Inferencia local por GPU** (Adreno) con dos motores y **detección automática de formato**:
  - `.task` → **MediaPipe** (Gemma 3, Gemma 3n)
  - `.litertlm` → **LiteRT-LM** (Gemma 4, multimodal, function calling)
- **Servidor OpenAI-compatible** local (`127.0.0.1:8090`).
- **Fuentes remotas** opcionales: Groq, Gemini, Cerebras, OpenRouter, xAI, LAN/personalizado.
- Terminal con centro de control (`lc-menu`), hasta 5 sesiones, setup del agente en un toque.

## Modelos soportados

**Formato `.task` (MediaPipe)** — del más ligero al más potente:

| Modelo | Tamaño | Velocidad Fold7 |
|---|---|---|
| Gemma 3 270M int8 | ~0.3 GB | ⚡⚡⚡⚡⚡ |
| **Gemma 3 1B int4** ⭐ | ~0.9 GB | ~55 tok/s · TTFT 0.15s |
| Gemma 3n E2B int4 | ~3 GB | ⚡⚡⚡ multimodal |
| Gemma 3n E4B int4 | ~4.4 GB | ⚡⚡ multimodal |

**Formato `.litertlm` (LiteRT-LM)** — Gemma 4, lo último on-device:

| Modelo | Repo Hugging Face | Notas |
|---|---|---|
| **Gemma 4 E2B** 🚀 | [litert-community/gemma-4-E2B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm) | Texto+imagen+audio, cuantización mixta 2/4/8-bit, function calling |
| **Gemma 4 E4B** | [litert-community/gemma-4-E4B-it-litert-lm](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) | El más capaz, multimodal, reasoning |
| Gemma 3 1B | [litert-community/Gemma3-1B-IT](https://huggingface.co/litert-community/Gemma3-1B-IT) | Verificado en Adreno ✓ |

> 💡 Fold7 tiene 12 GB RAM. Usa `int4`/E2B para el día a día; E4B cabe pero va más lento. Requiere login + aceptar licencia Gemma en Hugging Face.

## Arquitectura
Flutter UI ──channels──► Kotlin (InferenceEngine router)
│ PTY                      ├─ MediaPipeEngine (.task)
▼                         └─ LiteRtEngine (.litertlm)
proot Debian arm64                    │ GPU Adreno
└─ agent_server.py (:8765)          ▼
└─ smolagents ──OpenAI──► 127.0.0.1:8090 (servidor GPU local)

## Uso rápido

1. Instala el APK (ver [Releases](../../releases)).
2. Terminal → menú → **Setup Agente IA** (instala Python + smolagents).
3. **Prueba GPU** → importa un modelo `.task` o `.litertlm` → Cargar → Iniciar servidor.
4. **Agente** → fuente **GPU Local 🔥** → arranca agent-server → escribe tu tarea.

## Stack

Flutter · Kotlin (`tasks-genai:0.10.27`, `litertlm-android:0.13.1`, `nanohttpd:2.3.1`) · proot Debian Bookworm arm64 · Python 3.11 + smolagents + FastAPI · Android SDK 35 / NDK 27 / Java 17 · Snapdragon 8 Elite / Adreno.

## Estado

**v1.3 — Migración a LiteRT-LM completa** ✅
`.task` (MediaPipe) y `.litertlm` (LiteRT-LM) funcionando con router automático. Ambos motores coexisten.

**Roadmap**: function calling nativo de LiteRT-LM → integración Home Assistant, MQTT y Leapmotor B10.

---

<div align="center">

*No afiliado a Google, Anthropic ni a los proveedores de modelos mencionados.*

</div>
