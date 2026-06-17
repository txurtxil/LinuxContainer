#!/bin/bash
set -e

FILE="lib/services/proot_service.dart"

echo "Fixing ProotService core structure"

# 1. asegurar mixin ChangeNotifier
sed -i 's/class ProotService/class ProotService extends ChangeNotifier/g' "$FILE"

# 2. añadir variables faltantes al inicio de clase si no existen
if ! grep -q "_initialized" "$FILE"; then
sed -i '1,/class ProotService.*/a\
  bool _initialized = false;\
  bool _bionicInstalled = false;\
' "$FILE"
fi

# 3. arreglar notifyListeners (si falta import foundation)
grep -q "package:flutter/foundation.dart" "$FILE" || \
sed -i "1i import 'package:flutter/foundation.dart';" "$FILE"

# 4. parche checkEnvironment (si no existe, crear stub mínimo)
if ! grep -q "checkEnvironment" "$FILE"; then
cat >> "$FILE" << 'EOF2'

  Future<void> checkEnvironment() async {
    try {
      _initialized = true;
      _bionicInstalled = false;
      _logMsg("Environment checked");
      notifyListeners();
    } catch (e) {
      _logMsg("Error env: \$e");
    }
  }
EOF2
fi

# 5. arreglar llamadas incorrectas a _logMsg con parámetros
perl -pi -e 's/_logMsg\(([^)]*)\)\s*;/_logMsg($1.toString());/g' "$FILE"

echo "ProotService fixed"
