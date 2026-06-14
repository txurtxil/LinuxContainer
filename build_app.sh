#!/bin/bash
# ============================================================================
# Linux Container App - Master Build Script
# Proot-based Linux distro + Terminal + SSH + Networking + OpenCloud
# ============================================================================
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "========================================"
echo " Linux Container App - Builder"
echo "========================================"

# ---------------------------------------------------------------------------
# 1. Update pubspec.yaml with dependencies
# ---------------------------------------------------------------------------
echo "[1/6] Updating pubspec.yaml..."
cat > pubspec.yaml << 'YAML'
name: linux_container_app
description: "Terminal Linux - Proot + SSH + Networking + OpenCloud"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.6.1

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  path_provider: ^2.1.3
  shared_preferences: ^2.3.3
  provider: ^6.1.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
YAML

# ---------------------------------------------------------------------------
# 2. Create all Dart source files
# ---------------------------------------------------------------------------
echo "[2/6] Creating Dart source files..."

mkdir -p lib/models lib/services lib/widgets lib/screens
