# LinuxContainer — Dashboard IA v8.0

> Contenedor Debian completo en Android + Agente IA con MediaPipe GPU local o API remota.

## Caracteristicas

- **Contenedor Debian** ejecutandose nativamente en Android (via `proot`/`chroot`)
- **Agente IA** con servidor OpenAI-compatible embebido en el contenedor
- **MediaPipe GPU local** — carga modelos `.task` / `.litertlm` y sirve en `localhost:8090`
- **API remota** — compatible con OpenAI, Ollama, o cualquier endpoint `/v1/chat/completions`
- **Chat con historial** — guarda y carga conversaciones
- **Terminal integrada** — acceso directo al shell del contenedor
- **Foreground service** — mantiene el contenedor vivo en segundo plano
- **Auto-install de dependencias** — `pip`, `httpx`, `openai` se instalan solos si faltan (v8.0)
- **Fallback stdlib** — `agent_server.py` usa solo `urllib` (sin dependencias externas)

## Requisitos

- Android 10+ (API 29+)
- Dispositivo ARM64 (arm64-v8a) — optimizado para Galaxy Z Fold 7
- ~500 MB libres para el rootfs Debian
- Python 3 en el contenedor (se auto-instala si falta)

## Instalacion rapida

```bash
# 1. Clonar
git clone https://github.com/txurtxil/LinuxContainer.git
cd LinuxContainer

# 2. Ejecutar el parche v8
bash patch_agent_v8.sh

# 3. Instalar en el dispositivo
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

## Uso del Agente

1. Abre la app y espera a que el contenedor Debian se inicialice.
2. Ve a **Ajustes** (icono de tuerca) y elige tu fuente de inferencia:
   - **GPU Local**: carga un modelo MediaPipe (`.task`) y arranca el servidor `:8090`
   - **Personalizado**: introduce URL, modelo y API key de un endpoint remoto
3. Pulsa el **boton verde de play** para arrancar el agent-server.
4. Escribe tareas en lenguaje natural. El agente puede:
   - Crear y ejecutar scripts en el contenedor
   - Leer archivos y mostrar resultados
   - Usar herramientas definidas en `agent_server.py`

## Estructura del proyecto

```
lib/
  src/
    agent/
      agent_services.dart      # Logica de arranque, MediaPipe, config
      agent_dashboard.dart     # UI del chat y ajustes
      agent_chat.dart          # Controller del chat
assets/
  agent_server.py            # Servidor Python embebido (solo stdlib)
```

## Troubleshooting

| Problema | Solucion |
|----------|----------|
| `ModuleNotFoundError: No module named 'httpx'` | **v8.0** arreglado: `agent_server.py` usa `urllib` (stdlib). El script de arranque tambien instala `pip` + `httpx` automaticamente si faltan. |
| `exec: : not found` | Python 3 no estaba en el rootfs. **v8.0** lo busca en multiples rutas y lo instala via `apt-get`. |
| `No existe /root/agent_server.py` | El script se copia automaticamente desde `assets/` al arrancar el agente. |
| El agente no responde | Revisa los logs (icono de documento). Asegurate de que el contenedor este listo. |
| MediaPipe no carga | Verifica que el modelo sea `.task` o `.litertlm`. Prueba con CPU si GPU falla. |

## Compilacion manual

```bash
flutter pub get
flutter analyze
flutter build apk --release --split-per-abi
```

## Release

Las APKs firmadas se generan automaticamente con `patch_agent_v8.sh` y se suben a GitHub Releases via `gh CLI`.

---

**Autor:** txurtxil  
**Licencia:** MIT
