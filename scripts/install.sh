#!/bin/bash
set -e

# ============================================================
#  LidClosed — Build & Install Script
#  Creates a proper macOS .app bundle and installs to /Applications
# ============================================================

APP_NAME="LidClosed"
BUNDLE_NAME="${APP_NAME}.app"
BUILD_DIR=".build/release"
DIST_DIR="dist"
ICON_SOURCE="Resources/AppIcon.png"
ICONSET_DIR="${DIST_DIR}/AppIcon.iconset"

echo "🔨 Building ${APP_NAME}..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf "${DIST_DIR}/${BUNDLE_NAME}"
mkdir -p "${DIST_DIR}/${BUNDLE_NAME}/Contents/MacOS"
mkdir -p "${DIST_DIR}/${BUNDLE_NAME}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${DIST_DIR}/${BUNDLE_NAME}/Contents/MacOS/"

# Copy Info.plist
cp "Resources/Info.plist" "${DIST_DIR}/${BUNDLE_NAME}/Contents/"

# Create .icns icon from PNG
if [ -f "${ICON_SOURCE}" ]; then
    echo "🎨 Creating app icon..."
    mkdir -p "${ICONSET_DIR}"

    # Generate all required icon sizes
    sips -z 16 16     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png"      > /dev/null 2>&1
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png"   > /dev/null 2>&1
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png"      > /dev/null 2>&1
    sips -z 64 64     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png"   > /dev/null 2>&1
    sips -z 128 128   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png"    > /dev/null 2>&1
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null 2>&1
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png"    > /dev/null 2>&1
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null 2>&1
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png"    > /dev/null 2>&1
    sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null 2>&1

    # Convert iconset to icns
    iconutil -c icns "${ICONSET_DIR}" -o "${DIST_DIR}/${BUNDLE_NAME}/Contents/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "  ✅ Icon created"
else
    echo "  ⚠️  No icon found at ${ICON_SOURCE}, skipping icon"
fi

echo ""
echo "✅ App bundle created: ${DIST_DIR}/${BUNDLE_NAME}"
echo ""

# Install to /Applications
read -p "📲 Install to /Applications? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Remove old version if exists
    if [ -d "/Applications/${BUNDLE_NAME}" ]; then
        echo "  Removing old version..."
        rm -rf "/Applications/${BUNDLE_NAME}"
    fi

    cp -R "${DIST_DIR}/${BUNDLE_NAME}" "/Applications/"
    echo "  ✅ Installed to /Applications/${BUNDLE_NAME}"
    echo ""
    echo "🚀 You can now:"
    echo "   • Find it with Spotlight (Cmd+Space → 'LidClosed')"
    echo "   • Or run: open /Applications/${BUNDLE_NAME}"
else
    echo ""
    echo "ℹ️  To install manually:"
    echo "   cp -R ${DIST_DIR}/${BUNDLE_NAME} /Applications/"
fi
