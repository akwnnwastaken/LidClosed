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

    # First, re-encode PNG to ensure compatibility with iconutil
    CLEAN_PNG="${DIST_DIR}/AppIcon_clean.png"
    sips -s format png "${ICON_SOURCE}" --out "${CLEAN_PNG}" > /dev/null 2>&1

    mkdir -p "${ICONSET_DIR}"

    # Generate all required icon sizes from the clean PNG
    declare -a SIZES=("16" "32" "64" "128" "256" "512" "1024")
    for size in "${SIZES[@]}"; do
        sips -z "${size}" "${size}" "${CLEAN_PNG}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" > /dev/null 2>&1
    done

    # Rename to standard iconset naming convention
    cp "${ICONSET_DIR}/icon_32x32.png"     "${ICONSET_DIR}/icon_16x16@2x.png"
    cp "${ICONSET_DIR}/icon_64x64.png"     "${ICONSET_DIR}/icon_32x32@2x.png"
    cp "${ICONSET_DIR}/icon_256x256.png"   "${ICONSET_DIR}/icon_128x128@2x.png"
    cp "${ICONSET_DIR}/icon_512x512.png"   "${ICONSET_DIR}/icon_256x256@2x.png"
    cp "${ICONSET_DIR}/icon_1024x1024.png" "${ICONSET_DIR}/icon_512x512@2x.png"
    rm -f "${ICONSET_DIR}/icon_64x64.png" "${ICONSET_DIR}/icon_1024x1024.png"

    # Convert iconset to icns
    if iconutil -c icns "${ICONSET_DIR}" -o "${DIST_DIR}/${BUNDLE_NAME}/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "  ✅ Icon created"
    else
        echo "  ⚠️  iconutil failed — app will use default icon"
    fi

    rm -rf "${ICONSET_DIR}" "${CLEAN_PNG}"
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
