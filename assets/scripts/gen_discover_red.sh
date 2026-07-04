#!/bin/bash
# Descubre hosts vivos en una subred /24. Version conservadora: un
# primer intento con 32 concurrentes y 3 puertos de sonda provoco
# SIGKILL de la sesion (demasiada carga de procesos bajo proot en
# Android). Bajado a 8 concurrentes y 1 solo puerto, validado en
# produccion con el rango completo (254 IPs, 34s, sin caidas).
# Uso: bash gen_discover_red.sh <prefijo_red> <salida.txt> [inicio] [fin]
# Ejemplo pequeno de prueba: bash gen_discover_red.sh 192.168.10 /root/ips.txt 1 20
PREFIJO="$1"
OUTPUT="$2"
INICIO="${3:-1}"
FIN="${4:-254}"
PUERTO_SONDA=80
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
    if timeout "$TIMEOUT_SEG" bash -c "echo > /dev/tcp/$ip/$PUERTO_SONDA" 2>/dev/null; then
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
