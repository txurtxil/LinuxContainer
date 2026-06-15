#!/bin/bash
set -e
echo "Linux Container App v2.0 - Build & Release"
echo ""

# 1. Dependencies
if ! command -v flutter &>/dev/null; then
    echo "Instalando Flutter..."
    cd /opt
    curl -sL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.1-stable.tar.xz -o /tmp/fl.tar.xz
    tar -xf /tmp/fl.tar.xz -C /opt/
    export PATH="/opt/flutter/bin:$PATH"
fi
export ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
if [ ! -d "$ANDROID_HOME/platforms" ]; then
    echo "Instalando Android SDK..."
    mkdir -p "$ANDROID_HOME"
    cd /tmp
    curl -sL "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -o ct.zip
    unzip -qo ct.zip
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
    mv cmdline-tools/* "$ANDROID_HOME/cmdline-tools/latest/" 2>/dev/null || true
    yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null 2>&1 || true
    $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager "platform-tools" "build-tools;34.0.0" "platforms;android-34"
fi

if ! command -v java &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq openjdk-17-jdk-headless
fi

# 2. pub get
flutter pub get

# 3. Build
echo "Compilando APK..."
flutter build apk --release || flutter build apk --debug

APK=$(find build/app/outputs -name "*.apk" 2>/dev/null | head -1)
if [ -z "$APK" ]; then echo "ERROR: No se generó APK"; exit 1; fi
echo "APK: $APK ($(du -h "$APK" | cut -f1))"

# 4. GitHub Release
if command -v gh &>/dev/null && gh auth status 2>&1 | grep -q "active"; then
    VERSION="v2.0.0"
    git tag -f "$VERSION" 2>/dev/null || true
    git push origin "$VERSION" 2>/dev/null || true
    gh release create "$VERSION" "$APK" \
        --title "Linux Container v2.0" \
        --notes "## Linux Container v2.0
Correcciones: extraccion rootfs, proot URL, symlinks/hardlinks, CI/CD"
    echo "Release publicada!"
else
    echo "gh no autenticado. Publica manualmente:"
    echo "gh release create v2.0 $APK --title 'Linux Container v2.0' --notes '...'"
fi
