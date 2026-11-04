#!/bin/bash
# Builds Hangar in release mode, installs hangar-worker into a bin directory (default /usr/local/bin), writes its configuration and
# (re)loads the app.hangar.worker launchd agent in the current user's GUI session. Run it as the build user.
#
# Usage: install-worker.sh --server <url> --token <token> [--bin-dir <dir>]
#   --bin-dir <dir>      where to install (default /usr/local/bin). Created if missing; sudo is used only when it
#                        is not writable, so `--bin-dir ~/.local/bin` installs without sudo.
#   --render-only <out>  for testing: write the launchd plist for the chosen --bin-dir to <out> and exit, without
#                        building or installing anything (--server and --token are not needed).
#
# Keep the token out of the process list and shell history by passing it in the environment:
#   read -rs HANGAR_WORKER_TOKEN; export HANGAR_WORKER_TOKEN
#   install-worker.sh --server <url>
# When neither --token nor HANGAR_WORKER_TOKEN is set and stdin is a terminal, the script asks for it (input hidden).
# --token works too, but then the token is visible in `ps` for as long as this script runs (the whole release
# build) and stays in shell history.
set -euo pipefail

usage() { echo "usage: $0 --server <url> --token <token> [--bin-dir <dir>]   (or set HANGAR_WORKER_TOKEN)" >&2; exit 2; }

SERVER=""
INSTALL_DIR="/usr/local/bin"
RENDER_ONLY=""
TOKEN="${HANGAR_WORKER_TOKEN:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --server) [ $# -ge 2 ] || usage; SERVER="$2"; shift 2 ;;
        --token) [ $# -ge 2 ] || usage; TOKEN="$2"; shift 2 ;;
        --bin-dir) [ $# -ge 2 ] || usage; INSTALL_DIR="$2"; shift 2 ;;
        --render-only) [ $# -ge 2 ] || usage; RENDER_ONLY="$2"; shift 2 ;;
        *) usage ;;
    esac
done
# Expand a leading ~ and make the path absolute: the plist needs an absolute binary path.
case "$INSTALL_DIR" in
    "~") INSTALL_DIR="$HOME" ;;
    "~/"*) INSTALL_DIR="$HOME/${INSTALL_DIR#"~/"}" ;;
esac
case "$INSTALL_DIR" in /*) ;; *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;; esac
INSTALL_DIR="${INSTALL_DIR%/}"
[ -n "$INSTALL_DIR" ] || INSTALL_DIR="/"

if [ -z "$RENDER_ONLY" ] && [ -z "$TOKEN" ] && [ -t 0 ]; then
    read -rs -p "Worker token: " TOKEN
    echo
fi
[ -n "$RENDER_ONLY" ] || { [ -n "$SERVER" ] && [ -n "$TOKEN" ] || usage; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

if [ -n "$RENDER_ONLY" ]; then
    render_plist "$INSTALL_DIR/hangar-worker" "$HOME" > "$RENDER_ONLY"
    exit 0
fi

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
