<div align="center">

# 🤖 XTR Terminal

### Tu agente de IA autónomo, 100% local y privado, en el bolsillo

**Una terminal Linux completa + un agente de IA con inferencia on-device por GPU, corriendo enteramente en tu Samsung Galaxy Z Fold7 — sin nube, sin cuentas, sin que un solo token salga del dispositivo.**

`v1.2` · Flutter + Kotlin · proot Debian arm64 · MediaPipe GPU (Adreno)

</div>

---

## 📖 ¿Qué es XTR Terminal?

XTR Terminal es una aplicación Android que combina **dos mundos** en una sola app:

1. **Una terminal Linux real** — un entorno Debian Bookworm (arm64) completo corriendo vía `proot` **sin root**, con su gestor de paquetes `apt`, Python, editores, SSH, túneles y un centro de control interactivo.

2. **Un agente de IA autónomo** — basado en [smolagents](https://github.com/huggingface/smolagents), capaz de razonar y **ejecutar herramientas reales** dentro de la terminal: leer y escribir ficheros, ejecutar comandos bash, crear directorios… todo orquestado por un LLM que puede correr **enteramente en la GPU del teléfono**.

La pieza estrella es la **inferencia local por GPU**: usando **MediaPipe LLM Inference API** sobre la GPU **Adreno** del Snapdragon 8 Elite, XTR ejecuta modelos Gemma directamente en el silicio del Fold7 a **~55 tokens/segundo** con un *time-to-first-token* de apenas **0.15 segundos** — sin enviar absolutamente nada a internet.

---

## ✨ Capacidades

### 🧠 Agente de IA autónomo
- **Bucle ReAct** (Reasoning + Acting) con smolagents: el agente piensa, decide qué herramienta usar, la ejecuta y observa el resultado, iterando hasta resolver la tarea.
- **Herramientas integradas**: `run_bash`, `write_file`, `read_file`, `make_dir`, `list_files`.
- **Chat persistente** con historial y recuperación de errores.
- **Streaming en tiempo real** (SSE): ves el razonamiento y la respuesta token a token.

### 🔥 Inferencia 100% local por GPU
- **MediaPipe** sobre **GPU Adreno** — privacidad absoluta, funciona en modo avión.
- Servidor **OpenAI-compatible** local en `127.0.0.1:8090` (`/v1/chat/completions`, `/v1/models`, `/health`).
- Carga, prueba y descarga modelos `.task` desde la propia app.
- Métricas en vivo: tokens/s, TTFT, conteo de tokens.

### 🌐 Múltiples fuentes de inferencia
Además de la GPU local, puedes conectar el agente a proveedores remotos (la *clave API* se guarda solo en la app, nunca en el rootfs):

| Fuente | Notas |
|---|---|
| **GPU Local** 🔥 | MediaPipe/Adreno, 100% on-device |
| **Groq** | `llama-3.1-8b-instant` — gratis, ideal para *tool-calling* |
| **Google Gemini** | `gemini-3.5-flash` (gratis) y `gemini-2.5-flash` |
| **Cerebras** | Inferencia ultrarrápida, gratis |
| **OpenRouter** | Acceso a multitud de modelos |
| **xAI Grok** | Modelos de xAI |
| **LAN / Personalizado** | Cualquier endpoint OpenAI-compatible en tu red |

### 🐧 Terminal Linux completa
- **Debian Bookworm arm64** vía proot (sin root).
- **Centro de control** interactivo (`lc-menu`): setup del agente con un toque, paquetes extra (red, editores, SSH, ngrok, nginx), gestión del sistema (DNS, zona horaria, actualizaciones).
- Hasta **5 sesiones** simultáneas, teclado configurable, emulación `xterm` completa.
- Setup del agente IA **automatizado** en una sola opción del menú.

---

## 📦 Modelos `.task` soportados

XTR ejecuta modelos en formato **`.task`** (MediaPipe Task Bundle) sobre la GPU Adreno. Puedes importarlos desde la pantalla **"Prueba GPU"** de la app.

> 💡 **Regla práctica de RAM**: el Z Fold7 dispone de **12 GB de RAM**. Como referencia, deja **~3-4 GB libres** para el sistema y la propia app. Los modelos `int4` son los más eficientes en memoria y velocidad para GPU.

### De más ligero a más potente

| Modelo | Tamaño aprox. | RAM en uso | Velocidad esperada en Fold7 | Mejor para |
|---|---|---|---|---|
| **Qwen 2.5 0.5B** (int4/int8) | ~0.5 GB | ~1 GB | ⚡⚡⚡⚡⚡ Muy rápido | Respuestas rápidas, recursos mínimos, pruebas |
| **Gemma 3 270M** (int8) | ~0.3 GB | ~0.8 GB | ⚡⚡⚡⚡⚡ Muy rápido | El más ligero, ideal para tareas simples |
| **Gemma 3 1B** (int4) ⭐ | ~0.5–0.9 GB | ~1.2 GB | ⚡⚡⚡⚡ ~55 tok/s · TTFT 0.15s | **Recomendado** — el mejor equilibrio. Es el que XTR trae por defecto |
| **Qwen 3 1.7B** (int4) | ~1.0 GB | ~1.5 GB | ⚡⚡⚡⚡ Rápido | Buen razonamiento, sigue siendo ágil |
| **Phi-4 mini** (int4) | ~1.5 GB | ~2 GB | ⚡⚡⚡ Moderado | Q&A, chat y código |
| **Gemma 3n E2B** (int4) | ~1.5 GB | ~2.5 GB | ⚡⚡⚡ Moderado | Arquitectura Matformer, conversación |
| **Gemma 3 4B** (int4) | ~2.5 GB | ~3.5 GB | ⚡⚡ Más lento | Mayor calidad de razonamiento |
| **Gemma 3n E4B** (int4) | ~3.7 GB | ~4–5 GB | ⚡⚡ Más lento | Multimodal (texto/visión), el más capaz |
| **Gemma 4 E2B** (int4) 🚀 | ~2.6 GB | ~3.5 GB | ⚡⚡ Moderado | Multimodal (texto+imagen+audio), última gen |

> ⭐ **Recomendación general**: empieza con **Gemma 3 1B int4**. Es el punto dulce entre velocidad, calidad y consumo para el día a día en el Fold7.
>
> 🚀 **El más potente que el Fold7 puede mover con soltura**: **Gemma 3 4B int4** o **Gemma 3n E4B int4**. Caben en los 12 GB pero con la GPU trabajando al límite — espera menos tokens/s y mayor TTFT. Para texto puro, **Gemma 4 E2B** ofrece lo último en calidad on-device.

### 🔗 Dónde descargar modelos `.task`

Los modelos compatibles están en la **[LiteRT Community en Hugging Face](https://huggingface.co/litert-community)**:

- **[Gemma 3 1B IT](https://huggingface.co/litert-community/Gemma3-1B-IT)** — el recomendado (busca la variante `int4`).
- **[Colección Android Models](https://huggingface.co/collections/litert-community/android-models)** — todos los modelos optimizados para Android.
- **Familia Qwen, Phi, Gemma 3n** — disponibles en la misma comunidad.

> ⚠️ Para usar modelos Gemma debes aceptar la licencia de Google en Hugging Face (es inmediato). Algunos modelos requieren conversión a `.task` mediante el [bundler de MediaPipe](https://ai.google.dev/gemma/docs/conversions/hf-to-mediapipe-task); los de la LiteRT Community ya vienen listos.

---

## 🏗️ Arquitectura

**Flujo de una consulta al agente con GPU local:**
1. Escribes una tarea en el chat → Flutter la envía a `agent_server.py` (`:8765`).
2. smolagents razona y, si necesita inferencia, llama al servidor MediaPipe (`:8090`).
3. MediaPipe ejecuta el modelo `.task` en la **GPU Adreno** y devuelve la respuesta.
4. El agente puede ejecutar herramientas (bash, ficheros) dentro de la terminal Debian.
5. La respuesta vuelve por streaming SSE al chat.

---

## 🛠️ Stack técnico

| Capa | Tecnología |
|---|---|
| **App** | Flutter (stable), Dart |
| **Nativo** | Kotlin, `tasks-genai:0.10.27`, `nanohttpd:2.3.1` |
| **Contenedor** | proot, Debian Bookworm arm64 (sin root) |
| **Agente** | Python 3.11, smolagents, FastAPI, uvicorn |
| **Inferencia GPU** | MediaPipe LLM Inference API · GPU Adreno |
| **Build** | Android SDK 35, NDK 27, Java 17, Gradle (Kotlin DSL) |
| **Target** | Samsung Galaxy Z Fold7 — Snapdragon 8 Elite / Adreno |

---

## 🚀 Uso rápido

1. **Instala** el APK (ver [Releases](../../releases)).
2. Al abrir, la app extrae el rootfs Debian (solo la primera vez).
3. En la terminal, abre el menú y pulsa **"Setup Agente IA"** → instala Python + smolagents automáticamente.
4. Ve a **"Prueba GPU"**, importa un modelo `.task` (ej. Gemma 3 1B int4), pulsa **Cargar modelo** y luego **Iniciar servidor**.
5. Entra al **Agente**, selecciona la fuente **"GPU Local 🔥"** y arranca el **agent-server**.
6. ¡Escribe tu primera tarea! El agente responde 100% on-device.

---

## 🔒 Privacidad

Con la fuente **GPU Local**, XTR Terminal **no envía absolutamente nada a internet**. Toda la inferencia ocurre en la GPU del dispositivo. Funciona perfectamente en **modo avión**. Las claves API de proveedores remotos (si decides usarlos) se guardan **solo en la app**, como variables de entorno efímeras, nunca escritas al rootfs.

---

## 📋 Estado del proyecto

**v1.2 — Primera versión base 100% funcional** ✅

- ✅ Terminal Debian arm64 vía proot operativa
- ✅ Inferencia GPU MediaPipe (~55 tok/s, TTFT 0.15s)
- ✅ Servidor OpenAI-compatible local
- ✅ Agente smolagents con herramientas reales
- ✅ Chat con streaming SSE
- ✅ Múltiples fuentes de inferencia (local + remotas)
- ✅ Setup del agente automatizado

---

<div align="center">

**Hecho con ❤️ para correr IA de verdad, en local, en el bolsillo.**

*XTR Terminal no está afiliado a Google, Anthropic, ni a los proveedores de modelos mencionados.*

</div>
