#!/bin/bash
# PROTOTIPO validado: continua una "mision" activa cada vez que cron lo
# dispara, hasta que el propio fichero marque Estado: COMPLETADA.
#
# AVISO: la tarea de este script esta hoy hardcodeada a un ejemplo de
# prueba (contar hasta 5). La version generica "lee el Proximo paso y
# decide tu mismo que hacer" fallaba: el modelo razonaba bien pero no
# siempre llegaba a llamar a write_file de verdad. Antes de reutilizar
# esto para una mision real, hay que generalizar el TASK de abajo dando
# plantillas exactas de write_file (como aqui), no pidiendole al modelo
# que las componga libremente.
#
# Pensado para cron: */15 * * * * /root/run_mission.sh
MISSION_FILE="/root/mision_actual.md"
LOGFILE="/root/mission_log.txt"

if [ ! -f "$MISSION_FILE" ]; then
    exit 0
fi
if grep -q "^Estado: COMPLETADA" "$MISSION_FILE"; then
    exit 0
fi

TASK="Lee /root/mision_actual.md con read_file para ver el Contador actual. Suma 1 a ese numero. Si el resultado es 5 o mas, usa write_file con este argumento exacto (sustituyendo NADA salvo escribir 5 donde corresponde): /root/mision_actual.md|||Estado: COMPLETADA. Contador actual: 5. Mision terminada. Si el resultado es menor que 5, usa write_file con este argumento exacto, sustituyendo NUEVO por el numero resultante: /root/mision_actual.md|||Estado: ACTIVA. Contador actual: NUEVO. Proximo paso: sumar 1. Usa write_file de verdad, no te limites a decir que lo harias."

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
    ANSWER="(sin respuesta -- revisa agent-server y GPU)"
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] $ANSWER" >> "$LOGFILE"
