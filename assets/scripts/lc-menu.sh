#!/bin/bash
# XTR Terminal — Menú de gestión
set -o pipefail
C_RESET='\e[0m'; C_B='\e[1m'; C_DIM='\e[2m'
C_GRN='\e[1;32m'; C_YEL='\e[1;33m'; C_RED='\e[1;31m'
C_CYN='\e[1;36m'; C_MAG='\e[1;35m'
MARKER="$HOME/.lc_setup_done"

pause() { echo ""; read -rp "$(echo -e "${C_DIM}↵ Enter para continuar${C_RESET}")" _; }
hr()    { echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"; }

header() {
  clear
  echo -e "${C_GRN}╔════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GRN}║${C_RESET}  ${C_B}${C_GRN}XTR Terminal${C_RESET} ${C_DIM}·${C_RESET} ${C_B}Centro de control${C_RESET}       ${C_GRN}║${C_RESET}"
  echo -e "${C_GRN}╚════════════════════════════════════════╝${C_RESET}"
}

fix_dns() {
  # Fijar DNS siempre — no verificamos red (ping/curl pueden no estar disponibles)
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
  echo "nameserver 1.1.1.1" >> /etc/resolv.conf
  return 0
}

apt_install() {
  echo -e "${C_CYN}▸ Instalando: $*${C_RESET}"
  fix_dns || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    --fix-missing "$@" 2>&1 | grep -E "^(E:|W:|✓|Setting up|Unpacking)" | tail -10
  echo -e "${C_GRN}✓ Listo${C_RESET}"
}

# ── Setup completo del agente IA ──────────────────────────────
setup_agent() {
  header
  echo -e "  ${C_MAG}❯ Setup Agente IA${C_RESET}"
  hr
  echo -e "  Instala Python3, smolagents y el servidor del agente."
  echo -e "  ${C_DIM}Requiere WiFi. Primera vez ~10 min.${C_RESET}"
  echo ""
  read -rp "$(echo -e "  ¿Continuar? ${C_YEL}[s/N]${C_RESET} ")" confirm
  [[ "$confirm" != "s" && "$confirm" != "S" ]] && return

  echo ""

  # Fix DNS primero
  fix_dns
  echo -e "${C_GRN}✓ DNS configurado${C_RESET}"

  # apt update
  echo -e "${C_CYN}▸ Actualizando lista de paquetes...${C_RESET}"
  apt-get update -q 2>&1 | tail -3

  # Instalar python3 y herramientas
  echo -e "${C_CYN}▸ Instalando Python3 y herramientas base...${C_RESET}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
    python3 python3-pip python3-venv python3-dev \
    git curl wget ca-certificates build-essential 2>&1 | tail -5

  # Verificar python3
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${C_RED}✗ python3 no instalado. ¿Hay conexión a internet?${C_RESET}"
    pause; return
  fi
  echo -e "${C_GRN}✓ $(python3 --version)${C_RESET}"

  # Crear venv
  echo -e "${C_CYN}▸ Creando entorno virtual /root/agent-env...${C_RESET}"
  python3 -m venv /root/agent-env --clear
  echo -e "${C_GRN}✓ Entorno virtual creado${C_RESET}"

  # Instalar smolagents
  echo -e "${C_CYN}▸ Instalando smolagents y FastAPI (5-8 min)...${C_RESET}"
  /root/agent-env/bin/pip install --quiet --upgrade pip
  /root/agent-env/bin/pip install \
    smolagents "fastapi>=0.111.0" "uvicorn[standard]" \
    httpx openai requests
  VER=$(/root/agent-env/bin/pip show smolagents 2>/dev/null | grep Version | cut -d' ' -f2)
  echo -e "${C_GRN}✓ smolagents $VER instalado${C_RESET}"

  # agent_server.py
  echo -e "${C_CYN}▸ Verificando agent_server.py...${C_RESET}"
  if [ ! -f /root/agent_server.py ]; then
    curl -fsSL \
      "https://raw.githubusercontent.com/txurtxil/LinuxContainer/main/assets/agent_server.py" \
      -o /root/agent_server.py 2>/dev/null \
      && echo -e "${C_GRN}✓ agent_server.py descargado${C_RESET}" \
      || echo -e "${C_YEL}⚠ Descarga fallida — se descargará al arrancar el agente${C_RESET}"
  else
    echo -e "${C_GRN}✓ agent_server.py ya existe${C_RESET}"
  fi

  # start_agent.sh
  cat > /root/start_agent.sh << 'STARTEOF'
#!/bin/bash
source /root/agent-env/bin/activate
cd /root
exec uvicorn agent_server:app --host 127.0.0.1 --port 8765 --workers 1
STARTEOF
  chmod +x /root/start_agent.sh

  hr
  echo -e "${C_GRN}${C_B}✓ Setup completado${C_RESET}"
  echo ""
  echo -e "  ${C_DIM}→ Vuelve al Agente en la app y pulsa ▶ en agent-server${C_RESET}"
  echo -e "  ${C_DIM}→ Modelos GPU: pantalla 'Prueba GPU' de la app${C_RESET}"
  pause
}

# ── Paquetes extra ────────────────────────────────────────────
menu_packages() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Paquetes extra${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Red          ${C_DIM}nmap net-tools dnsutils traceroute${C_RESET}"
    echo -e "  ${C_YEL}2${C_RESET})  Editores     ${C_DIM}vim tmux zsh mc${C_RESET}"
    echo -e "  ${C_YEL}3${C_RESET})  OpenSSH      ${C_DIM}(instala y configura)${C_RESET}"
    echo -e "  ${C_YEL}4${C_RESET})  Nginx        ${C_DIM}(proxy inverso)${C_RESET}"
    echo -e "  ${C_YEL}5${C_RESET})  ngrok        ${C_DIM}(túnel a internet)${C_RESET}"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) apt_install nmap net-tools dnsutils traceroute iputils-ping; pause ;;
      2) apt_install vim tmux zsh mc; pause ;;
      3) setup_openssh; pause ;;
      4) setup_nginx; pause ;;
      5) setup_ngrok; pause ;;
      v|V) return ;;
    esac
  done
}

