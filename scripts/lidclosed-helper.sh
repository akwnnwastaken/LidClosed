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
# The app authenticates to enable or disable. The existing boot and session daemons
# can only restore sleep for an override recorded in our root-owned marker.
set -eu
umask 077

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

MARKER=/var/db/com.akwnnwastaken.LidClosed.active
LOCK=/var/db/com.akwnnwastaken.LidClosed.lock
PMSET=/usr/bin/pmset
GUARD=system/com.akwnnwastaken.LidClosed.batteryguard
TAG=com.akwnnwastaken.LidClosed.helper
LOW_BATTERY_PERCENT=20

log() {
    /usr/bin/logger -t "$TAG" "$1" || :
}

invalid() {
    echo "Invalid LidClosed session limits." >&2
    exit 64
}

# Canonical bounded decimals only; reject signs, leading zeros, and shell expressions.
uint() {
    case "$1" in
        ''|*[!0-9]*|0?*) return 1 ;;
    esac
    [ "${#1}" -le 10 ] && [ "$1" -le "$2" ]
}

validate_future_deadline() {
    # A local clock day can exceed 24 hours when the clocks go back.
    uint "$1" "$(($2 + 93600))" || invalid
    if [ "$1" -le "$2" ]; then
        echo "The selected end time has passed. Choose a new time and try again." >&2
        exit 1
    fi
}

battery_low() {
    /usr/bin/awk -v limit="$1" -v source="Now drawing from 'Battery Power'" '
        NR == 1 && $0 == source { on_battery = 1 }
        /-InternalBattery-/ && pct == "" && match($0, /[0-9]+%;/) {
            pct = substr($0, RSTART, RLENGTH - 2)
        }
        END { exit !(on_battery && pct != "" && pct + 0 <= limit) }
    '
}

thermal_state() {
    # Use Foundation without running code from a user-owned bundle or home directory.
    /usr/bin/env -i PATH="$PATH" HOME=/var/root /usr/bin/osascript -l JavaScript \
        -e 'ObjC.import("Foundation"); $.NSProcessInfo.processInfo.thermalState'
}

# now, deadline (0 = unlimited), battery percentage, thermal limit (0 = off),
# current thermal state (empty = unknown). Reads battery status on stdin.
limit_reason() {
    if [ "$2" -gt 0 ] && [ "$1" -ge "$2" ]; then
        echo "Time limit reached."
    elif [ "$4" -gt 0 ] && uint "$5" 3 && [ "$5" -ge "$4" ]; then
        echo "Thermal limit reached."
    elif battery_low "$3"; then
        echo "The battery is at $3% or below while unplugged. Connect power first."
    fi
}

sleep_is_disabled() {
    printf '%s\n' "$1" | /usr/bin/awk '$1 == "SleepDisabled" && $2 == "1" { found = 1 } END { exit !found }'
}

read_session() {
    [ -f "$MARKER" ] && read -r version deadline battery thermal extra < "$MARKER" &&
        [ "$version" = v2 ] && [ -z "$extra" ] &&
        uint "$deadline" 9999999999 && uint "$battery" 100 &&
        [ "$battery" -gt 0 ] && uint "$thermal" 3
}

write_session() {
    staged=$(/usr/bin/mktemp "${MARKER}.XXXXXX")
    trap '/bin/rm -f "$staged"' EXIT
    printf 'v2 %s %s %s\n' "$1" "$2" "$3" > "$staged"
    /bin/mv -f "$staged" "$MARKER"
}

restore_sleep() {
    "$PMSET" disablesleep 0
    /bin/rm -f "$MARKER"
}

case "${1:-}" in
limits-version)
    /bin/launchctl print "$GUARD" >/dev/null 2>&1 || exit 1
    # Older app builds expect exactly 1 from the argumentless probe.
    if [ "${2:-}" = live-timer ]; then echo 2; else echo 1; fi
    exit 0
    ;;
battery-low)
    limit=${2:-$LOW_BATTERY_PERCENT}
    uint "$limit" 100 || invalid
    battery_low "$limit"
    exit $?
    ;;
limits-check)
    [ "$#" -eq 6 ] && uint "$2" 9999999999 && uint "$3" 9999999999 &&
        uint "$4" 100 && [ "$4" -gt 0 ] && uint "$5" 3 &&
        { [ -z "$6" ] || uint "$6" 3; } || invalid
    shift
    limit_reason "$@"
    exit 0
    ;;
enable|enable-limited|enable-until|set-duration|set-deadline|disable|cleanup|battery-guard)
    [ "$(/usr/bin/id -u)" -eq 0 ] || exit 77
    if [ "$1" = "battery-guard" ] && [ ! -e "$MARKER" ]; then exit 0; fi
    # A guard run must not act on a marker from a session that was just replaced.
    exec /usr/bin/lockf -k -t 10 "$LOCK" "$0" locked "$@"
    ;;
