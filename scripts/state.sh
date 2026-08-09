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
INSTALLED_PLIST="/Applications/LidClosed.app/Contents/Info.plist"
HELPER="/Library/PrivilegedHelperTools/com.akwnnwastaken.LidClosed.helper"
DAEMON_LABEL="com.akwnnwastaken.LidClosed.cleanup"
MARKER="/var/db/com.akwnnwastaken.LidClosed.active"

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

# Which build is in /Applications. Stamped by install.sh from git, because answering this
# by comparing file timestamps against the log turned out to be genuinely confusing.
printf '%-14s ' "installed:"
if [ -f "$INSTALLED_PLIST" ]; then
    VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALLED_PLIST" 2>/dev/null)
    BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INSTALLED_PLIST" 2>/dev/null)
    SHA=$(/usr/libexec/PlistBuddy -c "Print :LidClosedGitCommit" "$INSTALLED_PLIST" 2>/dev/null)
    if [ -n "$SHA" ]; then
        echo "v$VER (build $BUILD, commit $SHA)"
    else
        echo "v$VER (build $BUILD, no commit stamp — installed before version stamping)"
    fi
else
    echo "not installed in /Applications"
fi

printf '%-14s ' "helper:"
if [ -x "$HELPER" ]; then
    echo "installed ($(/usr/bin/stat -f '%Su:%Sg %Sp' "$HELPER"))"
else
    echo "missing — app falls back to calling pmset directly, no cleanup at restart"
fi

printf '%-14s ' "boot daemon:"
if /bin/launchctl print "system/$DAEMON_LABEL" > /dev/null 2>&1; then
    echo "loaded ($DAEMON_LABEL)"
elif [ -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist" ]; then
    echo "plist present but not loaded"
else
    echo "not installed"
fi

# Root-owned, mode 600: existence is visible to anyone, contents are not.
printf '%-14s ' "boot marker:"
if [ -e "$MARKER" ]; then
    echo "present — sleep will be restored at next boot if not restored before then"
else
    echo "none"
fi

# Any caffeinate that is not ours, so it is not misread as a leak.
OTHER=$(pgrep -f caffeinate | while read -r p; do
    ps -p "$p" -o args= 2>/dev/null | grep -qv -- '-dimsu' && ps -p "$p" -o pid=,args= 2>/dev/null
done | grep -v -- '-dimsu')
if [ -n "$OTHER" ]; then
    echo
    echo "other caffeinate processes (not LidClosed's):"
    echo "$OTHER" | sed 's/^/  /'
fi
