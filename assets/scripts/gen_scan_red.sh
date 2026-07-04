#!/bin/bash
# Escanea una lista de IPs contra puertos comunes usando /dev/tcp de bash
# (evita el bloqueo de Android a /proc/net/route que impide a nmap
# calcular rutas -- confirmado esta noche: nmap falla con
# "failed to determine route", pero /dev/tcp si funciona porque
# deja que el kernel de Android enrute la conexion, sin que la app
# tenga que consultar la tabla de rutas por si misma).
# Genera un fichero de dispositivos compatible con gen_topologia.sh.
# Uso: bash gen_scan_red.sh <fichero_ips> <salida_dispositivos.txt>
# Formato de <fichero_ips>: una IP por linea, o "Nombre:IP"
INPUT="$1"
OUTPUT="$2"
PUERTOS="22 80 443 8080 8090 8765 3389 21 23 445 5000"

if [ ! -f "$INPUT" ]; then
    echo "Error: no existe $INPUT"
    exit 1
fi

RESULTADO=""
while IFS= read -r linea || [ -n "$linea" ]; do
    [ -z "$linea" ] && continue
    if [[ "$linea" == *":"* ]]; then
        nombre="${linea%%:*}"
        ip="${linea#*:}"
    else
        ip="$linea"
        nombre="$ip"
    fi

    abiertos=""
    for p in $PUERTOS; do
        if timeout 1 bash -c "echo > /dev/tcp/$ip/$p" 2>/dev/null; then
            abiertos="$abiertos $p"
        fi
    done

    if [ -n "$abiertos" ]; then
        etiqueta="$nombre (puertos:$abiertos)"
    else
        etiqueta="$nombre (sin puertos comunes)"
    fi

    if [ -z "$RESULTADO" ]; then
        RESULTADO="${etiqueta}:${ip}"
    else
        RESULTADO="${RESULTADO};${etiqueta}:${ip}"
    fi
    echo "Escaneado: $ip -> ${abiertos:-ninguno}" >&2
done < "$INPUT"

echo "$RESULTADO" > "$OUTPUT"
