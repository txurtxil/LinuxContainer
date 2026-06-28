#!/bin/bash
# ============================================================
# XTR Terminal — Preparar rootfs Debian arm64 para bundlear
# en assets/ de la APK
#
# Requisitos en bc-250:
#   sudo apt install debootstrap qemu-user-static
#
# RESULTADO: android/app/src/main/assets/rootfs.tar.gz
#            (~150-200 MB comprimido, ~500 MB descomprimido)
#
# Ejecutar desde: ~/linux_container_build/
# ============================================================
set -e
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${CYAN}[ROOTFS]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOTFS_DIR="/tmp/xtr_rootfs_build"
ASSETS_DIR="$PROJECT_DIR/android/app/src/main/assets"
OUTPUT="$ASSETS_DIR/rootfs.tar.gz"

# ── Comprobar si ya existe un rootfs precompilado ────────────
# Si ya tienes un rootfs en el dispositivo o lo has exportado,
# puedes saltarte el debootstrap y usarlo directamente:
#
#   tar czf /tmp/rootfs_export.tar.gz -C /ruta/al/rootfs .
#   cp /tmp/rootfs_export.tar.gz $OUTPUT
#
# Descomenta las 3 líneas siguientes si ya tienes el tar:
# EXISTING_ROOTFS="/ruta/a/tu/rootfs.tar.gz"
# cp "$EXISTING_ROOTFS" "$OUTPUT"
# exit 0

# ── 1. Instalar dependencias ─────────────────────────────────
log "Instalando debootstrap y qemu-user-static..."
sudo apt install -y debootstrap qemu-user-static binfmt-support > /dev/null 2>&1
sudo update-binfmts --enable qemu-aarch64 > /dev/null 2>&1 || true
ok "Dependencias listas"

# ── 2. Crear rootfs mínimo Debian Bookworm arm64 ────────────
if [ -d "$ROOTFS_DIR" ]; then
  warn "Directorio $ROOTFS_DIR ya existe — eliminando..."
  sudo rm -rf "$ROOTFS_DIR"
fi

log "Ejecutando debootstrap (Debian Bookworm arm64)..."
log "Esto tarda 5-15 minutos dependiendo de tu conexión..."
sudo debootstrap \
  --arch=arm64 \
  --foreign \
  --include=apt,apt-utils,curl,wget,ca-certificates,gnupg,lsb-release \
  bookworm \
  "$ROOTFS_DIR" \
  http://deb.debian.org/debian/

# Segunda fase con qemu
sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/" 2>/dev/null || true
sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
ok "Debootstrap completado"

# ── 3. Configuración básica del rootfs ───────────────────────
log "Configurando rootfs..."

# sources.list
sudo tee "$ROOTFS_DIR/etc/apt/sources.list" > /dev/null << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

# hostname
echo "xtr-terminal" | sudo tee "$ROOTFS_DIR/etc/hostname" > /dev/null

# resolv.conf
sudo tee "$ROOTFS_DIR/etc/resolv.conf" > /dev/null << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Instalar paquetes base dentro del rootfs
sudo chroot "$ROOTFS_DIR" /bin/bash << 'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt update -q
apt install -y --no-install-recommends \
  python3 python3-pip python3-venv python3-dev \
  git curl wget ca-certificates \
  build-essential cmake \
  nano vim \
  procps htop \
  openssh-client \
  locales \
  2>/dev/null
# Configurar locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen > /dev/null 2>&1
# Limpiar cache apt para reducir tamaño
apt clean
rm -rf /var/lib/apt/lists/*
CHROOT
ok "Paquetes base instalados en rootfs"

# ── 4. Instalar smolagents en el rootfs ──────────────────────
log "Instalando smolagents en el rootfs..."
sudo chroot "$ROOTFS_DIR" /bin/bash << 'CHROOT'
cd /root
python3 -m venv agent-env
source agent-env/bin/activate
pip install --quiet --upgrade pip
pip install --quiet \
  smolagents \
  fastapi \
  uvicorn \
  httpx \
  openai \
  requests
deactivate
CHROOT
ok "smolagents instalado en /root/agent-env"

# ── 5. Copiar agent_server.py al rootfs ──────────────────────
AGENT_SERVER_SRC="$PROJECT_DIR/assets/agent_server.py"
if [ -f "$AGENT_SERVER_SRC" ]; then
  sudo cp "$AGENT_SERVER_SRC" "$ROOTFS_DIR/root/agent_server.py"
  ok "agent_server.py copiado al rootfs"
else
  warn "No se encontró $AGENT_SERVER_SRC — el setup inicial lo instalará"
fi

# ── 6. Copiar script de setup inicial ────────────────────────
sudo cp "$PROJECT_DIR/assets/xtr_setup.sh" "$ROOTFS_DIR/root/xtr_setup.sh" 2>/dev/null || true
sudo chmod +x "$ROOTFS_DIR/root/xtr_setup.sh" 2>/dev/null || true

# ── 7. Eliminar qemu-static (no necesario en ARM real) ───────
sudo rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# ── 8. Comprimir rootfs ──────────────────────────────────────
mkdir -p "$ASSETS_DIR"
log "Comprimiendo rootfs → $OUTPUT"
log "Esto puede tardar varios minutos..."
sudo tar czf "$OUTPUT" \
  --exclude="$ROOTFS_DIR/proc/*" \
  --exclude="$ROOTFS_DIR/sys/*" \
  --exclude="$ROOTFS_DIR/dev/*" \
  --exclude="$ROOTFS_DIR/run/*" \
  -C "$ROOTFS_DIR" .

SIZE=$(du -sh "$OUTPUT" | cut -f1)
ok "rootfs.tar.gz generado: $SIZE"

# ── 9. Limpiar ───────────────────────────────────────────────
sudo rm -rf "$ROOTFS_DIR"
ok "Limpieza completada"

echo ""
log "=== IMPORTANTE ==="
echo "rootfs bundleado en: $OUTPUT ($SIZE)"
echo ""
echo "Añade a android/app/build.gradle.kts (en android block):"
echo "  aaptOptions { noCompress += listOf(\"gz\") }"
echo ""
echo "El APK será ~$SIZE más grande."
echo "Si supera 200 MB considera usar Android App Bundle (AAB)."
