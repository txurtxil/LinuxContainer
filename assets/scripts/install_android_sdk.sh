#!/bin/bash
# XTR Terminal — Entorno de desarrollo Android (aarch64)
#
# Instala un SDK de Android funcional dentro del rootfs Debian arm64,
# parcheando los binarios nativos que Google solo publica para x86_64.
#
#   install_android_sdk.sh              instalación base
#   install_android_sdk.sh --flutter    + SDK de Flutter (compila desde fuente, MUY lento)
#   install_android_sdk.sh --kotlin     + compilador Kotlin standalone
#   install_android_sdk.sh --code       + code-server
#   install_android_sdk.sh --test       solo el test de humo
#   install_android_sdk.sh --uninstall  revierte todo
#
# Idempotente: se puede relanzar sin miedo.

set -o pipefail

# ══════════════════════════════════════════════════════════════
#  VARIABLES — actualiza aquí cuando salgan versiones nuevas
# ══════════════════════════════════════════════════════════════

# cmdline-tools de Google (Java puro → corre en aarch64 sin parchear).
# El número es el build id; míralo en https://developer.android.com/studio
CMDLINE_TOOLS_BUILD="14742923"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"

# Paquetes que instala sdkmanager.
ANDROID_PLATFORM="android-35"
BUILD_TOOLS_VER="35.0.0"

# Binarios nativos aarch64 (lzhiyong). OJO: la versión NO coincide con
# BUILD_TOOLS_VER — es lo esperado, no hay release 35.0.0.
# https://github.com/lzhiyong/android-sdk-tools/releases
NATIVE_TOOLS_VER="35.0.2"
NATIVE_TOOLS_URL="https://github.com/lzhiyong/android-sdk-tools/releases/download/${NATIVE_TOOLS_VER}/android-sdk-tools-static-aarch64.zip"

# Gradle. NO usamos el de apt: Bookworm trae 4.4.1, inservible con AGP 8.x.
GRADLE_VER="8.9"
GRADLE_URL="https://services.gradle.org/distributions/gradle-${GRADLE_VER}-bin.zip"

# Combo del proyecto de prueba. AGP 8.7.x ↔ Gradle 8.9 ↔ compileSdk 35.
AGP_VER="8.7.3"
KOTLIN_VER="2.0.21"

# Rutas
ANDROID_HOME="/opt/android-sdk"
GRADLE_HOME="/opt/gradle"
JAVA_HOME_PATH="/usr/lib/jvm/java-17-openjdk-arm64"
PROFILE_D="/etc/profile.d/android-sdk.sh"
LOG_DIR="/var/log/linuxcontainer"
LOG_FILE="$LOG_DIR/android-sdk.log"
SMOKE_DIR="/tmp/hello-android"

MIN_FREE_GB=8
MIN_RAM_MB=3000

# ══════════════════════════════════════════════════════════════
#  Formato — mismos códigos que lc-menu.sh
# ══════════════════════════════════════════════════════════════
C_RESET='\e[0m'; C_B='\e[1m'; C_DIM='\e[2m'
C_GRN='\e[1;32m'; C_YEL='\e[1;33m'; C_RED='\e[1;31m'
C_CYN='\e[1;36m'; C_MAG='\e[1;35m'

PHASE_TOTAL=8
PHASE_N=0

