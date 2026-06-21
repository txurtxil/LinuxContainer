#!/bin/bash
# LinuxContainer - Menú de gestión
# Relanzable en cualquier momento con: lc-menu

set -o pipefail

C_RESET='\e[0m'; C_B='\e[1m'; C_DIM='\e[2m'
C_GRN='\e[1;32m'; C_BLU='\e[1;34m'; C_YEL='\e[1;33m'; C_RED='\e[1;31m'; C_CYN='\e[1;36m'; C_MAG='\e[1;35m'

MARKER="$HOME/.lc_setup_done"

pause() { echo ""; read -rp "$(echo -e "${C_DIM}↵ Enter para continuar${C_RESET}")" _; }
hr() { echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"; }

apt_install() {
  echo -e "${C_CYN}▸ Instalando: $*${C_RESET}"
  if apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
    echo -e "${C_GRN}✓ Instalado correctamente${C_RESET}"
  else
    echo -e "${C_RED}✗ Error (¿sin red?). Revisa la conexión.${C_RESET}"
  fi
}

header() {
  clear
  echo -e "${C_GRN}╔════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GRN}║${C_RESET}  ${C_B}${C_GRN}LinuxContainer${C_RESET} ${C_DIM}·${C_RESET} ${C_B}Centro de control${C_RESET}     ${C_GRN}║${C_RESET}"
  echo -e "${C_GRN}╚════════════════════════════════════════╝${C_RESET}"
}

# ─────────────── SUBMENÚ: PAQUETES ───────────────
menu_packages() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Instalar paquetes${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Base         ${C_DIM}git curl wget python3 nano unzip${C_RESET}"
    echo -e "  ${C_YEL}2${C_RESET})  Red          ${C_DIM}nmap net-tools dnsutils traceroute${C_RESET}"
    echo -e "  ${C_YEL}3${C_RESET})  Desarrollo   ${C_DIM}build-essential pip venv${C_RESET}"
    echo -e "  ${C_YEL}4${C_RESET})  Editores     ${C_DIM}vim tmux zsh${C_RESET}"
    echo -e "  ${C_YEL}5${C_RESET})  Midnight Commander ${C_DIM}(mc)${C_RESET}"
    echo -e "  ${C_YEL}6${C_RESET})  OpenSSH server ${C_DIM}(instala y configura)${C_RESET}"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) apt_install git curl wget python3 nano unzip ca-certificates; pause ;;
      2) apt_install nmap net-tools dnsutils traceroute iputils-ping; pause ;;
      3) apt_install build-essential python3-pip python3-venv; pause ;;
      4) apt_install vim tmux zsh; pause ;;
      5) apt_install mc; pause ;;
      6) setup_openssh; pause ;;
      v|V) return ;;
    esac
  done
}

setup_openssh() {
  apt_install openssh-server
  if [ -d /etc/ssh ]; then
    echo -e "${C_CYN}▸ Configurando SSH...${C_RESET}"
    mkdir -p /run/sshd
    ssh-keygen -A 2>/dev/null
    sed -i 's/#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    echo -e "${C_GRN}✓ SSH configurado.${C_RESET}"
    echo -e "  Inicia con: ${C_B}/usr/sbin/sshd${C_RESET}  ·  Puerto: ${C_B}22${C_RESET}"
    echo -e "  ${C_DIM}Pon contraseña a root en 'Configurar sistema'.${C_RESET}"
  fi
}

# ─────────────── SUBMENÚ: SISTEMA ───────────────
menu_system() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Configurar sistema${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Cambiar hostname"
    echo -e "  ${C_YEL}2${C_RESET})  Cambiar contraseña de root"
    echo -e "  ${C_YEL}3${C_RESET})  Configurar zona horaria"
    echo -e "  ${C_YEL}4${C_RESET})  Crear usuario no-root ${C_DIM}(con sudo)${C_RESET}"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) read -rp "Nuevo hostname: " hn; [ -n "$hn" ] && echo "$hn" > /etc/hostname && hostname "$hn" 2>/dev/null && echo -e "${C_GRN}✓ Hostname: $hn${C_RESET}"; pause ;;
      2) echo -e "${C_CYN}Cambiar contraseña de root:${C_RESET}"; passwd root; pause ;;
      3) cfg_timezone; pause ;;
      4) create_user; pause ;;
      v|V) return ;;
    esac
  done
}

