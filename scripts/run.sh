#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pkill -9 -x "tiffy-face" || true
sleep 0.3

if [ -d "/Applications/tiffy-face.app" ]; then
    open "/Applications/tiffy-face.app"
    echo "🚀 Launched /Applications/tiffy-face.app"
else
    open "${PROJECT_DIR}/tiffy-face.app"
    echo "🚀 Launched ${PROJECT_DIR}/tiffy-face.app"
fi
