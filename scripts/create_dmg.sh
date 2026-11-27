#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

./scripts/build_app.sh

DMG_TMP="${PROJECT_DIR}/.build_dmg"
DMG_OUTPUT="${PROJECT_DIR}/pliw-face-Installer.dmg"

rm -rf "${DMG_TMP}"
mkdir -p "${DMG_TMP}"
cp -R "${PROJECT_DIR}/Pliw Face.app" "${DMG_TMP}/Pliw Face.app"
ln -s /Applications "${DMG_TMP}/Applications"

rm -f "${DMG_OUTPUT}"
hdiutil create -volname "Pliw Face Installer" -srcfolder "${DMG_TMP}" -ov -format UDZO "${DMG_OUTPUT}"
rm -rf "${DMG_TMP}"

ZIP_OUTPUT="${PROJECT_DIR}/pliw-face.zip"
rm -f "${ZIP_OUTPUT}"
ditto -c -k --keepParent "${PROJECT_DIR}/Pliw Face.app" "${ZIP_OUTPUT}"

PORTAL_OUT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)/public/public/pliw-face"
if [ -d "${PORTAL_OUT_DIR}" ]; then
    echo "📦 Syncing DMG and ZIP to ${PORTAL_OUT_DIR}..."
    cp -f "${DMG_OUTPUT}" "${PORTAL_OUT_DIR}/pliw-face-Installer.dmg"
    cp -f "${ZIP_OUTPUT}" "${PORTAL_OUT_DIR}/pliw-face.zip"
fi

echo "🎉 DMG and ZIP packages created!"
ls -lh "${DMG_OUTPUT}" "${ZIP_OUTPUT}"
