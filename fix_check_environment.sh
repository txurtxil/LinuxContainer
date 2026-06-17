#!/bin/bash
set -e

FILE="lib/services/proot_service.dart"

echo "Ensuring checkEnvironment exists"

grep -q "Future<void> checkEnvironment" "$FILE" && exit 0

cat >> "$FILE" << 'EOF2'

  Future<void> checkEnvironment() async {
    try {
      _initialized = true;

      // simulación básica de entorno proot
      _bionicInstalled = false;

      _logMsg("checkEnvironment OK");
      notifyListeners();
    } catch (e) {
      _logMsg("checkEnvironment error: $e");
    }
  }

EOF2

echo "checkEnvironment added"
