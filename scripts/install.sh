#!/bin/bash
set -euo pipefail

# ============================================================
#  LidClosed — Build & Install Script
#  Creates a macOS .app bundle, codesigns it, and installs to
#  /Applications with root ownership to prevent local privilege
#  escalation.
# ============================================================

# Ensure we run from the project root
cd "$(dirname "$0")/.."

APP_NAME="LidClosed"
BUNDLE_NAME="${APP_NAME}.app"
BUILD_DIR=".build/release"
DIST_DIR="dist"
ICON_SOURCE="Resources/AppIcon.png"
ICONSET_DIR="${DIST_DIR}/AppIcon.iconset"
APP_PATH="${DIST_DIR}/${BUNDLE_NAME}"

echo "🔨 Building ${APP_NAME}..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${APP_PATH}/Contents/MacOS/"

# Copy Info.plist
cp "Resources/Info.plist" "${APP_PATH}/Contents/"

# Create .icns icon from PNG
if [ -f "${ICON_SOURCE}" ]; then
    echo "🎨 Creating app icon..."
    CLEAN_PNG="${DIST_DIR}/AppIcon_clean.png"
    sips -s format png "${ICON_SOURCE}" --out "${CLEAN_PNG}" > /dev/null 2>&1
    mkdir -p "${ICONSET_DIR}"

    declare -a SIZES=("16" "32" "64" "128" "256" "512" "1024")
    for size in "${SIZES[@]}"; do
        sips -z "${size}" "${size}" "${CLEAN_PNG}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" > /dev/null 2>&1
    done

    cp "${ICONSET_DIR}/icon_32x32.png"     "${ICONSET_DIR}/icon_16x16@2x.png"
    cp "${ICONSET_DIR}/icon_64x64.png"     "${ICONSET_DIR}/icon_32x32@2x.png"
    cp "${ICONSET_DIR}/icon_256x256.png"   "${ICONSET_DIR}/icon_128x128@2x.png"
    cp "${ICONSET_DIR}/icon_512x512.png"   "${ICONSET_DIR}/icon_256x256@2x.png"
    cp "${ICONSET_DIR}/icon_1024x1024.png" "${ICONSET_DIR}/icon_512x512@2x.png"
    rm -f "${ICONSET_DIR}/icon_64x64.png" "${ICONSET_DIR}/icon_1024x1024.png"

    if iconutil -c icns "${ICONSET_DIR}" -o "${APP_PATH}/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "  ✅ Icon created"
    else
        echo "  ⚠️  iconutil failed — app will use default icon"
    fi

    rm -rf "${ICONSET_DIR}" "${CLEAN_PNG}"
else
    echo "  ⚠️  No icon found at ${ICON_SOURCE}, skipping icon"
fi

# Ad-hoc signing seals the bundle so accidental corruption is detectable. It is NOT a
# defence against a local attacker: anyone can re-sign ad-hoc without a certificate.
# Root ownership below is what actually protects the bundle.
echo "🔐 Ad-hoc signing bundle..."
codesign --force --options runtime -s - "${APP_PATH}"
codesign --verify --strict "${APP_PATH}"

echo ""
echo "✅ App bundle created: ${APP_PATH}"
echo ""

# Install to /Applications. Default to NOT installing: this step needs sudo and writes
# outside the project, so a piped or CI invocation must never trigger it silently.
REPLY="n"
if [ -t 0 ]; then
    read -r -n 1 -p "📲 Install to /Applications? (requires sudo for root ownership) (y/n) " REPLY || true
    echo ""
fi

if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    STAGING="/Applications/.${BUNDLE_NAME}.staging"
    FINAL="/Applications/${BUNDLE_NAME}"

    echo "  Staging new version..."
    sudo rm -rf "${STAGING}"
    sudo cp -R "${APP_PATH}" "${STAGING}"

    # root:wheel ownership is the real mitigation against local privilege escalation:
    # the app runs commands as root via an admin prompt, so a bundle writable by the
    # logged-in user would let any user-level process swap the binary and inherit root.
    echo "  Securing permissions (root:wheel)..."
    sudo chown -R root:wheel "${STAGING}"
    sudo chmod -R go-w "${STAGING}"

    # Swap only once the new copy is fully staged, so a failure never leaves
    # /Applications without an app.
    echo "  Installing..."
    sudo rm -rf "${FINAL}"
    sudo mv "${STAGING}" "${FINAL}"

    echo "  ✅ Installed to ${FINAL}"
    echo ""
    echo "🚀 You can now find it with Spotlight (Cmd+Space → 'LidClosed')"
else
    echo ""
    echo "ℹ️  Not installed. To install manually (securely):"
    echo "   sudo cp -R ${APP_PATH} /Applications/"
    echo "   sudo chown -R root:wheel /Applications/${BUNDLE_NAME}"
    echo ""
    echo "   Note: launching the copy in ${DIST_DIR}/ instead leaves the bundle writable"
    echo "   by your user account, which reopens the privilege-escalation path."
fi