hr() { echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"; }

# Marcador que parsea la UI Flutter para la barra de progreso.
# Formato: ::PHASE::<n>::<total>::<mensaje>
phase() {
  PHASE_N=$((PHASE_N + 1))
  echo "::PHASE::${PHASE_N}::${PHASE_TOTAL}::$1"
  echo -e "${C_CYN}▸ [${PHASE_N}/${PHASE_TOTAL}] $1${C_RESET}"
}
info() { echo -e "  ${C_DIM}$1${C_RESET}"; }
ok()   { echo -e "${C_GRN}✓ $1${C_RESET}"; }
warn() { echo -e "${C_YEL}! $1${C_RESET}"; }
die()  { echo -e "${C_RED}✗ $1${C_RESET}"; echo "::FAIL::$1"; exit 1; }

header() {
  echo -e "${C_GRN}╔════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GRN}║${C_RESET}  ${C_B}${C_GRN}XTR Terminal${C_RESET} ${C_DIM}·${C_RESET} ${C_B}Android SDK / Dev${C_RESET}     ${C_GRN}║${C_RESET}"
  echo -e "${C_GRN}╚════════════════════════════════════════╝${C_RESET}"
}

mkdir -p "$LOG_DIR" 2>/dev/null
# Todo a consola y a log, sin códigos de color en el fichero.
exec > >(tee >(sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE")) 2>&1
echo "===== $(date '+%F %T') — $* =====" >> "$LOG_FILE"

# ══════════════════════════════════════════════════════════════
#  Flags
# ══════════════════════════════════════════════════════════════
WANT_FLUTTER=0; WANT_KOTLIN=0; WANT_CODE=0
MODE="install"

for arg in "$@"; do
  case "$arg" in
    --flutter)   WANT_FLUTTER=1; PHASE_TOTAL=$((PHASE_TOTAL + 1)) ;;
    --kotlin)    WANT_KOTLIN=1;  PHASE_TOTAL=$((PHASE_TOTAL + 1)) ;;
    --code)      WANT_CODE=1;    PHASE_TOTAL=$((PHASE_TOTAL + 1)) ;;
    --uninstall) MODE="uninstall" ;;
    --test)      MODE="test" ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           die "Flag desconocido: $arg" ;;
  esac
done

# ══════════════════════════════════════════════════════════════
#  DESINSTALAR
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "uninstall" ]; then
  header
  echo -e "  ${C_MAG}❯ Desinstalar entorno Android${C_RESET}"
  hr
  info "Se borrarán: $ANDROID_HOME, $GRADLE_HOME, $PROFILE_D,"
  info "~/.gradle, ~/.android, $SMOKE_DIR, /opt/flutter, /opt/kotlinc"
  info "Los paquetes apt (JDK, git...) NO se tocan."
  echo ""
  read -rp "$(echo -e "  ¿Seguro? ${C_YEL}[s/N]${C_RESET} ")" c
  [[ "$c" != "s" && "$c" != "S" ]] && { echo "Cancelado."; exit 0; }

  for p in "$ANDROID_HOME" "$GRADLE_HOME" "$PROFILE_D" "$HOME/.gradle" \
           "$HOME/.android" "$SMOKE_DIR" /opt/flutter /opt/kotlinc \
           /usr/local/bin/gradle /usr/local/bin/kotlinc; do
    if [ -e "$p" ]; then rm -rf "$p" && ok "borrado $p"; fi
  done
  command -v code-server >/dev/null && { npm uninstall -g code-server 2>/dev/null; ok "code-server fuera"; }
  echo ""
  ok "Entorno revertido. Abre una terminal nueva para limpiar el PATH."
  exit 0
fi

# ══════════════════════════════════════════════════════════════
#  1. Comprobaciones previas
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "install" ]; then
header
echo ""
phase "Comprobando el sistema"

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  die "Arquitectura no soportada: $ARCH

  Este instalador solo funciona en aarch64 (arm64). El parche de
  binarios nativos (aapt2/aapt/zipalign) que hace viable compilar
  APKs aquí solo existe para aarch64.
  En x86_64 usa el SDK oficial de Google, que ya funciona tal cual."
fi
ok "Arquitectura aarch64"

# Espacio libre en /opt (o donde caiga la partición)
FREE_KB=$(df -Pk /opt 2>/dev/null | awk 'NR==2{print $4}')
[ -z "$FREE_KB" ] && FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
FREE_GB=$((FREE_KB / 1024 / 1024))
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
  die "Espacio insuficiente: ${FREE_GB} GB libres, hacen falta ${MIN_FREE_GB} GB."
fi
ok "Espacio libre: ${FREE_GB} GB"

RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "$RAM_MB" -lt "$MIN_RAM_MB" ]; then
  warn "RAM: ${RAM_MB} MB — por debajo de ${MIN_RAM_MB} MB recomendados."
  warn "Gradle puede morir con OOM. Baja -Xmx en ~/.gradle/gradle.properties."
else
  ok "RAM: ${RAM_MB} MB"
fi