cfg_timezone() {
  command -v tzselect >/dev/null 2>&1 || apt_install tzdata
  read -rp "Zona (ej. Europe/Madrid): " tz
  if [ -n "$tz" ] && [ -f "/usr/share/zoneinfo/$tz" ]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
    echo "$tz" > /etc/timezone
    echo -e "${C_GRN}✓ Zona horaria: $tz${C_RESET}"
  else
    echo -e "${C_RED}✗ Zona no válida.${C_RESET}"
  fi
}

create_user() {
  read -rp "Nombre del nuevo usuario: " user
  [ -z "$user" ] && return
  command -v sudo >/dev/null 2>&1 || apt_install sudo
  adduser "$user"
  usermod -aG sudo "$user" 2>/dev/null
  echo -e "${C_GRN}✓ Usuario '$user' creado con sudo.${C_RESET}"
}

# ─────────────── SUBMENÚ: SERVICIOS Y TÚNELES ───────────────
menu_services() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Servicios y túneles${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Iniciar/parar OpenSSH server"
    echo -e "  ${C_YEL}2${C_RESET})  Instalar y configurar ngrok"
    echo -e "  ${C_YEL}3${C_RESET})  Instalar Nginx ${C_DIM}(proxy inverso)${C_RESET}"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) toggle_sshd; pause ;;
      2) setup_ngrok; pause ;;
      3) setup_nginx; pause ;;
      v|V) return ;;
    esac
  done
}

toggle_sshd() {
  if pgrep -x sshd >/dev/null 2>&1; then
    pkill -x sshd && echo -e "${C_YEL}SSH detenido.${C_RESET}"
  else
    if [ -x /usr/sbin/sshd ]; then
      mkdir -p /run/sshd; /usr/sbin/sshd && echo -e "${C_GRN}✓ SSH iniciado en puerto 22.${C_RESET}"
    else
      echo -e "${C_RED}SSH no instalado. Instálalo en 'Paquetes'.${C_RESET}"
    fi
  fi
}

setup_ngrok() {
  if ! command -v ngrok >/dev/null 2>&1; then
    echo -e "${C_CYN}▸ Descargando ngrok (arm64)...${C_RESET}"
    local url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-arm64.tgz"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o /tmp/ngrok.tgz
    elif command -v wget >/dev/null 2>&1; then
      wget -qO /tmp/ngrok.tgz "$url"
    else
      echo -e "${C_RED}Necesitas curl o wget (instálalos en Paquetes).${C_RESET}"; return
    fi
    tar -xzf /tmp/ngrok.tgz -C /usr/local/bin/ && rm -f /tmp/ngrok.tgz
    echo -e "${C_GRN}✓ ngrok instalado.${C_RESET}"
  fi
  echo ""
  echo -e "Necesitas un authtoken de ${C_B}https://dashboard.ngrok.com${C_RESET}"
  read -rp "Pega tu authtoken (Enter para saltar): " tok
  [ -n "$tok" ] && ngrok config add-authtoken "$tok" && echo -e "${C_GRN}✓ Token guardado.${C_RESET}"
  echo -e "  Uso: ${C_B}ngrok http 8080${C_RESET}  o  ${C_B}ngrok tcp 22${C_RESET}"
}

setup_nginx() {
  apt_install nginx
  if command -v nginx >/dev/null 2>&1; then
    echo -e "${C_GRN}✓ Nginx instalado.${C_RESET}"
    echo -e "  Config: ${C_B}/etc/nginx/sites-available/default${C_RESET}"
    echo -e "  Iniciar: ${C_B}nginx${C_RESET}  ·  Parar: ${C_B}nginx -s stop${C_RESET}"
    echo -e "  ${C_DIM}Proxy a un servicio local en :3000:${C_RESET}"
    echo -e "  ${C_DIM}  location / { proxy_pass http://127.0.0.1:3000; }${C_RESET}"
  fi
}

