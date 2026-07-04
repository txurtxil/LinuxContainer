#!/bin/bash
# Genera un diagrama de topologia de red en PNG usando Graphviz.
# El modelo NUNCA compone sintaxis DOT directamente -- solo escribe
# una lista simple "Nombre:IP;Nombre:IP;..." y este script construye
# el grafo real. Evita el fallo visto en produccion: pedirle a un
# modelo pequeno que componga DOT + escapado de bash a la vez producia
# generaciones truncadas/corruptas (ej. "PIENFIN" por corte a media
# generacion intentando una linea demasiado larga y anidada).
#
# Uso: bash gen_topologia.sh <fichero_dispositivos> <salida.dot> <salida.png>
# Formato de <fichero_dispositivos>: una linea "Nombre:IP;Nombre:IP;..."
#
# Requiere: apt install graphviz
INPUT="$1"
DOTFILE="$2"
PNGFILE="$3"

if [ ! -f "$INPUT" ]; then
    echo "Error: no existe $INPUT"
    exit 1
fi

CONTENT=$(cat "$INPUT")

{
    echo 'digraph red {'
    echo '    rankdir=LR;'
    echo '    node [shape=box, style=filled, fillcolor=lightblue];'
    echo '    router [label="Router", shape=diamond, fillcolor=orange];'
    i=0
    IFS=';' read -ra DISPOSITIVOS <<< "$CONTENT"
    for d in "${DISPOSITIVOS[@]}"; do
        nombre="${d%%:*}"
        ip="${d#*:}"
        i=$((i+1))
        echo "    d$i [label=\"$nombre\\n$ip\"];"
        echo "    router -> d$i;"
    done
    echo '}'
} > "$DOTFILE"

dot -Tpng "$DOTFILE" -o "$PNGFILE"