# DNS (mismo fix que lc-menu)
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
ok "DNS configurado"

# ══════════════════════════════════════════════════════════════
#  2. Paquetes apt
# ══════════════════════════════════════════════════════════════
phase "Instalando paquetes base (apt)"
apt-get update -q 2>&1 | tail -2

# NOTA: 'gradle' NO está en la lista a propósito — Bookworm trae 4.4.1.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --fix-missing \
  openjdk-17-jdk-headless git unzip zip curl wget ca-certificates \
  adb python3 cmake ninja-build 2>&1 | grep -E "^(E:|Setting up)" | tail -8

command -v java >/dev/null || die "java no quedó instalado. Revisa la red y reintenta."
JAVA_REAL="$(readlink -f "$(command -v java)" | sed 's|/bin/java$||')"
[ -d "$JAVA_HOME_PATH" ] || JAVA_HOME_PATH="$JAVA_REAL"
export JAVA_HOME="$JAVA_HOME_PATH"
ok "JDK: $(java -version 2>&1 | head -1)"

# ══════════════════════════════════════════════════════════════
#  3. cmdline-tools
# ══════════════════════════════════════════════════════════════
phase "Descargando cmdline-tools de Google"
export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"

if [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  ok "cmdline-tools ya presentes (saltando)"
else
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  TMP_ZIP="/tmp/cmdline-tools.zip"
  info "$CMDLINE_TOOLS_URL"
  wget -q --show-progress -O "$TMP_ZIP" "$CMDLINE_TOOLS_URL" \
    || die "No se pudo descargar cmdline-tools. ¿Hay WiFi? ¿Build id caducado?"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest" "/tmp/cmdt"
  mkdir -p /tmp/cmdt
  unzip -q -o "$TMP_ZIP" -d /tmp/cmdt || die "Zip de cmdline-tools corrupto."
  # El zip desempaqueta en cmdline-tools/ ; sdkmanager exige .../latest/bin
  mv /tmp/cmdt/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf /tmp/cmdt "$TMP_ZIP"
  [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ] \
    || die "Layout inesperado en el zip de cmdline-tools."
  ok "cmdline-tools $CMDLINE_TOOLS_BUILD en $ANDROID_HOME/cmdline-tools/latest"
fi

SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

# ══════════════════════════════════════════════════════════════
#  4. Paquetes del SDK
# ══════════════════════════════════════════════════════════════
phase "Instalando paquetes del SDK (licencias auto-aceptadas)"
info "platform-tools · platforms;$ANDROID_PLATFORM · build-tools;$BUILD_TOOLS_VER"
info "Son ~700 MB. Paciencia."

yes | "$SDKMANAGER" --licenses > /dev/null 2>&1
yes | "$SDKMANAGER" --install \
  "platform-tools" "platforms;$ANDROID_PLATFORM" "build-tools;$BUILD_TOOLS_VER" \
  2>&1 | grep -viE "^\s*$|Warning: File .* could not be found" | tail -6

BT_DIR="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VER"
[ -d "$BT_DIR" ] || die "build-tools;$BUILD_TOOLS_VER no se instaló. Mira $LOG_FILE."
ok "SDK instalado en $ANDROID_HOME"

# ══════════════════════════════════════════════════════════════
#  5. EL PARCHE — binarios aarch64
# ══════════════════════════════════════════════════════════════
phase "Parcheando binarios nativos a aarch64"
info "Google publica aapt2/aapt/zipalign/adb solo para x86_64."
info "Sustituyéndolos por los de lzhiyong/android-sdk-tools $NATIVE_TOOLS_VER."

NEEDS_PATCH=0
if [ -x "$BT_DIR/aapt2" ]; then
  if file "$BT_DIR/aapt2" 2>/dev/null | grep -q "ARM aarch64"; then
    ok "aapt2 ya es aarch64 (saltando parche)"
  else
    NEEDS_PATCH=1
  fi
else
  NEEDS_PATCH=1
fi

if [ "$NEEDS_PATCH" = "1" ]; then
  TMP_NZ="/tmp/sdk-tools-aarch64.zip"
  rm -rf /tmp/ndktools; mkdir -p /tmp/ndktools
  info "$NATIVE_TOOLS_URL"
  wget -q --show-progress -O "$TMP_NZ" "$NATIVE_TOOLS_URL" \
    || die "No se pudo descargar los binarios aarch64. ¿Cambió la release $NATIVE_TOOLS_VER?"
  unzip -q -o "$TMP_NZ" -d /tmp/ndktools || die "Zip de binarios nativos corrupto."

  # El layout del zip ha cambiado entre releases: buscamos, no asumimos.
  patch_one() {
    local name="$1" dest="$2"
    local src
    src="$(find /tmp/ndktools -type f -name "$name" -perm -u+x 2>/dev/null | head -1)"
    [ -z "$src" ] && src="$(find /tmp/ndktools -type f -name "$name" 2>/dev/null | head -1)"
    if [ -z "$src" ]; then
      warn "$name no encontrado en el zip — se deja el original"
      return 1
    fi
    install -m 755 "$src" "$dest/$name" || return 1
    ok "$name → $dest"
  }

  patch_one aapt2    "$BT_DIR"
  patch_one aapt     "$BT_DIR"
  patch_one zipalign "$BT_DIR"
  # Regalo: el mismo zip trae platform-tools aarch64. El adb de Google es x86_64.
  if [ -d "$ANDROID_HOME/platform-tools" ]; then
    patch_one adb      "$ANDROID_HOME/platform-tools" || true
    patch_one fastboot "$ANDROID_HOME/platform-tools" || true
  fi
  rm -rf /tmp/ndktools "$TMP_NZ"
fi

# --- Verificación, que es lo que importa ---
FILE_OUT="$(file "$BT_DIR/aapt2" 2>/dev/null)"
echo "$FILE_OUT" | grep -q "ELF" || die "aapt2 no es un ELF: $FILE_OUT"
echo "$FILE_OUT" | grep -q "aarch64" \
  || die "aapt2 NO es aarch64 tras el parche:
  $FILE_OUT
  Sin esto la build muere con 'cannot execute binary file'."
ok "file: ELF aarch64"

if AAPT2_OUT="$("$BT_DIR/aapt2" version 2>&1)"; then
  ok "aapt2 responde: $AAPT2_OUT"
else
  die "aapt2 es aarch64 pero no arranca:
  $AAPT2_OUT
  Suele faltar una lib. Prueba: apt-get install -y libc++1 zlib1g"
fi

# ══════════════════════════════════════════════════════════════
#  6. Gradle
# ══════════════════════════════════════════════════════════════
phase "Instalando Gradle $GRADLE_VER"
if [ -x "$GRADLE_HOME/bin/gradle" ] && "$GRADLE_HOME/bin/gradle" -v 2>/dev/null | grep -q "$GRADLE_VER"; then
  ok "Gradle $GRADLE_VER ya instalado"
else
  TMP_GZ="/tmp/gradle.zip"
  wget -q --show-progress -O "$TMP_GZ" "$GRADLE_URL" || die "No se pudo descargar Gradle."
  rm -rf "$GRADLE_HOME" /tmp/gradle-unz; mkdir -p /tmp/gradle-unz
  unzip -q -o "$TMP_GZ" -d /tmp/gradle-unz || die "Zip de Gradle corrupto."
  mv "/tmp/gradle-unz/gradle-${GRADLE_VER}" "$GRADLE_HOME"
  rm -rf /tmp/gradle-unz "$TMP_GZ"
  ln -sf "$GRADLE_HOME/bin/gradle" /usr/local/bin/gradle
  ok "Gradle en $GRADLE_HOME"
fi
fi  # fin MODE=install

# ══════════════════════════════════════════════════════════════
#  7. profile.d + gradle.properties
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "install" ]; then
phase "Escribiendo entorno y configuración de Gradle"

