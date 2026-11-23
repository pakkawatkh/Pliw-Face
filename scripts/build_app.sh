#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

if [ -z "${DEVELOPER_DIR}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "🔨 Building tiffy-face (Release mode)..."
swift build -c release -Xswiftc -cross-module-optimization

RELEASE_BIN="${PROJECT_DIR}/.build/release/tiffy-face"
APP_DIR="${PROJECT_DIR}/tiffy-face.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "📦 Assembling tiffy-face.app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

cp "${RELEASE_BIN}" "${MACOS_DIR}/tiffy-face"
strip "${MACOS_DIR}/tiffy-face"
chmod +x "${MACOS_DIR}/tiffy-face"

# Compile quantized FP16 ArcFace Core ML model into app bundle Resources
MLPACKAGE="${PROJECT_DIR}/Resources/ArcFaceFP16.mlpackage"
if [ -d "${MLPACKAGE}" ]; then
    echo "🧠 Compiling ArcFaceFP16.mlpackage for Apple Neural Engine..."
    xcrun coremlcompiler compile "${MLPACKAGE}" "${RESOURCES_DIR}"
fi

cat << 'EOF' > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>tiffy-face</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.tiffy-face</string>
    <key>CFBundleName</key>
    <string>Tiffy Face</string>
    <key>CFBundleDisplayName</key>
    <string>Tiffy Face</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Tiffy Face uses your camera on-device to recognize your face and verify liveness. Frames are never saved to disk or sent over the network.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "🔏 Code signing app bundle..."
SIGN_CERT="TiffyFaceDeveloper"
if ! security find-certificate -c "${SIGN_CERT}" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    if security find-certificate -c "MonkeyToolsDeveloper" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
        SIGN_CERT="MonkeyToolsDeveloper"
    fi
fi

codesign --force --deep --sign "${SIGN_CERT}" "${APP_DIR}" || codesign --force --deep --sign - "${APP_DIR}"

echo "✅ Successfully built: ${APP_DIR}"

if [ -z "${SKIP_INSTALL}" ]; then
    echo "📲 Updating /Applications/tiffy-face.app..."
    pkill -9 -x "tiffy-face" || true
    rm -rf "/Applications/tiffy-face.app"
    cp -R "${APP_DIR}" "/Applications/tiffy-face.app"
    echo "🎉 Updated /Applications/tiffy-face.app"
else
    echo "⏭️ Skipping install to /Applications because SKIP_INSTALL is set."
fi
