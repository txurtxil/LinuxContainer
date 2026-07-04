#!/bin/bash
# Descubre hosts vivos en una subred /24 usando ping (ICMP), que Android
# permite sin privilegios especiales a diferencia de rutas/ARP (ambas
# bloqueadas por el kernel a nivel de plataforma, confirmado esta noche
# con /proc/net/route y /proc/net/arp). Sustituye una version anterior
# que sondeaba puertos TCP -- esa version solo encontraba dispositivos
# con puertos comunes abiertos (4 en la red real de prueba); esta
# version encuentra CUALQUIER dispositivo con IP activa (13 en la
# misma red), acercandose mucho a lo que ve un escaner con acceso a
# ARP como Fing (11-14 dispositivos).
# Uso: bash gen_discover_red.sh <prefijo_red> <salida.txt> [inicio] [fin]
PREFIJO="$1"
OUTPUT="$2"
INICIO="${3:-1}"
FIN="${4:-254}"
LOTE=8
TIMEOUT_SEG=1

if [ -z "$PREFIJO" ] || [ -z "$OUTPUT" ]; then
    echo "Uso: gen_discover_red.sh <prefijo_red> <salida.txt> [inicio] [fin]"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

check_ip() {
    local ip="$1"
    local outfile="$2"
    if ping -c 1 -W "$TIMEOUT_SEG" "$ip" >/dev/null 2>&1; then
        echo "$ip" > "$outfile"
    fi
}

count=0
for i in $(seq "$INICIO" "$FIN"); do
    ip="${PREFIJO}.${i}"
    check_ip "$ip" "$TMPDIR/host_$i.found" &
    count=$((count+1))
    if [ "$count" -ge "$LOTE" ]; then
        wait
        count=0
    fi
done
wait

if ls "$TMPDIR"/*.found >/dev/null 2>&1; then
    cat "$TMPDIR"/*.found | sort -t. -k4 -n > "$OUTPUT"
else
    > "$OUTPUT"
fi

echo "Encontrados: $(wc -l < "$OUTPUT") hosts"
