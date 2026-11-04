#!/bin/bash
# Builds Hangar in release mode, installs hangar-worker into /usr/local/bin, writes its configuration and
# (re)loads the app.hangar.worker launchd agent in the current user's GUI session. Run it as the build user.
#
# Usage: install-worker.sh --server <url> --token <token>
#
# The token can instead come from the HANGAR_WORKER_TOKEN environment variable, which keeps it out of shell
# history and the process list:
#   HANGAR_WORKER_TOKEN=<token> install-worker.sh --server <url>
set -euo pipefail

usage() { echo "usage: $0 --server <url> --token <token>   (or set HANGAR_WORKER_TOKEN)" >&2; exit 2; }

SERVER=""
TOKEN="${HANGAR_WORKER_TOKEN:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --server) [ $# -ge 2 ] || usage; SERVER="$2"; shift 2 ;;
        --token) [ $# -ge 2 ] || usage; TOKEN="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$SERVER" ] && [ -n "$TOKEN" ] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
LABEL="app.hangar.worker"
PLIST_TEMPLATE="$ROOT/scripts/worker/$LABEL.plist"
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
swift build -c release --product hangar-worker
BIN_DIR="$(swift build -c release --show-bin-path)"

if [ ! -d "$INSTALL_DIR" ]; then
    as_installer mkdir -p "$INSTALL_DIR"
fi
as_installer install -m 755 "$BIN_DIR/hangar-worker" "$INSTALL_DIR/hangar-worker"

# The token goes through the environment, never the argument list.
HANGAR_WORKER_TOKEN="$TOKEN" "$INSTALL_DIR/hangar-worker" setup --server "$SERVER"

mkdir -p "$HOME/Library/Logs/Hangar" "$HOME/Library/LaunchAgents"
render_plist "$INSTALL_DIR/hangar-worker" "$HOME" > "$PLIST_DEST"
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

echo "hangar-worker installed and started. Log: $HOME/Library/Logs/Hangar/worker.log"
