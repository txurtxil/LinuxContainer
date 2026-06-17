#!/bin/bash
set -e

FILE="lib/services/proot_service.dart"

echo "Hard fixing archive symlinks compatibility"

# reemplazo completo de symbolicLink logic por skip seguro

perl -0777 -i -pe '
s/if\s*\(e\.isSymbolicLink.*?\{.*?\}/if (e.isSymbolicLink) { continue; }/gs;
s/e\.symbolicLink\s*\!\s*//g;
s/e\.symbolicLink\s*\?://" "/g;
' "$FILE"

echo "Done"
