#!/bin/bash
# Comprobacion diaria de salud de un servidor remoto via ssh_exec.
# Pensado para cron: 0 8 * * * /root/run_scheduled_task.sh
LOGFILE="/root/scheduled_reports.log"
TASK="Usa ssh_exec para conectarte a txurtxil@192.168.10.2. Comprueba memoria (free -m), carga (cat /proc/loadavg) y disco (df -h /). Dame un resumen breve de una linea."

RESPONSE=$(curl -s -X POST http://127.0.0.1:8765/run \
  -H "Content-Type: application/json" \
  -d "{\"task\": \"$TASK\", \"llm_base_url\": \"http://127.0.0.1:8090/v1\", \"llm_model\": \"gemma3-local\", \"llm_api_key\": \"local\"}" \
  --no-buffer)

ANSWER=$(echo "$RESPONSE" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line.startswith('data:'):
        try:
            obj = json.loads(line[5:].strip())
            if obj.get('type') == 'final':
                print(obj.get('answer', ''))
        except Exception:
            pass
")

if [ -z "$ANSWER" ]; then
    ANSWER="(sin respuesta -- revisa si agent-server y el modelo GPU estan activos)"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] $ANSWER" >> "$LOGFILE"
