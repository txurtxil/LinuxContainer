#!/bin/bash
# gen_discover_red.sh — Descubrimiento continuo + monitor de cambios en la red
# Uso: gen_discover_red.sh [SUBRED] [SALIDA]
set -e

SUBNET="${1:-$(ip route | awk '/src/ {print $1}' | head -1)}"
OUTDIR="${2:-/root}"
mkdir -p "$OUTDIR"
BASELINE="$OUTDIR/red_baseline.txt"
CURRENT="$OUTDIR/red_current.txt"
DIFF="$OUTDIR/red_diff.txt"

echo "[*] Escaneando $SUBNET..."
nmap -sn "$SUBNET" -oG - 2>/dev/null | awk '/Up$/{print $2}' | sort > "$CURRENT"

if [ -f "$BASELINE" ]; then
    echo "[*] Comparando con baseline..."
    NEW=$(comm -13 "$BASELINE" "$CURRENT")
    LOST=$(comm -23 "$BASELINE" "$CURRENT")
    if [ -n "$NEW" ]; then
        echo "[!] NUEVOS EQUIPOS DETECTADOS:" | tee "$DIFF"
        echo "$NEW" | tee -a "$DIFF"
    fi
    if [ -n "$LOST" ]; then
        echo "[!] EQUIPOS PERDIDOS:" | tee -a "$DIFF"
        echo "$LOST" | tee -a "$DIFF"
    fi
    if [ -z "$NEW" ] && [ -z "$LOST" ]; then
        echo "[+] Sin cambios respecto al escaneo anterior." | tee "$DIFF"
    fi
else
    echo "[*] Primer escaneo (baseline creado)."
    cp "$CURRENT" "$BASELINE"
fi

echo "[*] Resultado actual: $(wc -l < "$CURRENT") hosts"
cat "$CURRENT"