cat > "$PROFILE_D" <<EOF
# Generado por install_android_sdk.sh — no editar a mano
export ANDROID_HOME=$ANDROID_HOME
export ANDROID_SDK_ROOT=$ANDROID_HOME
export JAVA_HOME=$JAVA_HOME_PATH
export GRADLE_HOME=$GRADLE_HOME
# proot no lleva bien native-platform de Gradle: lo desactivamos.
export GRADLE_OPTS="-Dorg.gradle.native=false"
export PATH="\$PATH:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/emulator:\$GRADLE_HOME/bin"
EOF
chmod 644 "$PROFILE_D"
ok "$PROFILE_D"

mkdir -p "$HOME/.gradle"
GP="$HOME/.gradle/gradle.properties"
if [ -f "$GP" ] && ! grep -q "aapt2FromMavenOverride" "$GP"; then
  cp "$GP" "$GP.bak.$(date +%s)"
  warn "gradle.properties existía — copia de seguridad guardada"
fi
cat > "$GP" <<EOF
# Generado por install_android_sdk.sh
# SIN este override, AGP se baja el aapt2 x86_64 de Maven e ignora el
# de build-tools → "cannot execute binary file". Es la línea clave.
android.aapt2FromMavenOverride=$BT_DIR/aapt2

org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g
org.gradle.daemon=false
org.gradle.parallel=true

