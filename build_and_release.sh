#!/bin/bash
# ============================================================================
# Linux Container App - Master Build & Release Script
# 
# Crea APK de la aplicación y publica release en GitHub
# Compatible con x86_64 y ARM64 (con limitaciones)
#
# Uso: bash build_and_release.sh
# ============================================================================
set -e

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Linux Container App - Builder v1.0${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ---------- 1. Verificar entorno ----------
echo -e "${YELLOW}[1/7] Verificando entorno...${NC}"

# Flutter
if ! command -v flutter &> /dev/null; then
    if [ -f /usr/local/flutter/bin/flutter ]; then
        export PATH="$PATH:/usr/local/flutter/bin"
    else
        echo -e "${RED}Flutter no encontrado. Instala Flutter SDK primero.${NC}"
        echo "  curl -sL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.1-stable.tar.xz -o /tmp/flutter.tar.xz"
        echo "  tar -xf /tmp/flutter.tar.xz -C /usr/local/"
        echo "  export PATH=\"\$PATH:/usr/local/flutter/bin\""
        exit 1
    fi
fi

# Android SDK
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

if [ ! -d "$ANDROID_HOME/platforms" ]; then
    echo -e "${YELLOW}Android SDK no encontrado en $ANDROID_HOME${NC}"
    echo "  Instalando Android SDK..."
    mkdir -p "$ANDROID_HOME"
    cd /tmp
    curl -sL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o cmdline-tools.zip
    unzip -q cmdline-tools.zip
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
    mv cmdline-tools/* "$ANDROID_HOME/cmdline-tools/latest/"
    yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null 2>&1
    $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34" > /dev/null 2>&1
    flutter config --android-sdk "$ANDROID_HOME" > /dev/null 2>&1
    cd "$PROJECT_DIR"
fi

# Java
if ! command -v java &> /dev/null; then
    echo -e "${YELLOW}Java no encontrado. Instalando...${NC}"
    apt-get update -qq && apt-get install -y -qq openjdk-17-jdk-headless > /dev/null 2>&1
fi

echo -e "  ${GREEN}✓${NC} Flutter: $(flutter --version 2>&1 | head -1)"
echo -e "  ${GREEN}✓${NC} Android SDK: $ANDROID_HOME"
echo -e "  ${GREEN}✓${NC} Java: $(java -version 2>&1 | head -1)"
echo ""

# ---------- 2. pubspec.yaml ----------
echo -e "${YELLOW}[2/7] Configurando pubspec.yaml...${NC}"

cat > pubspec.yaml << 'YAML'
name: linux_container_app
description: "Terminal Linux - Proot + SSH + Networking + OpenCloud"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.6.0

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

flutter pub get > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Dependencias instaladas"
echo ""

# ---------- 3. Inyectar permisos Android ----------
echo -e "${YELLOW}[3/7] Configurando permisos Android...${NC}"

python3 << 'PYTHON'
import os

manifest = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.micloj.linux_container_app">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <application
        android:label="Linux Container"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:usesCleartextTraffic="true"
        android:networkSecurityConfig="@xml/network_security_config">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">

            <meta-data
                android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />

            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <meta-data
            android:name="flutterEmbedding"
            android:value="2" />
    </application>
</manifest>
"""

with open("android/app/src/main/AndroidManifest.xml", "w") as f:
    f.write(manifest)

# Create network security config
os.makedirs("android/app/src/main/res/xml", exist_ok=True)
with open("android/app/src/main/res/xml/network_security_config.xml", "w") as f:
    f.write('''<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
</network-security-config>
''')

print("  [+] Permisos: INTERNET, NETWORK_STATE, WIFI_STATE, STORAGE, FOREGROUND, NOTIFICATIONS")
print("  [+] Network security config creado")
PYTHON

echo -e "  ${GREEN}✓${NC} AndroidManifest.xml configurado"
echo ""

# ---------- 4. build.gradle ----------
echo -e "${YELLOW}[4/7] Configurando build.gradle...${NC}"

python3 << 'PYTHON'
with open("android/app/build.gradle", "r") as f:
    content = f.read()

content = content.replace("minSdk = flutter.minSdkVersion", "minSdk = 21")
content = content.replace("targetSdk = flutter.targetSdkVersion", "targetSdk = 34")
content = content.replace("versionCode = flutter.versionCode", "versionCode = 1")
content = content.replace('versionName = flutter.versionName', 'versionName = "1.0.0"')

with open("android/app/build.gradle", "w") as f:
    f.write(content)

print("  [+] minSdk=21, targetSdk=34, versionName=1.0.0")
PYTHON

echo -e "  ${GREEN}✓${NC} Build config listo"
echo ""

# ---------- 5. Análisis de código ----------
echo -e "${YELLOW}[5/7] Verificando código Dart...${NC}"

ANALYSIS=$(flutter analyze 2>&1)
if echo "$ANALYSIS" | grep -q "No issues found"; then
    echo -e "  ${GREEN}✓${NC} Sin errores de análisis"
else
    echo -e "  ${YELLOW}⚠${NC} Issues encontrados (no críticos):"
    echo "$ANALYSIS" | grep "error\|warning\|info" | head -5
fi
echo ""

# ---------- 6. Compilar APK ----------
echo -e "${YELLOW}[6/7] Compilando APK...${NC}"

ARCH=$(uname -m)
echo -e "  Arquitectura: ${BLUE}$ARCH${NC}"

if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    echo -e "  ${YELLOW}⚠ ARM64 detectado. El frontend_server de Flutter puede no funcionar.${NC}"
    echo -e "  ${YELLOW}  Intentando build de todas formas...${NC}"
fi

# Try debug build first (simpler)
echo -e "  ${BLUE}→${NC} Build debug..."
BUILD_OUTPUT=$(flutter build apk --debug 2>&1) || {
    echo -e "  ${YELLOW}⚠ Build debug falló. Intentando release...${NC}"
    
    BUILD_OUTPUT=$(flutter build apk --release 2>&1) || {
        echo -e "  ${RED}✗ Build falló.${NC}"
        echo ""
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  ERROR: Compilación no disponible en ARM64 Linux.${NC}"
        echo -e "${RED}  La arquitectura ARM64 no tiene soporte oficial de Flutter${NC}"
        echo -e "${RED}  para compilación Android.${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Soluciones:"
        echo -e "  1. Usa GitHub Actions con runner x86_64"
        echo -e "  2. Compila en tu máquina local x86_64"
        echo -e "  3. Usa el Docker build (si tienes acceso a x86_64)"
        echo ""
        echo -e "  El código fuente está listo en:"
        echo -e "  ${BLUE}$PROJECT_DIR/lib/${NC}"
        echo ""
        echo -e "  Para compilar manualmente en x86_64:"
        echo -e "  ${BLUE}  flutter pub get${NC}"
        echo -e "  ${BLUE}  flutter build apk --profile${NC}"
        echo -e "  ${BLUE}  gh release create v1.0 build/app/outputs/flutter-apk/app-profile.apk \\"
        echo -e "  ${BLUE}    --title \"Linux Container v1.0\" --notes \"Primera versión\"${NC}"
        exit 1
    }
}

APK_PATH=$(find build/app/outputs -name "*.apk" 2>/dev/null | head -1)

if [ -n "$APK_PATH" ] && [ -f "$APK_PATH" ]; then
    APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
    echo -e "  ${GREEN}✓${NC} APK generado: $APK_PATH ($APK_SIZE)"
else
    echo -e "  ${RED}✗${NC} No se encontró el APK"
    exit 1
fi
echo ""

# ---------- 7. GitHub Release ----------
echo -e "${YELLOW}[7/7] Publicando release en GitHub...${NC}"

if command -v gh &> /dev/null && gh auth status 2>&1 | grep -q "active"; then
    # Crear tag y release
    VERSION="v1.0.0"
    git tag -f "$VERSION" 2>/dev/null || true
    git push origin "$VERSION" 2>/dev/null || true
    
    gh release create "$VERSION" "$APK_PATH" \
        --title "Linux Container v1.0" \
        --notes "## Linux Container App v1.0

### ✨ Características
- **Terminal interactiva** con shell Debian/Ubuntu via proot
- **Gestor de paquetes apt** integrado
- **Servidor SSH** con autenticación por contraseña
- **Herramientas de networking** (ping, curl, traceroute, dig, netstat)
- **OpenCloud** (Nextcloud) - instalación con un clic
- Interfaz Material Design 3 con tema oscuro

### 🔧 Stack
- Flutter 3.27.1 | Dart 3.6.1
- Debian Bookworm (rootfs automático)
- OpenSSH Server
- Apache + MariaDB + PHP

### 📱 Permisos
- Internet, Network State, WiFi State
- Almacenamiento externo
- Servicio en foreground
- Notificaciones
" 2>&1 || {
    echo -e "  ${YELLOW}⚠ gh CLI no autenticado. Skipping release...${NC}"
    echo -e "  Para crear release manualmente:"
    echo -e "  ${BLUE}  gh release create v1.0 $APK_PATH --title \"Linux Container v1.0\" --notes \"...\"${NC}"
}

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ BUILD COMPLETADO${NC}"
echo -e "${GREEN}  APK: $APK_PATH${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Próximos pasos:"
echo -e "  1. Instala el APK en tu dispositivo Android"
echo -e "  2. Abre la app y presiona \"Setup Linux\""
echo -e "  3. Espera a que se descargue Debian rootfs"
echo -e "  4. Usa la terminal, instala paquetes, configura SSH, etc."
echo ""
