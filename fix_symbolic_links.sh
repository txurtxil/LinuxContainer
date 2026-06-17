#!/bin/bash
set -e

FILE="lib/services/proot_service.dart"

echo "Removing invalid ArchiveFile.symbolicLink usage"

# 1. elimina cualquier uso de symbolicLink en líneas de extracción
perl -0777 -i -pe '
s/ArchiveFile.*symbolicLink.*?;/ /gs;
s/e\.symbolicLink.*?(\)|;)/""/g;
' "$FILE"

# 2. parche seguro: elimina manejo de symlinks (compatibilidad archive 3.x)
perl -0777 -i -pe '
s/if\s*\(e\.isSymbolicLink.*?\{.*?\}/if (e.isSymbolicLink) { continue; }/gs;
' "$FILE"

echo "OK"
