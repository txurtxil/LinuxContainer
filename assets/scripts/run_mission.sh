#!/bin/bash
# Motor generico de misiones. El modelo SOLO responde a una comprobacion;
# nunca escribe su propio estado -- eso lo hace este script con sed,
# evitando el fallo detectado esta noche (el modelo razonaba bien pero
# fallaba al componer la llamada a write_file directamente).
#
# La condicion de parada compara NUMEROS (ej. "menor de 80" contra un
# porcentaje detectado en la respuesta), no frases textuales -- una
# version anterior que buscaba coincidencia de texto ("por debajo")
# fallaba porque el modelo no siempre repetia las palabras exactas
# esperadas, aunque el dato numerico si fuera correcto.
#
# Formato de /root/mision_actual.md:
#   Estado: ACTIVA | COMPLETADA
#   Tarea: <instruccion para el agente, debe responder con un numero+%>
#   Condicion de parada: <texto con un numero, ej "menor de 80">
#   Ciclos maximo: <entero, red de seguridad>
#   Ciclos hechos: <entero, gestionado por este script>
#
# Pensado para cron: */15 * * * * /root/run_mission.sh
MISSION_FILE="/root/mision_actual.md"
LOGFILE="/root/mission_log.txt"

if [ ! -f "$MISSION_FILE" ]; then exit 0; fi
if grep -q "^Estado: COMPLETADA" "$MISSION_FILE"; then exit 0; fi

TAREA=$(grep "^Tarea:" "$MISSION_FILE" | sed 's/^Tarea: *//')
CONDICION=$(grep "^Condicion de parada:" "$MISSION_FILE" | sed 's/^Condicion de parada: *//')
CICLOS_MAX=$(grep "^Ciclos maximo:" "$MISSION_FILE" | sed 's/^Ciclos maximo: *//')
CICLOS_HECHOS=$(grep "^Ciclos hechos:" "$MISSION_FILE" | sed 's/^Ciclos hechos: *//')

RESPONSE=$(curl -s -X POST http://127.0.0.1:8765/run \
  -H "Content-Type: application/json" \
  -d "{\"task\": \"$TAREA\", \"llm_base_url\": \"http://127.0.0.1:8090/v1\", \"llm_model\": \"gemma3-local\", \"llm_api_key\": \"local\"}" \
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
[ -z "$ANSWER" ] && ANSWER="(sin respuesta -- revisa agent-server y GPU)"

NUEVO_CICLOS=$((CICLOS_HECHOS + 1))
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Ciclo $NUEVO_CICLOS: $ANSWER" >> "$LOGFILE"
sed -i "s/^Ciclos hechos:.*/Ciclos hechos: $NUEVO_CICLOS/" "$MISSION_FILE"

PORCENTAJE=$(echo "$ANSWER" | grep -oE "[0-9]+%" | head -1 | tr -d "%")
UMBRAL=$(echo "$CONDICION" | grep -oE "[0-9]+")
CONDICION_OK=0
if [ -n "$PORCENTAJE" ] && [ -n "$UMBRAL" ] && [ "$PORCENTAJE" -lt "$UMBRAL" ]; then
    CONDICION_OK=1
fi
if [ "$CONDICION_OK" = "1" ]; then
    sed -i "s/^Estado:.*/Estado: COMPLETADA/" "$MISSION_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Condicion de parada detectada. Mision completada." >> "$LOGFILE"
elif [ "$NUEVO_CICLOS" -ge "$CICLOS_MAX" ]; then
    sed -i "s/^Estado:.*/Estado: COMPLETADA (limite de ciclos)/" "$MISSION_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Limite de ciclos alcanzado. Mision detenida." >> "$LOGFILE"
fi
