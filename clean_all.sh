#!/bin/bash
set -e

echo "[CLEAN] removing build artifacts..."

flutter clean

rm -rf build
rm -rf .dart_tool
rm -rf .packages
rm -rf pubspec.lock

cd android
./gradlew clean || true
cd ..

echo "[CLEAN] done"
