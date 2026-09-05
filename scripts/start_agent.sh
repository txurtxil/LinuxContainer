#!/bin/bash
# XTR Agent — start_agent.sh v13.0
# Arranca el agent-server autónomo dentro del contenedor proot
set -e

AGENT_PORT="${AGENT_PORT:-8765}"
export AGENT_PORT
export LLM_BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:8090/v1}"
export LLM_MODEL="${LLM_MODEL:-gemma3-local}"
export LLM_API_KEY="${LLM_API_KEY:-local}"
export AGENT_PID_FILE="${AGENT_PID_FILE:-/tmp/agent.pid}"
# Nuevos en v13.0 (opcionales, tienen default en el servidor)
export AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-15}"
export AGENT_GOAL_TIMEOUT="${AGENT_GOAL_TIMEOUT:-600}"

PY=/usr/bin/python3
[ -x /usr/local/bin/python3 ] && PY=/usr/local/bin/python3

echo "[XTR] Instalando dependencias criticas..."
$PY -m pip install --quiet --no-input fastapi uvicorn pydantic httpx 2>/dev/null || \
$PY -m pip install --quiet --no-input --break-system-packages fastapi uvicorn pydantic httpx

# sqlite3 es stdlib en python3, pero aseguramos el directorio de memoria
mkdir -p /root/agent_memory/logs

# Si ya hay un agente corriendo, lo matamos
if [ -f "$AGENT_PID_FILE" ]; then
  OLD_PID=$(cat "$AGENT_PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[XTR] Agente anterior (pid $OLD_PID) detectado, reiniciando..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
fi

echo "[XTR] Arrancando agent-server v13.0 en puerto $AGENT_PORT..."
nohup $PY /root/agent_server.py > /tmp/agent_server.log 2>&1 &
echo $! > "$AGENT_PID_FILE"

sleep 2
if kill -0 "$(cat $AGENT_PID_FILE)" 2>/dev/null; then
  echo "[XTR] Agente corriendo (pid $(cat $AGENT_PID_FILE)) — http://127.0.0.1:$AGENT_PORT"
  curl -s http://127.0.0.1:$AGENT_PORT/health || true
else
  echo "[XTR] ERROR: el agente no arranco. Log:"
  tail -20 /tmp/agent_server.log
  exit 1
fi
