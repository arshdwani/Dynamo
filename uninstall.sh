#!/bin/bash
# Removes Dynamo and hands charging back to macOS.
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

LABEL=io.github.arshdwani.dynamo
DIR="/Library/Application Support/Dynamo"

pkill -x Dynamo 2>/dev/null || true
# Stopping the daemon re-enables charging; restore again in case it was not running.
launchctl bootout "system/$LABEL" 2>/dev/null || true
if [[ -x "$DIR/dynamo" ]]; then "$DIR/dynamo" restore || true; fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/bin/dynamo /etc/newsyslog.d/dynamo.conf
rm -f /var/log/dynamo.log*
rm -rf "$DIR" /Applications/Dynamo.app
echo "Dynamo removed; charging is back under macOS control."
