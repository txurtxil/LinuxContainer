#!/bin/bash
# Genera un diagrama de flujo secuencial (Graphviz). El modelo NUNCA
# compone sintaxis DOT: solo escribe "Paso1;Paso2;Paso3" en una linea.
# Uso: bash gen_flujo.sh <fichero_pasos> <salida.dot> <salida.png>
INPUT="$1"
DOTFILE="$2"
PNGFILE="$3"
if [ ! -f "$INPUT" ]; then
    echo "Error: no existe $INPUT"
    exit 1
fi
CONTENT=$(cat "$INPUT")
{
    echo 'digraph flujo {'
    echo '    rankdir=TB;'
    echo '    node [shape=box, style="filled,rounded", fillcolor=lightyellow];'
    i=0
    prev=""
    IFS=';' read -ra PASOS <<< "$CONTENT"
    for p in "${PASOS[@]}"; do
        i=$((i+1))
        echo "    p$i [label=\"$p\"];"
        if [ -n "$prev" ]; then
            echo "    $prev -> p$i;"
        fi
        prev="p$i"
    done
    echo '}'
} > "$DOTFILE"
dot -Tpng "$DOTFILE" -o "$PNGFILE"
