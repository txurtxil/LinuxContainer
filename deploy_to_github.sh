#!/bin/bash
set -e

REPO="txurtxil/LinuxContainer"
TOKEN_FILE="/home/txurtxil/githubToken"
APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
VERSION="v12.9" # Control de versión actualizado

if [ ! -f "$TOKEN_FILE" ]; then
    echo "❌ Error: Token no encontrado en $TOKEN_FILE"
    exit 1
fi
TOKEN=$(cat "$TOKEN_FILE" | tr -d '\n')

echo "🚀 Iniciando compilación de Flutter (Release)..."
flutter build apk --release

echo "📦 Subiendo código fuente a GitHub..."
git config user.email "txurtxil@users.noreply.github.com"
git config user.name "txurtxil"
git add .
git commit -m "Release $VERSION: Agent Server robusto con logs y script de deploy automático" || true
git push origin main || echo "⚠️ Push al código falló (quizás ya está actualizado), intentando subir la Release..."

echo "📦 Creando Release $VERSION en GitHub..."
RELEASE_JSON=$(printf '{"tag_name": "%s", "name": "Build %s", "body": "Servidor reescrito con captura de logs y permisos estáticos", "draft": false, "prerelease": false}' "$VERSION" "$VERSION")
RELEASE_ID=$(curl -s -H "Authorization: token $TOKEN" -d "$RELEASE_JSON" https://api.github.com/repos/${REPO}/releases | grep -o '"id": [0-9]*' | head -1 | awk '{print $2}')

if [ -z "$RELEASE_ID" ]; then
    echo "❌ Error al crear release. Es posible que el tag $VERSION ya exista."
    exit 1
fi

echo "⬆️ Subiendo $APK_PATH a la Release ID: $RELEASE_ID..."
curl -s -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/vnd.android.package-archive" \
    --data-binary @"$APK_PATH" "https://uploads.github.com/repos/${REPO}/releases/${RELEASE_ID}/assets?name=app-release.apk"

echo "✅ ¡Despliegue $VERSION completado con éxito!"