android.useAndroidX=true
EOF
ok "$GP (aapt2 override apuntando a $BT_DIR/aapt2)"
fi

# ══════════════════════════════════════════════════════════════
#  8. Extras opcionales
# ══════════════════════════════════════════════════════════════
if [ "$WANT_KOTLIN" = "1" ]; then
  phase "Instalando compilador Kotlin"
  if command -v kotlinc >/dev/null; then
    ok "kotlinc ya presente"
  else
    KZ="/tmp/kotlin.zip"
    wget -q --show-progress -O "$KZ" \
      "https://github.com/JetBrains/kotlin/releases/download/v${KOTLIN_VER}/kotlin-compiler-${KOTLIN_VER}.zip" \
      || warn "No se pudo bajar Kotlin $KOTLIN_VER"
    if [ -s "$KZ" ]; then
      unzip -q -o "$KZ" -d /opt && ln -sf /opt/kotlinc/bin/kotlinc /usr/local/bin/kotlinc
      rm -f "$KZ"; ok "kotlinc → /opt/kotlinc (JVM puro, corre nativo en arm64)"
    fi
  fi
fi

if [ "$WANT_CODE" = "1" ]; then
  phase "Instalando code-server"
  if command -v code-server >/dev/null; then
    ok "code-server ya presente"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm 2>&1 | tail -2
    npm install -g code-server 2>&1 | tail -3 || warn "npm falló — reintenta a mano"
    command -v code-server >/dev/null && ok "code-server listo"
  fi
  info "Arrancar:  code-server --bind-addr 127.0.0.1:8443 --auth password"
  info "Abrir en el navegador del móvil: http://127.0.0.1:8443"
  info "La contraseña sale en ~/.config/code-server/config.yaml"
fi

if [ "$WANT_FLUTTER" = "1" ]; then
  phase "Instalando Flutter (arm64 — desde fuente)"
  warn "════════════════════════════════════════════════"
  warn "  Google NO publica Flutter para Linux arm64."
  warn "  Esto clona el repo y compila el motor de Dart."
  warn "  Tarda 40-90 min y puede fallar por RAM en proot."
  warn "  El primer 'flutter doctor' añade otros 10-15 min."
  warn "════════════════════════════════════════════════"
  if [ -d /opt/flutter ]; then
    ok "/opt/flutter ya existe (saltando)"
  else
    git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter \
      || warn "Clone de Flutter falló"
    if [ -d /opt/flutter ]; then
      git config --global --add safe.directory /opt/flutter
      echo 'export PATH="$PATH:/opt/flutter/bin"' >> "$PROFILE_D"
      info "Precachéando (aquí es donde tarda)..."
      /opt/flutter/bin/flutter precache --android 2>&1 | tail -5
      /opt/flutter/bin/flutter config --android-sdk "$ANDROID_HOME" 2>&1 | tail -2
      ok "Flutter en /opt/flutter — comprueba con: flutter doctor"
    fi
  fi
fi

# ══════════════════════════════════════════════════════════════
#  9. Test de humo
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "install" ] || [ "$MODE" = "test" ]; then
[ "$MODE" = "test" ] && { header; PHASE_TOTAL=1; PHASE_N=0; }
phase "Test de humo: compilando un APK de verdad"

