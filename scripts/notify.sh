#!/bin/sh
# Get the user's attention: notification + sound + an alert that stays until dismissed.
# Usage: scripts/notify.sh "Message" ["Title"]
msg="$1"; title="${2:-ICA client}"
osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1
afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
nohup osascript -e "tell application \"System Events\" to display alert \"$title\" message \"$msg\" as critical" >/dev/null 2>&1 &
