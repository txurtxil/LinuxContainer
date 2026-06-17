#!/bin/bash
set -e

FILE="lib/services/proot_service.dart"

echo "Fixing archive API compatibility"

# Eliminar uso de symbolicLink inexistente y reemplazar lógica

sed -i 's/e\.symbolicLink/""/g' "$FILE"

echo "Archive symbolicLink patched"
