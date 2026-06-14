#!/bin/bash
# =============================================================================
# solucionar-dns-local.sh
# =============================================================================
# Se conecta por SSH a la Raspberry Pi (192.168.1.140) e instala/configura
# dnsmasq como DNS local para resolver www.mundaka.net desde dentro de la LAN.
# =============================================================================

set -euo pipefail

# ─── Colores ─────────────────────────────────────────────────────────────────
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
ROJO='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${VERDE}[✓]${NC} $1"; }
aviso()   { echo -e "${AMARILLO}[!]${NC} $1"; }
error()   { echo -e "${ROJO}[✗]${NC} $1"; }
titulo()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}\n"; }

# ─── Banner ──────────────────────────────────────────────────────────────────
clear
cat << "BANNER"
╔══════════════════════════════════════════════════════════════╗
║   Solucionador de NAT Loopback vía SSH                      ║
║                                                              ║
║   Conéctate a tu Raspberry Pi 192.168.1.140                 ║
║   y configura dnsmasq para www.mundaka.net                   ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo ""

# ─── Pedir credenciales SSH ──────────────────────────────────────────────────
echo "Introduce las credenciales SSH para conectarte a la Raspberry Pi"
echo "(IP: 192.168.1.140)"
echo ""
read -p "Usuario SSH: " SSH_USER
read -s -p "Contraseña SSH: " SSH_PASS
echo ""
echo ""

# ─── Variables ────────────────────────────────────────────────────────────────
RPI_IP="192.168.1.140"
DOMINIO="mundaka.net"
DOMINIO_WWW="www.mundaka.net"
DNS_UPSTREAM_1="1.1.1.1"
DNS_UPSTREAM_2="8.8.8.8"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# Función para ejecutar comandos remotos
remote() {
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${RPI_IP}" "$@"
}

# ─── Verificar sshpass ───────────────────────────────────────────────────────
titulo "PASO 0: Preparar entorno local"

if ! command -v sshpass &>/dev/null; then
    aviso "sshpass no está instalado. Instalándolo..."
    apt-get update -qq && apt-get install -y -qq sshpass
    info "sshpass instalado."
else
    info "sshpass ya está instalado."
fi

# ─── Verificar conectividad SSH ──────────────────────────────────────────────
titulo "PASO 0.5: Verificar conectividad con la Raspberry Pi"

if ! REMOTE_HOSTNAME=$(remote "hostname" 2>/dev/null); then
    error "No se pudo conectar a 192.168.1.140"
    error "Posibles causas:"
    error "  - Credenciales incorrectas"
    error "  - SSH no habilitado en la Pi (sudo systemctl enable ssh)"
    error "  - Puerto 22 cerrado en el firewall de la Pi"
    aviso  "La Pi responde ping, pero SSH rechaza la conexión."
    unset SSH_PASS
    exit 1
fi
info "Conectado a ${REMOTE_HOSTNAME} (${RPI_IP})"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PASO 1: Instalar dnsmasq
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 1: Instalar dnsmasq en la Raspberry Pi"

echo "Actualizando paquetes e instalando dnsmasq (puede tardar)..."
remote "sudo apt-get update -qq && sudo apt-get install -y -qq dnsmasq dnsutils" || {
    error "Falló la instalación remota de dnsmasq."
    unset SSH_PASS
    exit 1
}
info "dnsmasq instalado correctamente en la Pi."

# ═══════════════════════════════════════════════════════════════════════════
# PASO 2: Backup de configuración original
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 2: Respaldar configuración original"

remote "sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.\$(date +%Y%m%d-%H%M%S) 2>/dev/null; echo OK"
info "Backup realizado."

# ═══════════════════════════════════════════════════════════════════════════
# PASO 3: Configurar dnsmasq
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 3: Configurar dnsmasq en la Pi"

# Detectar la interfaz de LAN
INTERFAZ_LAN=$(remote "ip -4 route show default | grep -oP 'dev\s+\K[^\s]+' | head -1")
if [[ -z "${INTERFAZ_LAN}" ]]; then
    aviso "No se pudo detectar la interfaz. Usando eth0."
    INTERFAZ_LAN="eth0"