setup_openssh() {
  apt_install openssh-server
  mkdir -p /run/sshd
  ssh-keygen -A 2>/dev/null
  sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  echo -e "${C_GRN}✓ SSH listo. Inicia con: /usr/sbin/sshd${C_RESET}"
}

setup_nginx() {
  apt_install nginx
  echo -e "${C_GRN}✓ Nginx listo. Config: /etc/nginx/sites-available/default${C_RESET}"
}

setup_ngrok() {
  command -v ngrok >/dev/null 2>&1 || {
    echo -e "${C_CYN}▸ Descargando ngrok arm64...${C_RESET}"
    curl -fsSL "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz" \
      -o /tmp/ngrok.tgz && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin/ && rm -f /tmp/ngrok.tgz
  }
  read -rp "Authtoken de ngrok.com (Enter para saltar): " tok
  [ -n "$tok" ] && ngrok config add-authtoken "$tok"
  echo -e "${C_GRN}✓ ngrok listo. Uso: ngrok http 8080${C_RESET}"
}

# ── Sistema ───────────────────────────────────────────────────
menu_system() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Sistema${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Actualizar sistema"
    echo -e "  ${C_YEL}2${C_RESET})  Info del sistema"
    echo -e "  ${C_YEL}3${C_RESET})  Test de red"
    echo -e "  ${C_YEL}4${C_RESET})  Cambiar contraseña de root"
    echo -e "  ${C_YEL}5${C_RESET})  Configurar zona horaria"
    echo -e "  ${C_YEL}6${C_RESET})  Limpiar caché apt"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) fix_dns && apt-get update -q && apt-get upgrade -y; pause ;;
      2) sys_info; pause ;;
      3) net_test; pause ;;
      4) passwd root; pause ;;
      5) cfg_timezone; pause ;;
      6) apt-get clean && apt-get autoclean -y; echo -e "${C_GRN}✓ Caché limpiada${C_RESET}"; pause ;;
      v|V) return ;;
    esac
  done
}

sys_info() {
  hr
  echo -e "${C_B}Kernel:${C_RESET}   $(uname -r 2>/dev/null || echo n/d)"
  echo -e "${C_B}Distro:${C_RESET}   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo Debian)"
  echo -e "${C_B}Arch:${C_RESET}     $(uname -m)"
  echo -e "${C_B}CPU:${C_RESET}      $(nproc) núcleos"
  echo -e "${C_B}Memoria:${C_RESET}  $(free -h 2>/dev/null | awk '/Mem:/{print $3" / "$2}')"
  echo -e "${C_B}Disco:${C_RESET}    $(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  echo -e "${C_B}Python3:${C_RESET}  $(python3 --version 2>/dev/null || echo 'no instalado')"
  echo -e "${C_B}smolagents:${C_RESET} $(/root/agent-env/bin/pip show smolagents 2>/dev/null | grep Version | cut -d' ' -f2 || echo 'no instalado')"
  hr
}

net_test() {
  echo -e "${C_CYN}▸ Probando red...${C_RESET}"
  fix_dns
  curl -fsS --max-time 5 https://deb.debian.org > /dev/null 2>&1 \
    && echo -e "${C_GRN}✓ Internet + DNS OK${C_RESET}" \
    || echo -e "${C_RED}✗ Sin internet o DNS falla${C_RESET}"
}

cfg_timezone() {
  read -rp "Zona (ej. Europe/Madrid): " tz
  [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ] && \
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime && \
    echo "$tz" > /etc/timezone && \
    echo -e "${C_GRN}✓ Zona: $tz${C_RESET}" || \
    echo -e "${C_RED}✗ Zona no válida${C_RESET}"
}

# ── Menú principal ────────────────────────────────────────────
main_menu() {
  while true; do
    header
    echo ""
    echo -e "  ${C_MAG}1${C_RESET})  ${C_B}Setup Agente IA${C_RESET}  ${C_DIM}(Python + smolagents + agent-server)${C_RESET}"
    echo -e "  ${C_YEL}2${C_RESET})  ${C_B}Paquetes extra${C_RESET}   ${C_DIM}(red, editores, SSH, ngrok...)${C_RESET}"
    echo -e "  ${C_YEL}3${C_RESET})  ${C_B}Sistema${C_RESET}          ${C_DIM}(actualizar, info, DNS, zona horaria)${C_RESET}"
    hr
    echo -e "  ${C_GRN}s${C_RESET})  Ir al shell"
    echo -e "  ${C_RED}q${C_RESET})  Salir ${C_DIM}(no mostrar al inicio)${C_RESET}"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) setup_agent ;;
      2) menu_packages ;;
      3) menu_system ;;
      s|S) clear; echo -e "${C_GRN}▸ Shell. Escribe ${C_B}lc-menu${C_RESET}${C_GRN} para volver.${C_RESET}"; echo ""; return 0 ;;
      q|Q) touch "$MARKER"; clear; echo -e "${C_DIM}Menú desactivado. Escribe ${C_B}lc-menu${C_RESET}${C_DIM} para reabrirlo.${C_RESET}"; echo ""; return 0 ;;
    esac
  done
}

main_menu
