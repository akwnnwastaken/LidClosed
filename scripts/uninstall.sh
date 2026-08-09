#!/bin/bash
set -euo pipefail

# ============================================================
#  LidClosed — Uninstaller
#  Removes the app, the privileged helper, the boot cleanup
#  daemon and the per-user state.
#
#  Order is deliberate: system sleep is restored FIRST, while
#  the helper still exists. Removing the tooling before undoing
#  the override would leave a Mac that never sleeps and nothing
#  installed to fix it.
# ============================================================

cd "$(dirname "$0")/.."

APP_NAME="LidClosed"
BUNDLE_NAME="${APP_NAME}.app"
INSTALLED_APP="/Applications/${BUNDLE_NAME}"
DAEMON_LABEL="com.akwnnwastaken.LidClosed.cleanup"
HELPER_PATH="/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
MARKER="/var/db/com.akwnnwastaken.LidClosed.active"
USER_STATE="${HOME}/Library/Application Support/LidClosed"

echo "🧹 LidClosed uninstaller"
echo ""
echo "This removes:"
echo "   ${INSTALLED_APP}"
echo "   ${HELPER_PATH}"
echo "   ${DAEMON_PLIST}  (and unloads the daemon)"
echo "   ${MARKER}"
echo "   ${USER_STATE}"
echo ""

# Same rule as install.sh: this needs sudo and writes outside the project, so a piped or
# CI invocation must never trigger it silently.
REPLY="n"
if [ -t 0 ]; then
    read -r -n 1 -p "Continue? (requires sudo) (y/n) " REPLY || true
    echo ""
fi

if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
    echo "ℹ️  Nothing was removed."
    exit 0
fi

echo ""

# 1. Stop the app, so it cannot rewrite state while we tear down. SIGTERM lets its own
#    handler attempt a restore first.
if pgrep -x "${APP_NAME}" > /dev/null 2>&1; then
    echo "  Quitting the running app..."
    pkill -x "${APP_NAME}" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "${APP_NAME}" > /dev/null 2>&1 || break
        sleep 0.3
    done
fi

# 2. Restore sleep — but only an override LidClosed owns. The marker is that proof. If
#    sleep is disabled without a marker, something else did it and it is not ours to undo.
if /usr/bin/pmset -g | grep -qE 'SleepDisabled[ \t]+1'; then
    if sudo test -e "${MARKER}"; then
        echo "  Restoring system sleep (LidClosed owned the override)..."
        sudo /usr/bin/pmset disablesleep 0
        echo "  ✅ Sleep restored"
    else
        echo "  ⚠️  System sleep is disabled, but there is no LidClosed marker."
        echo "     Something else disabled it, so it was left untouched."
        echo "     To undo it yourself: sudo pmset disablesleep 0"
    fi
fi

# 3. Unload and remove the daemon before the helper it points at.
if [ -e "${DAEMON_PLIST}" ]; then
    echo "  Unloading ${DAEMON_LABEL}..."
    sudo launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
    sudo rm -f "${DAEMON_PLIST}"
    echo "  ✅ Daemon removed"
fi

sudo rm -f "${HELPER_PATH}" "${MARKER}"
echo "  ✅ Helper and marker removed"

sudo rm -rf "${INSTALLED_APP}"
echo "  ✅ App removed"

# The per-user directory also holds instance.lock, so this clears both.
rm -rf "${USER_STATE}"
echo "  ✅ Per-user state removed"

echo ""
echo "✅ LidClosed is fully uninstalled."
echo ""
/usr/bin/pmset -g | grep -E 'SleepDisabled' || echo "   (pmset reports no SleepDisabled entry)"
