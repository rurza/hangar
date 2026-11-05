#!/bin/sh
# Moves this Mac's worker back from the hangar user's LaunchDaemon to the current user's launch agent: the same
# machine and token, the hangar user's current binary. The hangar user stays; its build cache is removed.
# Run it in Terminal as an administrator, without sudo; it asks for your password once.
set -eu

LABEL=app.hangar.worker
HANGAR_HOME=/Users/hangar
DAEMON=/Library/LaunchDaemons/$LABEL.plist
CONFIG_DIR="$HOME/Library/Application Support/Hangar/worker"
BIN="$HOME/.local/bin/hangar-worker"
LOGS="$HOME/Library/Logs/Hangar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

sudo -v

echo "Stopping hangar's worker daemon..."
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "$DAEMON"

echo "Copying the worker and its configuration back to $(id -un)..."
mkdir -p "$HOME/.local/bin" "$LOGS" "$HOME/Library/LaunchAgents"
mkdir -p -m 700 "$CONFIG_DIR"
sudo install -o "$(id -un)" -g staff -m 755 "$HANGAR_HOME/.local/bin/hangar-worker" "$BIN"
sudo cat "$HANGAR_HOME/Library/Application Support/Hangar/worker/config.json" \
    | /usr/bin/python3 -c 'import json, sys; c = json.load(sys.stdin); c["dataDirectory"] = sys.argv[1]; c.pop("workDirectory", None); json.dump(c, sys.stdout, indent=2)' "$CONFIG_DIR" \
    >"$CONFIG_DIR/config.json.new"
chmod 600 "$CONFIG_DIR/config.json.new"
mv -f "$CONFIG_DIR/config.json.new" "$CONFIG_DIR/config.json"

echo "Removing hangar's build cache..."
sudo rm -rf "$HANGAR_HOME/.hangar/worker/workspaces" "$HANGAR_HOME/.hangar/worker/jobs" "$HANGAR_HOME/.hangar/worker/tmp"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Standard</string>
    <key>StandardOutPath</key>
    <string>$LOGS/worker.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/worker.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
"$BIN" check && echo "Done: the worker runs as $(id -un) again. Log: $LOGS/worker.log"
