#!/bin/bash
set -e

echo "Fix pubspec dependencies"

cat > pubspec.yaml << 'EOF2'
name: linuxcontainer
description: Linux Container App
publish_to: none

environment:
  sdk: ">=3.3.0 <4.0.0"

dependencies:
  flutter:
    sdk: flutter

  provider: ^6.1.2
  path_provider: ^2.1.4
  archive: ^3.6.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0

flutter:
  uses-material-design: true
EOF2

flutter clean
flutter pub get

echo "Pub fixed"
