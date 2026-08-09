#!/bin/sh
#
# LidClosed privileged helper.
#
# Installed by scripts/install.sh to
#   /Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper
# owned root:wheel and writable by nobody else.
#
# That ownership is load-bearing, not hygiene. The app invokes this script through an
# administrator prompt, so a copy the logged-in user could modify would hand root to any
# process running as that user — the exact escalation that root-owning the app bundle was
# meant to close. /Library is root:wheel and not group-writable, which is why the helper
# lives there and not under /Library/Application Support (root:admin).
#
# Two callers:
#   - the app, via `do shell script … with administrator privileges` (enable / disable)
#   - the LaunchDaemon com.akwnnwastaken.LidClosed.cleanup, at boot (cleanup)
#
# The point of routing the app through here rather than calling pmset directly is the
# marker: it is written as root, in the same operation that disables sleep, so the
# boot-time cleanup has a trustworthy record of whether LidClosed owns the override.

set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

MARKER=/var/db/com.akwnnwastaken.LidClosed.active
PMSET=/usr/bin/pmset
TAG=com.akwnnwastaken.LidClosed.helper

log() {
    /usr/bin/logger -t "$TAG" "$1"
}

case "${1:-}" in
enable)
    # `set -e` means the marker is written only if pmset actually succeeded, so the
    # marker can never claim an override that was not applied.
    "$PMSET" disablesleep 1
    /bin/date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
    /bin/chmod 600 "$MARKER"
    log "sleep override enabled; marker written"
    ;;

disable)
    "$PMSET" disablesleep 0
    /bin/rm -f "$MARKER"
    log "sleep override removed; marker cleared"
    ;;

cleanup)
    # Runs once at boot from the LaunchDaemon. A marker present this early means a
    # previous session disabled sleep and never restored it: no LidClosed process can
    # have survived the reboot, so there is nothing to coordinate with and no dialog to
    # wait for. This is what stops `SleepDisabled 1` — which is persisted to
    # /Library/Preferences/com.apple.PowerManagement.plist — from outliving the session
    # that asked for it.
    #
    # If pmset fails here, `set -e` leaves the marker in place and the next boot retries.
    #
    # The liveness guard costs nothing at boot, where no LidClosed can be running, and
    # exists for the other time this runs: `launchctl bootstrap` during a re-install. An
    # unguarded cleanup there would restore sleep out from under a user who has lid-closed
    # mode switched on, while the app still believed it owned the override.
    if /usr/bin/pgrep -x LidClosed > /dev/null 2>&1; then
        log "cleanup: LidClosed is running, leaving the override alone"
        exit 0
    fi

    if [ -e "$MARKER" ]; then
        "$PMSET" disablesleep 0
        /bin/rm -f "$MARKER"
        log "boot cleanup: restored system sleep left disabled by a previous session"
    else
        log "boot cleanup: nothing to restore"
    fi
    ;;

*)
    echo "usage: $(basename "$0") enable|disable|cleanup" >&2
    exit 64
    ;;
esac
