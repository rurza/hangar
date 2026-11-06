#!/bin/bash
# Builds Hangar in release mode, installs hangar-server with its web UI bundle, hangar-worker (which the server hands
# out to `curl <server>/install | sh` on new build Macs) and hangar, when it was built, into a bin directory, and
# (re)loads the app.hangar.server launchd agent for the current user.
#
# Usage: install-server.sh [--bin-dir <dir>]
#   --bin-dir <dir>      where to install (default /usr/local/bin). Created if missing; sudo is used only when it
#                        is not writable, so `--bin-dir ~/.local/bin` installs without sudo.
#   --render-only <out>  for testing: write the launchd plist for the chosen --bin-dir to <out> and exit, without
#                        building or installing anything.
#   --check-bin-dir      for testing: create the --bin-dir as the install would, report whether sudo is needed
#                        to write to it, and exit.
set -euo pipefail

usage() { echo "usage: $0 [--bin-dir <dir>]" >&2; exit 2; }

INSTALL_DIR="/usr/local/bin"
RENDER_ONLY=""
CHECK_BIN_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bin-dir) [ $# -ge 2 ] || usage; INSTALL_DIR="$2"; shift 2 ;;
        --render-only) [ $# -ge 2 ] || usage; RENDER_ONLY="$2"; shift 2 ;;
        --check-bin-dir) CHECK_BIN_DIR=1; shift ;;
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LABEL="app.hangar.server"
PLIST_TEMPLATE="$ROOT/scripts/server/$LABEL.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Escapes a value for use as a sed replacement with the | delimiter.
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Escapes a value for use as XML text.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Renders the plist template: render_plist <binary> <home> > file
render_plist() {
    sed -e "s|__BINARY__|$(sed_escape "$(xml_escape "$1")")|g" -e "s|__HOME__|$(sed_escape "$(xml_escape "$2")")|g" "$PLIST_TEMPLATE"
}

# Runs a command, with sudo only when the install directory is not writable.
as_installer() {
    if [ -w "$INSTALL_DIR" ]; then "$@"; else sudo "$@"; fi
}

# Creates the install directory: unprivileged first, so a new directory under $HOME stays user-owned; sudo only
# when that fails.
ensure_install_dir() {
    [ -d "$INSTALL_DIR" ] || mkdir -p "$INSTALL_DIR" 2>/dev/null || sudo mkdir -p "$INSTALL_DIR"
}

if [ -n "$CHECK_BIN_DIR" ]; then
    ensure_install_dir
    if [ -w "$INSTALL_DIR" ]; then echo "$INSTALL_DIR: writable, no sudo needed"; else echo "$INSTALL_DIR: not writable, sudo needed"; fi
    exit 0
fi

if [ -n "$RENDER_ONLY" ]; then
    render_plist "$INSTALL_DIR/hangar-server" "$HOME" > "$RENDER_ONLY"
    exit 0
fi

cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
# hangar-worker is built universal (Apple silicon and Intel), so the server can hand it to any build Mac.
WORKER_BUILD=(swift build -c release --product hangar-worker --arch arm64 --arch x86_64)
"${WORKER_BUILD[@]}"
WORKER_BIN_DIR="$("${WORKER_BUILD[@]}" --show-bin-path)"

ensure_install_dir
as_installer install -m 755 "$BIN_DIR/hangar-server" "$INSTALL_DIR/hangar-server"
# The web UI's files live in the SwiftPM resource bundle, which hangar-server looks for next to itself.
WEB_BUNDLE="Hangar_HangarServer.bundle"
if [ ! -d "$BIN_DIR/$WEB_BUNDLE" ]; then
    echo "error: $BIN_DIR/$WEB_BUNDLE is missing from the build output" >&2
    exit 1
fi
as_installer rm -rf "${INSTALL_DIR:?}/$WEB_BUNDLE"
as_installer cp -R "$BIN_DIR/$WEB_BUNDLE" "$INSTALL_DIR/$WEB_BUNDLE"
# The server serves the hangar-worker next to it at /install/hangar-worker. -S replaces it by renaming, so a worker
# already running from this directory keeps its old copy until launchd restarts it.
if [ ! -x "$WORKER_BIN_DIR/hangar-worker" ]; then
    echo "error: $WORKER_BIN_DIR/hangar-worker is missing from the build output" >&2
    exit 1
fi
# VM builds need the virtualization entitlement, which any signature carries. Signed before it is hashed or
# copied, so the SHA-256 the server announces and the self-update compares is the signed binary's.
# A Developer ID identity, when this Mac has one, keeps the worker's identity the same across updates, so macOS
# asks once for its Local Network access (the VMs' SSH) instead of after every update, as it does for an ad hoc
# signature. HANGAR_WORKER_SIGNING_IDENTITY picks another identity; "-" forces ad hoc.
WORKER_SIGNING_IDENTITY="${HANGAR_WORKER_SIGNING_IDENTITY:-}"
if [ -z "$WORKER_SIGNING_IDENTITY" ]; then
    WORKER_SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)
fi
if [ -n "$WORKER_SIGNING_IDENTITY" ] && [ "$WORKER_SIGNING_IDENTITY" != "-" ] \
    && codesign --force --sign "$WORKER_SIGNING_IDENTITY" --identifier app.hangar.worker --timestamp=none \
        --entitlements "$ROOT/scripts/worker/hangar-worker.entitlements" "$WORKER_BIN_DIR/hangar-worker"; then
    echo "Signed hangar-worker with $WORKER_SIGNING_IDENTITY"
else
    codesign --force --sign - --identifier app.hangar.worker \
        --entitlements "$ROOT/scripts/worker/hangar-worker.entitlements" "$WORKER_BIN_DIR/hangar-worker"
    echo "Signed hangar-worker ad hoc (macOS asks again for Local Network access after each update)"
fi
as_installer install -S -m 755 "$WORKER_BIN_DIR/hangar-worker" "$INSTALL_DIR/hangar-worker"
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
