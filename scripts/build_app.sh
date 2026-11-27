#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_DIR}"

if [ -z "${DEVELOPER_DIR}" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "🔨 Building pliw-face (Release mode)..."
swift build -c release -Xswiftc -cross-module-optimization

RELEASE_BIN="${PROJECT_DIR}/.build/release/pliw-face"
APP_DIR="${PROJECT_DIR}/Pliw Face.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "📦 Assembling Pliw Face.app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

cp "${RELEASE_BIN}" "${MACOS_DIR}/pliw-face"
strip "${MACOS_DIR}/pliw-face"
chmod +x "${MACOS_DIR}/pliw-face"

# Copy macOS App Icon if present
if [ -f "${PROJECT_DIR}/Resources/AppIcon.icns" ]; then
    cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

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
    <string>pliw-face</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.pliw-face</string>
    <key>CFBundleName</key>
    <string>Pliw Face</string>
    <key>CFBundleDisplayName</key>
    <string>Pliw Face</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>Pliw Face uses your camera on-device to recognize your face and verify liveness. Frames are never saved to disk or sent over the network.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "🔏 Code signing Pliw Face.app with stable PliwDeveloper certificate..."
SIGN_CERT="PliwDeveloper"
if ! security find-certificate -c "${SIGN_CERT}" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "Creating persistent local developer certificate '${SIGN_CERT}' for stable macOS TCC permissions..."
    TMP_CERT_DIR=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -days 3650 \
      -keyout "${TMP_CERT_DIR}/dev.key" -out "${TMP_CERT_DIR}/dev.crt" -nodes \
      -subj "/CN=${SIGN_CERT}" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=codeSigning"
    if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
        openssl pkcs12 -export -legacy \
          -in "${TMP_CERT_DIR}/dev.crt" -inkey "${TMP_CERT_DIR}/dev.key" \
          -out "${TMP_CERT_DIR}/dev.p12" -password pass:pliwdev
    else
        openssl pkcs12 -export \
          -in "${TMP_CERT_DIR}/dev.crt" -inkey "${TMP_CERT_DIR}/dev.key" \
          -out "${TMP_CERT_DIR}/dev.p12" -password pass:pliwdev
    fi
    security import "${TMP_CERT_DIR}/dev.p12" -k ~/Library/Keychains/login.keychain-db -P pliwdev -T /usr/bin/codesign || true
    rm -rf "${TMP_CERT_DIR}"
fi

if ! security find-identity -v -p codesigning | grep -q "${SIGN_CERT}"; then
    echo "🔐 Trusting '${SIGN_CERT}' for code signing so macOS TCC preserves permissions across rebuilds..."
    TMP_TRUST_CRT=$(mktemp /tmp/pliwdev.XXXXXX.crt)
    if security find-certificate -c "${SIGN_CERT}" -p ~/Library/Keychains/login.keychain-db > "${TMP_TRUST_CRT}" 2>/dev/null; then
        security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "${TMP_TRUST_CRT}" || true
    fi
    rm -f "${TMP_TRUST_CRT}"
fi

codesign --force --deep --sign "${SIGN_CERT}" "${APP_DIR}" || codesign --force --deep --sign - "${APP_DIR}"

echo "✅ Successfully built: ${APP_DIR}"

if [ -z "${SKIP_INSTALL}" ]; then
    echo "📲 Updating /Applications/Pliw Face.app..."
    pkill -9 -x "pliw-face" || true
    rm -rf "/Applications/Pliw Face.app"
    cp -R "${APP_DIR}" "/Applications/Pliw Face.app"
    touch "/Applications/Pliw Face.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Pliw Face.app" >/dev/null 2>&1 || true
    echo "🎉 Updated /Applications/Pliw Face.app"
else
    echo "⏭️ Skipping install to /Applications because SKIP_INSTALL is set."
fi
