#!/bin/bash
# ============================================================
# XTR Terminal — Setup Inicial (se ejecuta dentro de proot)
# Ruta dentro del rootfs: /root/xtr_setup.sh
# ============================================================
CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'
YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYAN}◆${NC} $1"; }
ok()      { echo -e "${GREEN}✓${NC} $1"; }
warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
err()     { echo -e "${RED}✗${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}═══ $1 ═══${NC}"; }

clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
 ╔═══════════════════════════════════════╗
 ║     XTR Terminal — Setup Inicial      ║
 ║   Configuración del entorno proot     ║
 ╚═══════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Detección de entorno ─────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
  warn "No eres root — puede que algunos pasos fallen"
fi

if ! command -v apt > /dev/null 2>&1; then
  err "apt no encontrado — ¿estás dentro de proot Debian?"
  exit 1
fi

section "1/5 — Actualización del sistema"
log "Ejecutando apt update..."
apt update -q 2>&1 | tail -3
log "Ejecutando apt upgrade (puede tardar)..."
DEBIAN_FRONTEND=noninteractive apt upgrade -y -q 2>&1 | tail -5
ok "Sistema actualizado"

section "2/5 — Herramientas base"
log "Instalando Python, git, curl, nano..."
DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  python3 python3-pip python3-venv python3-dev \
  git curl wget ca-certificates \
  build-essential \
  nano vim \
  procps \
  2>&1 | tail -5
ok "Herramientas base instaladas"

section "3/5 — Entorno Python / smolagents"
VENV_DIR="/root/agent-env"

if [ -d "$VENV_DIR" ]; then
  log "Entorno virtual ya existe — actualizando..."
else
  log "Creando entorno virtual en $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

log "Instalando/actualizando dependencias Python..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet \
  smolagents \
  "fastapi>=0.111.0" \
  "uvicorn[standard]" \
  httpx \
  openai \
  requests \
  2>&1 | tail -3

ok "smolagents y FastAPI instalados en $VENV_DIR"

section "4/5 — Agent server"
AGENT_SERVER="/root/agent_server.py"

if [ ! -f "$AGENT_SERVER" ]; then
  log "Descargando agent_server.py desde GitHub..."
  curl -fsSL \
    "https://raw.githubusercontent.com/txurtxil/LinuxContainer/main/assets/agent_server.py" \
    -o "$AGENT_SERVER" 2>/dev/null || {
      warn "No se pudo descargar — creando plantilla mínima..."
      cat > "$AGENT_SERVER" << 'PYEOF'
# agent_server.py — placeholder
# El fichero real se copiará desde la app
print("Esperando configuración desde XTR Terminal...")
PYEOF
    }
  ok "agent_server.py listo en /root/"
else
  ok "agent_server.py ya existe"
fi

# Crear script de arranque del agente
cat > /root/start_agent.sh << 'STARTEOF'
#!/bin/bash
source /root/agent-env/bin/activate
cd /root
uvicorn agent_server:app --host 127.0.0.1 --port 8765 --workers 1 &
echo "Agente iniciado en puerto 8765 (PID: $!)"
STARTEOF
chmod +x /root/start_agent.sh

section "5/5 — Verificación"
echo ""
log "Python:       $(python3 --version 2>&1)"
log "pip:          $($VENV_DIR/bin/pip --version 2>&1 | cut -d' ' -f1-2)"
log "smolagents:   $($VENV_DIR/bin/pip show smolagents 2>/dev/null | grep Version || echo 'no instalado')"
log "fastapi:      $($VENV_DIR/bin/pip show fastapi 2>/dev/null | grep Version || echo 'no instalado')"
log "git:          $(git --version 2>&1)"

echo ""
echo -e "${GREEN}${BOLD}"
cat << 'DONE'
 ╔═══════════════════════════════════════╗
 ║        Setup completado ✓             ║
 ║                                       ║
 ║  Los modelos GPU (.task) se gestionan ║
 ║  desde la pantalla "Prueba GPU"       ║
 ║  de XTR Terminal.                     ║
 ║                                       ║
 ║  Para iniciar el agente:              ║
 ║    bash /root/start_agent.sh          ║
 ╚═══════════════════════════════════════╝
DONE
echo -e "${NC}"
