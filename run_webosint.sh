#!/usr/bin/env bash
# Lanzador rápido para webosint
# Inicia el servidor en puerto 9080 y abre el navegador si es posible
set -euo pipefail

cd "$(dirname "$0")"

# Matar instancia previa si existe
pkill -f "webosint.py" 2>/dev/null || true
sleep 0.5

echo ""
echo "  ◈ webosint — OSINT web server"
echo "  ◈ Puerto 9080"
echo ""

# Iniciar servidor
python3 -u webosint.py &
PID=$!

# Esperar que levante
sleep 1

# Verificar que está corriendo
if kill -0 "$PID" 2>/dev/null; then
    echo "  ✓ Servidor iniciado (PID: $PID)"
    echo "  ✓ http://localhost:9080"
    echo ""
    echo "  Presiona Ctrl+C para detener"
else
    echo "  ✗ Error al iniciar servidor"
    exit 1
fi

# Intentar abrir navegador
if command -v xdg-open &>/dev/null; then
    xdg-open "http://localhost:9080" 2>/dev/null || true
elif command -v sensible-browser &>/dev/null; then
    sensible-browser "http://localhost:9080" 2>/dev/null || true
fi

# Esperar señal de terminación
trap "echo ''; echo '  ⏹  Deteniendo...'; kill $PID 2>/dev/null; exit 0" INT TERM
wait "$PID"
