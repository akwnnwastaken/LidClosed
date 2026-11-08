#!/bin/bash
# Build and stage LidClosed without installing the app or touching system state.
set -euo pipefail
cd "$(dirname "$0")/.."
arch=()
case "${1:-}" in
  '') ;;
  --universal) arch=(--arch arm64 --arch x86_64) ;;
  *) echo 'usage: build-app.sh [--universal]' >&2; exit 64 ;;
esac
APP_NAME=LidClosed
DIST_DIR=dist
ICON_SOURCE=Resources/AppIcon.png
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
APP_PATH="$DIST_DIR/$APP_NAME.app"

echo "🔨 Building ${APP_NAME}..."
swift build -c release ${arch[@]+"${arch[@]}"}
BUILD_DIR="$(swift build -c release ${arch[@]+"${arch[@]}"} --show-bin-path)"

echo "📦 Creating app bundle..."
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${APP_PATH}/Contents/MacOS/"

# Copy Info.plist
cp "Resources/Info.plist" "${APP_PATH}/Contents/"

# Keep the release version from Info.plist. Stamp the build number and source commit
# only in the packaged copy so an older release tag cannot relabel a new build.
#
# Worth having because "which build is installed?" was previously answered by comparing file
# timestamps against the git log. CFBundleVersion is the commit count.
BUNDLE_PLIST="${APP_PATH}/Contents/Info.plist"
if git rev-parse --git-dir > /dev/null 2>&1; then
    GIT_COUNT="$(git rev-list --count HEAD)"
    GIT_SHA="$(git rev-parse --short HEAD)"
    GIT_DIRTY=""
    git diff --quiet HEAD 2>/dev/null || GIT_DIRTY="+dirty"

    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GIT_COUNT}" "${BUNDLE_PLIST}" > /dev/null

    # Not a CFBundle key: records the exact commit, which a version number cannot.
    /usr/libexec/PlistBuddy -c "Add :LidClosedGitCommit string ${GIT_SHA}${GIT_DIRTY}" \
        "${BUNDLE_PLIST}" > /dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :LidClosedGitCommit ${GIT_SHA}${GIT_DIRTY}" \
            "${BUNDLE_PLIST}" > /dev/null

    SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUNDLE_PLIST}")"
    echo "  ✅ Version ${SHORT_VERSION} (build ${GIT_COUNT}, commit ${GIT_SHA}${GIT_DIRTY})"
else
    echo "  ⚠️  Not a git checkout — leaving the version in Info.plist untouched"
fi

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
