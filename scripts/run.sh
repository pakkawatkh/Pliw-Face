#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pkill -9 -x "pliw-face" || true
sleep 0.3

if [ -d "/Applications/Pliw Face.app" ]; then
    open "/Applications/Pliw Face.app"
    echo "🚀 Launched /Applications/Pliw Face.app"
else
    open "${PROJECT_DIR}/Pliw Face.app"
    echo "🚀 Launched ${PROJECT_DIR}/Pliw Face.app"
fi
