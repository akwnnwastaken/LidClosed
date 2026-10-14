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
# Three callers:
#   - the app, via `do shell script … with administrator privileges` (enable / disable)
#   - the LaunchDaemon com.akwnnwastaken.LidClosed.cleanup, at boot (cleanup)
#   - the LaunchDaemon com.akwnnwastaken.LidClosed.batteryguard, every minute (battery-guard)
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

# At or below this charge, on battery, LidClosed gives sleep back. A lid-closed Mac on
# battery is usually in a bag: left alone it runs flat, and it can run hot.
LOW_BATTERY_PERCENT=20

log() {
    /usr/bin/logger -t "$TAG" "$1"
}

# Reads `pmset -g batt` output on stdin and succeeds only when the Mac is drawing from its
# battery at or below LOW_BATTERY_PERCENT. Anything it cannot parse — a desktop, AC power,
# unexpected output — counts as not low: the guard must never restore sleep under a user on
# the strength of a guess.
battery_low() {
    /usr/bin/awk -v limit="$LOW_BATTERY_PERCENT" '
        NR == 1 && /Battery Power/ { on_battery = 1 }
        pct == "" && match($0, /[0-9]+%;/) { pct = substr($0, RSTART, RLENGTH - 2) }
        END { exit !(on_battery && pct != "" && pct + 0 <= limit) }
    '
}

case "${1:-}" in
enable)
    # Refused rather than allowed and undone a minute later by the battery guard, so the
    # user is told why at the moment they can still plug in. The message reaches the app's
    # "Could Not Disable Sleep" alert through `do shell script`'s error text.
    if "$PMSET" -g batt | battery_low; then
        echo "The battery is at ${LOW_BATTERY_PERCENT}% or below and the Mac is not plugged in. Connect power first." >&2
        exit 1
    fi

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

battery-guard)
    # Runs every minute from the LaunchDaemon com.akwnnwastaken.LidClosed.batteryguard.
    # The app cannot do this itself: restoring sleep needs root, and with the lid shut
    # there is nobody to answer a password prompt.
    #
    # Unlike `cleanup`, this deliberately acts while LidClosed is running — a live session
    # is exactly the case it exists for. The app notices sleep came back the next time it
    # reads `pmset` and drops its own state file.
    [ -e "$MARKER" ] || exit 0

    if "$PMSET" -g batt | battery_low; then
        "$PMSET" disablesleep 0
        /bin/rm -f "$MARKER"
        log "battery guard: on battery at ${LOW_BATTERY_PERCENT}% or below, restored system sleep"
    fi
    ;;

battery-low)
    # Pure decision, no privileged action: parses `pmset -g batt` output from stdin. Exists
    # so the threshold logic can be tested without root.
    battery_low
    ;;

*)
    echo "usage: $(basename "$0") enable|disable|cleanup|battery-guard|battery-low" >&2
    exit 64
    ;;
esac