fi
info "Interfaz de red detectada: ${INTERFAZ_LAN}"

# Enviar configuración vía stdin con tee remoto
remote "sudo tee /etc/dnsmasq.conf > /dev/null" << EOF
# Configuracion generada por solucionar-dns-local.sh
# $(date '+%Y-%m-%d %H:%M:%S')

interface=${INTERFAZ_LAN}
bind-interfaces
no-resolv

server=${DNS_UPSTREAM_1}
server=${DNS_UPSTREAM_2}

cache-size=1000

address=/${DOMINIO}/${RPI_IP}
address=/${DOMINIO_WWW}/${RPI_IP}

listen-address=127.0.0.1
listen-address=${RPI_IP}

domain-needed
bogus-priv
local=/${DOMINIO}/
EOF

info "Configuración escrita en /etc/dnsmasq.conf"

# ═══════════════════════════════════════════════════════════════════════════
# PASO 4: Configurar resolv.conf en la Pi
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 4: Configurar la Pi para usar su propio DNS"

remote "sudo chattr -i /etc/resolv.conf 2>/dev/null; echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf > /dev/null; sudo chattr +i /etc/resolv.conf 2>/dev/null; echo OK"
info "resolv.conf apunta a 127.0.0.1 (protegido)"

# Configurar dhcpcd si existe
remote "if command -v dhcpcd >/dev/null 2>&1; then
  if ! grep -q 'nohook resolv.conf' /etc/dhcpcd.conf 2>/dev/null; then
    echo '' | sudo tee -a /etc/dhcpcd.conf > /dev/null
    echo '# Anadido por solucionar-dns-local.sh' | sudo tee -a /etc/dhcpcd.conf > /dev/null
    echo 'nohook resolv.conf' | sudo tee -a /etc/dhcpcd.conf > /dev/null
    echo 'dhcpcd configurado'
  else
    echo 'dhcpcd ya estaba configurado'
  fi
else
  echo 'dhcpcd no presente, se omite'
fi" || true
info "dhcpcd configurado (si aplica)."

# ═══════════════════════════════════════════════════════════════════════════
# PASO 5: Verificar IP estática
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 5: Verificar IP de la Pi"

IP_ACTUAL=$(remote "ip -4 addr show ${INTERFAZ_LAN} 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true")
if [[ "${IP_ACTUAL}" != "${RPI_IP}" ]]; then
    aviso "La IP actual es ${IP_ACTUAL:-DESCONOCIDA}, no ${RPI_IP}."
    echo ""
    read -p "Configurar IP estática ${RPI_IP} en la Pi ahora? (s/N): " CONFIG_IP
    if [[ "${CONFIG_IP,,}" =~ ^s(í|i)?$ ]]; then
        remote "echo '' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo '# IP estatica (solucionar-dns-local.sh)' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo 'interface ${INTERFAZ_LAN}' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo 'static ip_address=${RPI_IP}/24' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo 'static routers=192.168.1.1' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo 'static domain_name_servers=127.0.0.1' | sudo tee -a /etc/dhcpcd.conf > /dev/null
echo OK"
        info "IP estática configurada (se aplica al reiniciar)."
        aviso "Ejecuta en la Pi: sudo reboot"
    fi
else
    info "IP correcta: ${RPI_IP}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PASO 6: Firewall
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 6: Abrir puerto 53 en el firewall"

remote "if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 53/tcp comment 'DNS' >/dev/null 2>&1
  sudo ufw allow 53/udp comment 'DNS' >/dev/null 2>&1
  echo 'ufw OK'
elif command -v firewall-cmd >/dev/null 2>&1; then
  sudo firewall-cmd --add-service=dns --permanent >/dev/null 2>&1
  sudo firewall-cmd --reload >/dev/null 2>&1
  echo 'firewalld OK'
else
  echo 'Sin firewall detectado'
fi" || true
info "Puerto 53 abierto."

# ═══════════════════════════════════════════════════════════════════════════
# PASO 7: Arrancar dnsmasq
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 7: Arrancar dnsmasq en la Pi"

