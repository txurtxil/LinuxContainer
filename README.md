# XTR Terminal

Terminal Android local con agente de IA autónomo — Debian Bookworm (arm64) sin root vía `proot`, con inferencia multimodal 100% on-device.

**Repositorio:** https://github.com/txurtxil/LinuxContainer
**Releases:** https://github.com/txurtxil/LinuxContainer/releases
**Última versión:** [v1.8.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.8.0)

## Qué es esto

XTR Terminal convierte un Samsung Galaxy Z Fold7 (Snapdragon 8 Elite) en una estación Linux de bolsillo: terminal completo con Debian real, y un agente de IA que ejecuta comandos, genera imágenes, descubre la red doméstica y actúa de forma autónoma a lo largo del tiempo — todo local, sin nube, sin root.

## Hardware objetivo

- Samsung Galaxy Z Fold7 (Snapdragon 8 Elite, GPU Adreno)
- Debería funcionar en cualquier Android arm64 razonablemente potente, sin garantías fuera del dispositivo de desarrollo

## Arquitectura
Flutter (UI, Dart)
│
├─ Terminal (xterm) ── proot ── Debian Bookworm arm64
│                                   │
│                                   ├─ agent_server.py (FastAPI, puerto 8765)
│                                   │     bucle ReAct ligero + tools
│                                   │
│                                   └─ scripts/*.sh, *.py (generación de imágenes, red, scheduler)
│
└─ MethodChannel ── InferenceEngine (Kotlin)
├─ LiteRtEngine (Gemma 4, .litertlm, multimodal)
└─ MediaPipeEngine (Gemma 3, .task, legacy)
│
└─ MediaPipeServer.kt (NanoHTTPD, puerto 8090, API estilo OpenAI)

El agente (`agent_server.py`) habla con el modelo local vía HTTP en `127.0.0.1:8090/v1`, con el mismo protocolo que usarías contra la API de OpenAI — así que también acepta fuentes remotas (Groq, Gemini, OpenRouter...) sin cambiar de código.

## Funcionalidades principales

**Terminal**
- Multi-sesión (hasta 5 pestañas), teclado configurable con atajos visibles/ocultos
- Recupera el foco del teclado al volver de segundo plano

**Agente de IA**
- Bucle ReAct ligero optimizado para modelos pequeños on-device (Gemma 4 E2B)
- Herramientas: `run_bash`, `write_file`, `read_file`, `make_dir`, `list_files`, `http_request`, `ssh_exec`
- Guardarraíles: bloqueo de comandos destructivos, rutas protegidas del sistema, detección de repetición de acciones, verificación de que las tools mencionadas en la tarea se usan de verdad antes de aceptar un `FINAL`

**Multimodal**
- Cámara/galería → chat → Gemma 4 → descripción real de la imagen
- El agente también puede generar imágenes y mostrártelas en el propio chat (botón de ojo o detección automática)
- Portapapeles: pegar en el campo de tarea, copiar cualquier respuesta

**Generación de imágenes** (`assets/scripts/`)
- `gen_topologia.sh` — diagramas de red (Graphviz)
- `gen_flujo.sh` — diagramas de flujo secuenciales (Graphviz)
- `gen_grafica.py` — gráficas de barras (matplotlib)
- `gen_qr.sh` — códigos QR (qrencode)
- `gen_scan_red.sh` — escaneo de puertos comunes de IPs conocidas (`/dev/tcp`, sin nmap)
- `gen_discover_red.sh` — descubrimiento real de dispositivos en la subred vía ping ICMP

**Automatización**
- `run_mission.sh` — motor de misiones: dale una orden, el agente la completa a lo largo de varios ciclos programados por `cron`, sin intervención
- `run_scheduled_task.sh` — comprobaciones periódicas (ej. salud de un servidor remoto por SSH)

**Gestión de servicios**
- Tarjetas de un toque para GPU Local, agent-server y cron — arrancar/parar/ver logs sin terminal

**SSH**
- Gestor de conexiones estilo Termius, plantillas de tareas reutilizables, ejecución por lotes

**Plantillas de prompts**
- Botón dedicado con prompts predefinidos y editables para las capacidades de imagen/red más usadas

## Estructura del código

lib/src/
├── agent/
│   ├── agent_chat.dart          — cliente HTTP + estado del chat (AgentController)
│   ├── agent_dashboard.dart     — UI del chat, tarjetas de servicio, botones
│   ├── agent_services.dart      — arranque/parada de procesos (llama, agent-server, cron)
│   ├── mediapipe_test_screen.dart — pantalla de pruebas del motor GPU
│   ├── prompt_templates.dart    — plantillas de prompts guardadas
│   └── ssh_connections.dart     — gestor de conexiones SSH
├── container/
│   ├── container_bootstrap.dart — extracción inicial del rootfs
│   ├── container_manager.dart   — gestión de proot en tiempo de ejecución
│   ├── native_paths.dart        — rutas nativas vía MethodChannel
│   └── rootfs_config.dart       — .bashrc y configuración del rootfs
└── terminal/
├── keybar_config.dart       — configuración del teclado
├── keybar_settings_screen.dart
├── terminal_keybar.dart
├── terminal_session.dart
└── terminal_view.dart       — vista principal de la terminal
android/app/src/main/kotlin/com/example/linux_container/
├── MainActivity.kt              — MethodChannels, selector de imágenes
├── InferenceEngine.kt           — router entre LiteRT-LM y MediaPipe
├── LiteRtEngine.kt              — motor Gemma 4 (.litertlm), multimodal
├── MediaPipeEngine.kt           — motor Gemma 3 (.task), legacy
├── MediaPipeServer.kt           — servidor HTTP estilo OpenAI (NanoHTTPD)
└── AgentForegroundService.kt    — foreground service del agente
assets/
├── agent_server.py              — servidor del agente (FastAPI + smolagents)
└── scripts/
├── lc-menu.sh                — menú de configuración, Setup Agente IA
├── gen_topologia.sh / gen_flujo.sh / gen_grafica.py / gen_qr.sh
├── gen_scan_red.sh / gen_discover_red.sh
└── run_mission.sh / run_scheduled_task.sh
## Historial de versiones

| Versión | Cambios principales |
|---|---|
| [v1.8.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.8.0) | Descubrimiento real de red (ping ICMP), séptima plantilla |
| [v1.7.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.7.0) | Botón de plantillas de prompts, escaneo de red por puertos |
| [v1.6.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.6.0) | Detección automática de imágenes en el chat, gráficas, QR, flujos |
| [v1.5.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.5.0) | Motor de misiones autónomo, tarjeta de servicio para cron |
| [v1.4.0](https://github.com/txurtxil/LinuxContainer/releases/tag/v1.4.0) | Chat multimodal de extremo a extremo (cámara → agente → Gemma 4) |
| v1.3.x | Endurecimiento del agente, `ssh_exec`, gestor de conexiones SSH |
| v1.2 y anteriores | Migración a LiteRT-LM, base del proyecto |

## Limitaciones conocidas

- **Sin root real**: `proot` no da privilegios de sistema. `/proc/net/route` y `/proc/net/arp` están bloqueados por Android — `nmap` no puede calcular rutas ni hacer descubrimiento ARP. El descubrimiento de red usa `ping` (ICMP), que Android sí permite sin privilegios especiales.
- **Sin identificación de fabricante**: sin acceso a ARP, no hay forma de leer direcciones MAC ni identificar fabricantes (a diferencia de apps como Fing).
- **Modelo pequeño, composición limitada**: Gemma 4 E2B a veces falla al componer sintaxis exacta (el separador `|||` de `write_file`, por ejemplo). Mitigado con parsers tolerantes, pero las tareas con plantillas explícitas son más fiables que pedirle que componga formatos complejos desde cero.
- **Servicios no persistentes**: `agent-server`, el servidor GPU y `cron` no sobreviven al cierre completo de la app — hay que relanzarlos (un toque cada uno, desde sus tarjetas de servicio).
- **Rootfs se pierde en reinstalación completa**: `Setup Agente IA` (en `lc-menu`) descarga automáticamente `agent_server.py` y todos los scripts desde este repositorio, y instala las dependencias necesarias (`graphviz`, `qrencode`, `python3-matplotlib`, `openssh-client`, `cron`).

## Primeros pasos

Desde la terminal de la app: `lc-menu` → **Setup Agente IA**. Instala Python, dependencias, y descarga todos los scripts de este repositorio automáticamente.
