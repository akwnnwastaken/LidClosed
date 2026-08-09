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

# The privileged helper and the boot-time cleanup daemon. The helper goes under /Library
# rather than /Library/Application Support because /Library is root:wheel and not
# group-writable, and the app invokes the helper through an admin prompt — a copy the
# logged-in user could modify would hand it root.
DAEMON_LABEL="com.akwnnwastaken.LidClosed.cleanup"
HELPER_PATH="/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

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

# Stamp the version from git. Only the copy inside the bundle is edited — Resources/Info.plist
# stays clean, so building never dirties the working tree.
#
# Worth having because "which build is installed?" was previously answered by comparing file
# timestamps against the git log. CFBundleVersion is the commit count (monotonic, and a valid
# period-separated integer); the short version comes from the latest tag if there is one, and
# is otherwise left alone rather than invented.
BUNDLE_PLIST="${APP_PATH}/Contents/Info.plist"
if git rev-parse --git-dir > /dev/null 2>&1; then
    GIT_COUNT="$(git rev-list --count HEAD)"
    GIT_SHA="$(git rev-parse --short HEAD)"
    GIT_DIRTY=""
    git diff --quiet HEAD 2>/dev/null || GIT_DIRTY="+dirty"

    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GIT_COUNT}" "${BUNDLE_PLIST}" > /dev/null

    GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    if [ -n "${GIT_TAG}" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${GIT_TAG#v}" \
            "${BUNDLE_PLIST}" > /dev/null
    fi

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

# Ad-hoc signing seals the bundle so accidental corruption is detectable. It is NOT a
# defence against a local attacker: anyone can re-sign ad-hoc without a certificate.
# Root ownership below is what actually protects the bundle.
echo "🔐 Ad-hoc signing bundle..."
codesign --force --options runtime -s - "${APP_PATH}"
codesign --verify --strict "${APP_PATH}"

# SwiftPM gives debug builds com.apple.security.get-task-allow, which permits attaching a
# debugger to a process that performs privileged operations. BUILD_DIR is release-only, so a
# debug binary cannot reach the bundle today — assert it instead of trusting that to hold.
if codesign -d --entitlements - "${APP_PATH}" 2>/dev/null | grep -q "get-task-allow"; then
    echo "  ❌ Refusing to continue: the bundle carries com.apple.security.get-task-allow."
    echo "     That entitlement belongs to debug builds only. Check BUILD_DIR."
    exit 1
fi
echo "  ✅ No debug entitlements"

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

    # The privileged helper. Both the app (through an admin prompt) and the boot-time
    # daemon (as root) run this, so root:wheel and mode 755 are the security boundary,
    # not tidiness: a user-writable helper would hand root to any process running as the
    # logged-in user the next time they authenticate.
    echo "  Installing privileged helper..."
    sudo install -d -o root -g wheel -m 755 "$(dirname "${HELPER_PATH}")"
    sudo install -o root -g wheel -m 755 "scripts/lidclosed-helper.sh" "${HELPER_PATH}"
    echo "  ✅ Helper installed at ${HELPER_PATH}"

    # Restores sleep at boot if a session ended without restoring it. bootout first so a
    # re-install replaces a previously loaded definition rather than failing on it.
    echo "  Installing boot cleanup daemon..."
    sudo install -o root -g wheel -m 644 "Resources/${DAEMON_LABEL}.plist" "${DAEMON_PLIST}"
    sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    sudo launchctl bootstrap system "${DAEMON_PLIST}"
    echo "  ✅ Daemon ${DAEMON_LABEL} loaded"

    # dist/ holds a user-owned, fully launchable copy of the same app. Leaving it behind
    # reopens exactly the escalation path that root-owning /Applications just closed, so
    # it goes now that the hardened copy is in place.
    rm -rf "${APP_PATH}"
    echo "  ✅ Removed the unhardened build copy from ${DIST_DIR}/"

    echo ""
    echo "🚀 You can now find it with Spotlight (Cmd+Space → 'LidClosed')"
    echo "   To remove everything later, including the daemon: ./scripts/uninstall.sh"
else
    echo ""
    echo "ℹ️  Not installed. To install manually (securely):"
    echo "   sudo cp -R ${APP_PATH} /Applications/"
    echo "   sudo chown -R root:wheel /Applications/${BUNDLE_NAME}"
    echo ""
    echo "   Note: launching the copy in ${DIST_DIR}/ instead leaves the bundle writable"
    echo "   by your user account, which reopens the privilege-escalation path."
    echo ""
    echo "   A manual copy also skips the privileged helper and the boot cleanup daemon."
    echo "   The app still works: it calls pmset directly and recovers a leftover override"
    echo "   on next launch, which is how it behaved before the daemon existed. What you"
    echo "   lose is cleanup at restart or shutdown."
fi
