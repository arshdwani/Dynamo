#!/bin/bash
# Builds and installs Dynamo: root daemon, CLI, and menu bar app.
# Safe to re-run to upgrade; your settings are kept.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=io.github.arshdwani.dynamo
DIR="/Library/Application Support/Dynamo"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [[ $(uname -m) != arm64 ]]; then
    echo "Dynamo supports Apple Silicon Macs only." >&2; exit 1
fi

if [[ $EUID -ne 0 ]]; then
    ./build.sh
    exec sudo "$0" "$@"
fi

if pgrep -if "aldente" >/dev/null; then
    echo "AlDente (or its helper) is still running. Two charge limiters will fight over the SMC." >&2
    echo "Quit AlDente and remove its helper first (AlDente > Settings > Uninstall, or:" >&2
    echo "  sudo launchctl bootout system/com.apphousekitchen.aldente-pro.helper)" >&2
    exit 1
fi

USER_NAME="${SUDO_USER:-$(stat -f %Su /dev/console)}"

echo "Installing background service..."
launchctl bootout "system/$LABEL" 2>/dev/null || true
install -d -o root -g wheel -m 755 "$DIR"

# Upgrade from the pre-rename "ChargeLimit" builds: keep settings and history.
OLD_DIR="/Library/Application Support/ChargeLimit"
if [[ -d "$OLD_DIR" || -f /Library/LaunchDaemons/com.local.chargelimit.plist ]]; then
    echo "Migrating from ChargeLimit..."
    launchctl bootout system/com.local.chargelimit 2>/dev/null || true
    pkill -x ChargeLimit 2>/dev/null || true
    for f in config.json history.json state.json; do
        if [[ -f "$OLD_DIR/$f" && ! -f "$DIR/$f" ]]; then cp "$OLD_DIR/$f" "$DIR/$f"; fi
    done
    rm -rf "$OLD_DIR" /Applications/ChargeLimit.app
    rm -f /Library/LaunchDaemons/com.local.chargelimit.plist /usr/local/bin/chargelimit \
          /etc/newsyslog.d/chargelimit.conf /var/log/chargelimit.log*
fi

install -o root -g wheel -m 755 build/dynamo "$DIR/dynamo"
mkdir -p /usr/local/bin
ln -sf "$DIR/dynamo" /usr/local/bin/dynamo

if [[ ! -f "$DIR/config.json" ]]; then
    cat > "$DIR/config.json" <<'JSON'
{
  "calibrate" : false,
  "discharge" : false,
  "enabled" : true,
  "heatMaxC" : 35,
  "heatProtection" : false,
  "limit" : 80,
  "magsafeLED" : true,
  "preventSleepWhileCharging" : true,
  "sailing" : 5,
  "topUp" : false
}
JSON
fi
# The menu bar app runs as you, so it needs to be able to write the settings.
chown root:staff "$DIR/config.json"
chmod 664 "$DIR/config.json"

install -o root -g wheel -m 644 "Resources/$LABEL.plist" "$PLIST"
install -o root -g wheel -m 644 Resources/dynamo.newsyslog.conf /etc/newsyslog.d/dynamo.conf
launchctl bootstrap system "$PLIST"

# Remember where the source lives so the app's Update button can pull and reinstall.
echo "$PWD" > "$DIR/source-path"
chmod 644 "$DIR/source-path"

echo "Installing app..."
if ! codesign --verify --deep build/Dynamo.app 2>/dev/null; then
    echo "build/Dynamo.app is incomplete (was a build running at the same time?). Run ./install.sh again." >&2
    exit 1
fi
pkill -x Dynamo 2>/dev/null || true
rm -rf /Applications/Dynamo.app
cp -R build/Dynamo.app /Applications/
chown -R "$USER_NAME":staff /Applications/Dynamo.app
touch /Applications/Dynamo.app  # refresh the Finder/Dock icon cache
sudo -u "$USER_NAME" open /Applications/Dynamo.app || echo "Open Dynamo from your Applications folder." >&2

sleep 3
if ! launchctl print "system/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "Warning: the background service did not start. See /var/log/dynamo.log" >&2
fi
/usr/local/bin/dynamo status
echo
echo "Done. Dynamo is in your menu bar. Logs: /var/log/dynamo.log"
