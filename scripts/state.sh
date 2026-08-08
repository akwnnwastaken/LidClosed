#!/bin/bash
# ============================================================
#  LidClosed — state inspector
#
#  Prints everything needed to verify what the app is actually
#  doing. Safe to run at any time: reads only, changes nothing.
#
#  Usage:  ./scripts/state.sh
# ============================================================

STATE_FILE="$HOME/Library/Application Support/LidClosed/state.json"

printf '%-14s ' "app:"
if APP_PID=$(pgrep -x LidClosed | head -1); [ -n "$APP_PID" ]; then
    STARTED=$(ps -p "$APP_PID" -o lstart= 2>/dev/null | tr -s ' ')
    echo "running (pid $APP_PID, since$STARTED)"
else
    echo "not running"
fi

printf '%-14s ' "lid closed:"
SLEEP_DISABLED=$(/usr/bin/pmset -g | awk '/SleepDisabled/ {print $2}')
if [ "$SLEEP_DISABLED" = "1" ]; then
    if [ -f "$STATE_FILE" ]; then
        echo "ON  — owned by LidClosed"
    else
        echo "ON  — set outside LidClosed (no state file)"
    fi
else
    echo "off"
fi

printf '%-14s ' "keep awake:"
# Matched on -dimsu so an unrelated caffeinate (other tools use plain -i) is not
# mistaken for ours.
if CAFF=$(pgrep -f 'caffeinate -dimsu' | head -1); [ -n "$CAFF" ]; then
    echo "ON  — caffeinate pid $CAFF ($(ps -p "$CAFF" -o args= | tr -s ' '))"
else
    echo "off"
fi

printf '%-14s ' "state file:"
if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"; echo
else
    echo "none"
fi

printf '%-14s ' "display:"
/usr/bin/pmset -g | awk '/displaysleep/ {$1=""; print substr($0,2)}'

# Any caffeinate that is not ours, so it is not misread as a leak.
OTHER=$(pgrep -f caffeinate | while read -r p; do
    ps -p "$p" -o args= 2>/dev/null | grep -qv -- '-dimsu' && ps -p "$p" -o pid=,args= 2>/dev/null
done | grep -v -- '-dimsu')
if [ -n "$OTHER" ]; then
    echo
    echo "other caffeinate processes (not LidClosed's):"
    echo "$OTHER" | sed 's/^/  /'
fi
