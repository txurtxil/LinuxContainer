#!/bin/bash
set -e

cd /workspace/linuxcontainer

flutter build apk --release

VERSION=$(date +%Y%m%d-%H%M%S)

mkdir -p "releases/$VERSION"
cp build/app/outputs/flutter-apk/app-release.apk "releases/$VERSION/"

git add "releases/$VERSION/app-release.apk"
git commit -m "Release APK $VERSION"
git push origin main