# ─────────────── SUBMENÚ: MANTENIMIENTO ───────────────
menu_maint() {
  while true; do
    header
    echo -e "  ${C_MAG}❯ Mantenimiento${C_RESET}"
    hr
    echo -e "  ${C_YEL}1${C_RESET})  Actualizar sistema ${C_DIM}(update && upgrade)${C_RESET}"
    echo -e "  ${C_YEL}2${C_RESET})  Ver información del sistema"
    echo -e "  ${C_YEL}3${C_RESET})  Test de red ${C_DIM}(ping + DNS)${C_RESET}"
    echo -e "  ${C_YEL}4${C_RESET})  Limpiar caché de apt"
    hr
    echo -e "  ${C_CYN}v${C_RESET})  Volver"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) apt-get update -y && apt-get upgrade -y; echo -e "${C_GRN}✓ Sistema actualizado.${C_RESET}"; pause ;;
      2) sys_info; pause ;;
      3) net_test; pause ;;
      4) apt-get clean && apt-get autoclean -y && echo -e "${C_GRN}✓ Caché limpiada.${C_RESET}"; pause ;;
      v|V) return ;;
    esac
  done
}

sys_info() {
  hr
  echo -e "${C_B}Kernel:${C_RESET}   $(uname -r)"
  echo -e "${C_B}Distro:${C_RESET}   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo -e "${C_B}Arch:${C_RESET}     $(uname -m)"
  echo -e "${C_B}CPU:${C_RESET}      $(nproc) núcleos"
  echo -e "${C_B}Memoria:${C_RESET}  $(free -h 2>/dev/null | awk '/Mem:/{print $3" / "$2}')"
  echo -e "${C_B}Disco:${C_RESET}    $(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  echo -e "${C_B}Uptime:${C_RESET}   $(uptime -p 2>/dev/null || echo 'n/d')"
  hr
}

net_test() {
  echo -e "${C_CYN}▸ Probando conectividad...${C_RESET}"
  if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "${C_GRN}✓ Internet OK${C_RESET} ${C_DIM}(ping 8.8.8.8)${C_RESET}"
  else
    echo -e "${C_RED}✗ Sin conectividad a 8.8.8.8${C_RESET}"
  fi
  if ping -c 2 google.com >/dev/null 2>&1; then
    echo -e "${C_GRN}✓ DNS OK${C_RESET} ${C_DIM}(google.com resuelve)${C_RESET}"
  else
    echo -e "${C_YEL}⚠ DNS no resuelve${C_RESET}"
  fi
}

# ─────────────── MENÚ PRINCIPAL ───────────────
main_menu() {
  while true; do
    header
    echo ""
    echo -e "  ${C_YEL}1${C_RESET})  ${C_B}Instalar paquetes${C_RESET}"
    echo -e "  ${C_YEL}2${C_RESET})  ${C_B}Configurar sistema${C_RESET}"
    echo -e "  ${C_YEL}3${C_RESET})  ${C_B}Servicios y túneles${C_RESET}"
    echo -e "  ${C_YEL}4${C_RESET})  ${C_B}Mantenimiento${C_RESET}"
    hr
    echo -e "  ${C_GRN}s${C_RESET})  Ir al shell"
    echo -e "  ${C_RED}q${C_RESET})  Salir ${C_DIM}(no volver a mostrar al inicio)${C_RESET}"
    echo ""
    read -rp "$(echo -e "${C_B}❯ ${C_RESET}")" opt
    case "$opt" in
      1) menu_packages ;;
      2) menu_system ;;
      3) menu_services ;;
      4) menu_maint ;;
      s|S) shell_exit ;;
      q|Q) touch "$MARKER"; clear; echo -e "${C_DIM}Menú desactivado al inicio.${C_RESET}"; echo -e "Para reabrirlo escribe ${C_B}${C_GRN}lc-menu${C_RESET} en cualquier momento."; echo ""; return 0 ;;
    esac
  done
}

shell_exit() {
  clear
  echo -e "${C_GRN}▸ Saliendo al shell.${C_RESET}"
  echo -e "  Para volver a este menú, escribe ${C_B}${C_GRN}lc-menu${C_RESET} y pulsa Enter."
  echo -e "  ${C_DIM}Escribe 'help-lc' para ver todos los atajos disponibles.${C_RESET}"
  echo ""
  return 0
}

main_menu
