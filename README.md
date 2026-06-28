# XTR Terminal

App Android con agente IA autónomo **100% local y privado**.

- **Plataforma:** Samsung Z Fold7 (Snapdragon 8 Elite)
- **Sistema:** Debian Bookworm arm64 vía proot (sin root)
- **GPU:** MediaPipe LLM API — Adreno GPU (55+ tok/s)
- **Package:** `com.example.linux_container`

## Setup desde 0 en bc-250

```bash
# 1. Bootstrap (instala SDK, Flutter, Java)
bash scripts/00_bootstrap_bc250.sh
source ~/.bashrc

# 2. Preparar rootfs Debian (~15 min, una sola vez)
bash scripts/01_prepare_rootfs.sh

# 3. Build APK
cd ~/linux_container_build
./build_and_deploy.sh
```

## Primera ejecución en el dispositivo

1. Instalar APK
2. La app extrae Debian automáticamente (~500 MB, 1-3 min)
3. Menú ☰ → **Setup Inicial** (instala smolagents)
4. Modelos GPU: pantalla "Prueba GPU" → Importar .task
