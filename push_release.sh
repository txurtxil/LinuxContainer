#!/bin/bash
set -e

git add -A

git commit -m "sync release APK and fixes" || echo "no changes to commit"

git pull --rebase origin main || true

git push origin main
