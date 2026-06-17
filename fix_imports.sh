#!/bin/bash
set -e

echo "Fixing missing imports"

find lib -name "*.dart" -type f | while read f; do
  # provider watch fix
  if grep -q "context.watch<" "$f"; then
    grep -q "package:provider/provider.dart" "$f" || \
    sed -i "1i import 'package:provider/provider.dart';" "$f"
  fi

  # archive usage fix
  if grep -q "ZipDecoder\\|TarDecoder\\|GZipDecoder" "$f"; then
    grep -q "package:archive/archive.dart" "$f" || \
    sed -i "1i import 'package:archive/archive.dart';" "$f"
  fi

  # path_provider fix
  if grep -q "getApplicationDocumentsDirectory" "$f"; then
    grep -q "package:path_provider/path_provider.dart" "$f" || \
    sed -i "1i import 'package:path_provider/path_provider.dart';" "$f"
  fi
done

echo "Imports fixed"