export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME" JAVA_HOME="$JAVA_HOME_PATH"
export GRADLE_OPTS="-Dorg.gradle.native=false"
export PATH="$PATH:$GRADLE_HOME/bin:$ANDROID_HOME/platform-tools"
BT_DIR="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VER"

[ -x "$BT_DIR/aapt2" ] || die "No hay SDK instalado. Lanza el instalador sin --test."

rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/app/src/main"

cat > "$SMOKE_DIR/settings.gradle" <<EOF
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "hello-android"
include ":app"
EOF

cat > "$SMOKE_DIR/build.gradle" <<EOF
plugins {
    id "com.android.application" version "$AGP_VER" apply false
}
EOF

cat > "$SMOKE_DIR/gradle.properties" <<EOF
android.aapt2FromMavenOverride=$BT_DIR/aapt2
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g
org.gradle.daemon=false
org.gradle.parallel=true
android.useAndroidX=true
EOF

cat > "$SMOKE_DIR/local.properties" <<EOF
sdk.dir=$ANDROID_HOME
EOF

cat > "$SMOKE_DIR/app/build.gradle" <<EOF
plugins { id "com.android.application" }
android {
    namespace "com.xtr.hello"
    compileSdk 35
    defaultConfig {
        applicationId "com.xtr.hello"
        minSdk 24
        targetSdk 35
        versionCode 1
        versionName "1.0"
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    buildTypes { debug { } }
}
EOF

cat > "$SMOKE_DIR/app/src/main/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:label="Hello XTR" />
</manifest>
EOF

cd "$SMOKE_DIR" || die "No se pudo entrar en $SMOKE_DIR"

info "Generando el wrapper..."
gradle wrapper --gradle-version "$GRADLE_VER" --quiet 2>&1 | tail -3 \
  || die "No se pudo generar el wrapper de Gradle."

info "./gradlew assembleDebug — la primera vez baja dependencias (~5-10 min)"
hr
if ./gradlew assembleDebug --no-daemon --console=plain 2>&1 | tail -25; then
  APK="$SMOKE_DIR/app/build/outputs/apk/debug/app-debug.apk"
  if [ -f "$APK" ]; then
    SZ=$(du -h "$APK" | cut -f1)
    hr
    ok "═══ TEST DE HUMO: OK ═══"
    ok "APK: $APK ($SZ)"
    echo "::RESULT::OK::$APK"
    "$BT_DIR/aapt2" dump badging "$APK" 2>/dev/null | head -2
  else
    die "Gradle terminó con éxito pero no hay APK. Raro. Mira $LOG_FILE."
  fi
else
  hr
  echo -e "${C_RED}✗ ═══ TEST DE HUMO: FALLO ═══${C_RESET}"
  echo "::RESULT::FAIL::"
  warn "Pistas:"
  warn " · 'cannot execute binary file' → el override de aapt2 no se aplicó."
  warn "   Comprueba: grep aapt2 $SMOKE_DIR/gradle.properties"
  warn " · OOM / 'Java heap space' → baja -Xmx3g a -Xmx2g en $GP"
  warn " · Cuelgue en 'Starting daemon' → org.gradle.daemon=false no llegó"
  warn " · Timeouts de red → vuelve a lanzar, Gradle cachea lo ya bajado"
  warn "Log completo: $LOG_FILE"
  exit 1
fi
fi

# ══════════════════════════════════════════════════════════════
#  Cierre
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "install" ]; then
  echo ""
  hr
  ok "Entorno de desarrollo Android listo."
  echo ""
  info "ANDROID_HOME : $ANDROID_HOME"
  info "Gradle       : $GRADLE_VER"
  info "aapt2        : $NATIVE_TOOLS_VER (aarch64, parcheado)"
  info "Log          : $LOG_FILE"
  echo ""
  warn "El emulador NO funciona: no hay KVM dentro de proot."
  warn "Prueba en el propio dispositivo con depuración inalámbrica:"
  warn "  adb connect 127.0.0.1:PUERTO"
  echo ""
  info "Abre una terminal NUEVA para que cargue $PROFILE_D."
  echo "::DONE::"
fi
