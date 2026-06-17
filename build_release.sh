#!/bin/bash
set -e

flutter clean
flutter pub get

flutter build apk --release \
  --android-skip-build-dependency-validation

mkdir -p releases/v1
cp build/app/outputs/flutter-apk/app-release.apk releases/v1/

echo "[BUILD] APK copied to releases/v1/"
