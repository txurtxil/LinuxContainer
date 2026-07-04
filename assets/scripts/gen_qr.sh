#!/bin/bash
# Genera un codigo QR a partir de un texto/URL.
# Uso: bash gen_qr.sh "texto o url" <salida.png>
TEXTO="$1"
SALIDA="$2"
qrencode -o "$SALIDA" "$TEXTO"