echo "Deteniendo servicios conflictivos..."
remote "sudo systemctl stop systemd-resolved 2>/dev/null || true"
remote "sudo systemctl disable systemd-resolved 2>/dev/null || true"
remote "sudo systemctl stop bind9 2>/dev/null || true"
remote "sudo systemctl stop named 2>/dev/null || true"
info "Listo."

echo "Arrancando dnsmasq..."
remote "sudo systemctl enable dnsmasq 2>/dev/null; sudo systemctl restart dnsmasq" || {
    error "Fallo al arrancar dnsmasq."
    error "Logs remotos:"
    remote "sudo journalctl -u dnsmasq -n 30 --no-pager 2>&1 || true"
    unset SSH_PASS
    exit 1
}
info "dnsmasq arrancado correctamente."

# ═══════════════════════════════════════════════════════════════════════════
# PASO 8: Verificar DNS
# ═══════════════════════════════════════════════════════════════════════════
titulo "PASO 8: Verificar resolución DNS en la Pi"

sleep 1

echo "→ www.mundaka.net..."
RES1=$(remote "nslookup www.mundaka.net 127.0.0.1 2>/dev/null | grep -oP 'Address:\s+\K[^\s]+' | tail -1")
if [[ "${RES1}" == "${RPI_IP}" ]]; then
    info "www.mundaka.net → ${RES1}  ✓"
else
    aviso "www.mundaka.net → ${RES1:-fallo}  (se esperaba ${RPI_IP})"
fi

echo "→ mundaka.net..."
RES2=$(remote "nslookup mundaka.net 127.0.0.1 2>/dev/null | grep -oP 'Address:\s+\K[^\s]+' | tail -1")
if [[ "${RES2}" == "${RPI_IP}" ]]; then
    info "mundaka.net → ${RES2}  ✓"
else
    aviso "mundaka.net → ${RES2:-fallo}  (se esperaba ${RPI_IP})"
fi

echo "→ google.com (upstream)..."
RES3=$(remote "nslookup google.com 127.0.0.1 2>/dev/null | grep -oP 'Address:\s+\K[^\s]+' | tail -1")
if [[ -n "${RES3}" ]]; then
    info "google.com → ${RES3}  (upstream OK)"
else
    aviso "google.com no se resolvió — revisa conectividad WAN en la Pi"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PASO 9: Instrucciones finales
# ═══════════════════════════════════════════════════════════════════════════
titulo "PRÓXIMOS PASOS"

cat << "INSTRUCCIONES"
╔══════════════════════════════════════════════════════════════════════╗
║  La Raspberry Pi ya resuelve tu dominio correctamente.               ║
║                                                                      ║
║  Ahora configura el RESTO de dispositivos de tu LAN                 ║
║  para que usen la Pi como DNS.                                       ║
╚══════════════════════════════════════════════════════════════════════╝

  OPCION A — CAMBIAR DNS EN EL ROUTER (RECOMENDADA)
  ─────────────────────────────────────────────
  1. Entra en http://192.168.1.1
  2. Busca "DHCP Server" o "LAN Configuration"
  3. Pon "Primary DNS" = 192.168.1.140
  4. Guarda. Los clientes que renueven DHCP usaran la Pi como DNS.

  OPCION B — CAMBIAR DNS EN CADA DISPOSITIVO
  ─────────────────────────────────────────────
  Configura el DNS manualmente a 192.168.1.140 en cada equipo.

INSTRUCCIONES

# ─── Limpiar ──────────────────────────────────────────────────────────────────
titulo "RESUMEN FINAL"

info "Conexión:         ${SSH_USER}@${RPI_IP}"
info "dnsmasq:           ✓ instalado y corriendo"
info "mundaka.net      → ${RPI_IP}"
info "www.mundaka.net  → ${RPI_IP}"
info "Otros dominios   → ${DNS_UPSTREAM_1}, ${DNS_UPSTREAM_2}"
echo ""
echo "Logs remotos: ssh ${SSH_USER}@${RPI_IP} 'sudo journalctl -u dnsmasq -f'"
echo ""

unset SSH_PASS
SSH_PASS=""

exit 0
