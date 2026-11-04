#!/bin/bash
# Builds Hangar in release mode, installs hangar-server (and hangar, once it exists) into /usr/local/bin,
# and (re)loads the app.hangar.server launchd agent for the current user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
LABEL="app.hangar.server"
PLIST_TEMPLATE="$ROOT/scripts/server/$LABEL.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Escapes a value for use as a sed replacement with the | delimiter.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Renders the plist template: render_plist <binary> <home> > file
render_plist() {
    sed -e "s|__BINARY__|$(sed_escape "$1")|g" -e "s|__HOME__|$(sed_escape "$2")|g" "$PLIST_TEMPLATE"
}

# Runs a command, with sudo only when the install directory is not writable.
as_installer() {
    if [ -w "$INSTALL_DIR" ]; then "$@"; else sudo "$@"; fi
}

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -d "$INSTALL_DIR" ]; then
    as_installer mkdir -p "$INSTALL_DIR"
fi
as_installer install -m 755 "$BIN_DIR/hangar-server" "$INSTALL_DIR/hangar-server"
if [ -x "$BIN_DIR/hangar" ]; then
    as_installer install -m 755 "$BIN_DIR/hangar" "$INSTALL_DIR/hangar"
else
    echo "note: no hangar CLI in the build output yet; skipping it"
fi

mkdir -p "$HOME/Library/Logs/Hangar" "$HOME/Library/LaunchAgents"
render_plist "$INSTALL_DIR/hangar-server" "$HOME" > "$PLIST_DEST"
plutil -lint "$PLIST_DEST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout can return before the job is gone; wait up to 10 s so bootstrap does not fail with an I/O error.
for _ in $(seq 1 20); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
# Retry a few times in case the unload is still finishing.
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"; then break; fi
    if [ "$attempt" = 5 ]; then echo "error: launchctl bootstrap failed" >&2; exit 1; fi
    sleep 1
done

echo "hangar-server installed and started. Log: $HOME/Library/Logs/Hangar/server.log"
