#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

./scripts/build_app.sh

DMG_TMP="${PROJECT_DIR}/.build_dmg"
DMG_OUTPUT="${PROJECT_DIR}/tiffy-face-Installer.dmg"

rm -rf "${DMG_TMP}"
mkdir -p "${DMG_TMP}"
cp -R "${PROJECT_DIR}/tiffy-face.app" "${DMG_TMP}/tiffy-face.app"
ln -s /Applications "${DMG_TMP}/Applications"

rm -f "${DMG_OUTPUT}"
hdiutil create -volname "Tiffy Face Installer" -srcfolder "${DMG_TMP}" -ov -format UDZO "${DMG_OUTPUT}"
rm -rf "${DMG_TMP}"

mkdir -p "${PROJECT_DIR}/docs"
cp -f "${DMG_OUTPUT}" "${PROJECT_DIR}/docs/tiffy-face-Installer.dmg"

ZIP_OUTPUT="${PROJECT_DIR}/tiffy-face.zip"
rm -f "${ZIP_OUTPUT}"
ditto -c -k --keepParent "${PROJECT_DIR}/tiffy-face.app" "${ZIP_OUTPUT}"
cp -f "${ZIP_OUTPUT}" "${PROJECT_DIR}/docs/tiffy-face.zip"

TIFFY_OUT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)/tiffy-app/tiffy-face"
if [ -d "${TIFFY_OUT_DIR}" ]; then
    echo "📦 Syncing DMG and ZIP to ${TIFFY_OUT_DIR}..."
    cp -f "${DMG_OUTPUT}" "${TIFFY_OUT_DIR}/tiffy-face-Installer.dmg"
    cp -f "${ZIP_OUTPUT}" "${TIFFY_OUT_DIR}/tiffy-face.zip"
fi

echo "🎉 DMG and ZIP packages created!"
ls -lh "${DMG_OUTPUT}" "${ZIP_OUTPUT}"