locked)
    [ "$(/usr/bin/id -u)" -eq 0 ] || exit 77
    shift
    ;;
*)
    exit 64
    ;;
esac

case "${1:-}" in
enable|enable-limited|enable-until)
    minutes=0 battery=$LOW_BATTERY_PERCENT thermal=0
    if [ "$1" != "enable" ]; then
        [ "$#" -eq 4 ] && uint "$3" 100 &&
            [ "$3" -gt 0 ] && uint "$4" 3 || invalid
        if [ "$1" = "enable-limited" ]; then
            uint "$2" 1440 || invalid
            minutes=$2
        fi
        battery=$3 thermal=$4
        if ! /bin/launchctl print "$GUARD" >/dev/null 2>&1; then
            echo "The LidClosed background guard is not loaded. Run the full installer." >&2
            exit 1
        fi
    fi

    state=
    if [ "$thermal" -gt 0 ]; then
        if ! state=$(thermal_state) || ! uint "$state" 3; then
            echo "LidClosed could not read the macOS thermal state. Try again." >&2
            exit 1
        fi
    fi
    reason=$("$PMSET" -g batt | limit_reason 0 0 "$battery" "$thermal" "$state")
    if [ -n "$reason" ]; then
        echo "$reason" >&2
        exit 1
    fi
    current=$("$PMSET" -g)
    if sleep_is_disabled "$current"; then
        echo "System sleep is already disabled. LidClosed did not take ownership." >&2
        exit 1
    fi

    deadline=0
    if [ "$1" = "enable-until" ]; then
        validate_future_deadline "$2" "$(/bin/date +%s)"
        deadline=$2
    elif [ "$minutes" -gt 0 ]; then
        now=$(/bin/date +%s)
        deadline=$((now + minutes * 60))
    fi
    # Persist recovery information first: an interruption must not strand pmset enabled.
    write_session "$deadline" "$battery" "$thermal"
    if ! "$PMSET" disablesleep 1; then
        if current=$("$PMSET" -g) && ! sleep_is_disabled "$current"; then
            /bin/rm -f "$MARKER"
        fi
        exit 1
    fi
    log "sleep override enabled; session marker written"
    ;;

set-duration|set-deadline)
    now=$(/bin/date +%s)
    [ "$#" -eq 2 ] || invalid
    if [ "$1" = "set-duration" ]; then
        uint "$2" 1440 || invalid
        new_deadline=0
        if [ "$2" -gt 0 ]; then new_deadline=$((now + $2 * 60)); fi
    else
        validate_future_deadline "$2" "$now"
        new_deadline=$2
    fi
    current=$("$PMSET" -g)
    if ! read_session || ! sleep_is_disabled "$current" ||
        { [ "$deadline" -gt 0 ] && [ "$now" -ge "$deadline" ]; }; then
        echo "The Lid Closed session is no longer active." >&2
        exit 1
    fi
    if ! /bin/launchctl print "$GUARD" >/dev/null 2>&1; then
        echo "The LidClosed background guard is not loaded. Run the full installer." >&2
        exit 1
    fi
    write_session "$new_deadline" "$battery" "$thermal"
    log "active session deadline updated"
    ;;

disable)
    restore_sleep
    log "sleep override removed; marker cleared"
    ;;

cleanup)
    # bootstrap on reinstall also runs this; leave a live session alone.
    if /usr/bin/pgrep -x LidClosed > /dev/null 2>&1; then
        log "cleanup: LidClosed is running, leaving the override alone"
        exit 0
    fi
    if [ -e "$MARKER" ]; then
        restore_sleep
        log "boot cleanup: restored system sleep left disabled by a previous session"
    fi
    ;;

battery-guard)
    [ -f "$MARKER" ] || exit 0
    # Legacy timestamp markers retain their original battery protection.
    if ! read_session; then
        deadline=0 battery=$LOW_BATTERY_PERCENT thermal=0
    fi

    current=$("$PMSET" -g)
    if ! sleep_is_disabled "$current"; then
        /bin/rm -f "$MARKER"
        exit 0
    fi
    now=$(/bin/date +%s)
    state=
    if [ "$thermal" -gt 0 ]; then state=$(thermal_state) || state=; fi
    reason=$("$PMSET" -g batt | limit_reason "$now" "$deadline" "$battery" "$thermal" "$state")
    if [ -n "$reason" ]; then
        restore_sleep
        log "session guard: $reason Restored system sleep."
    fi
    ;;
*)
    exit 64
    ;;
esac
