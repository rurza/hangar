#!/usr/bin/env bash
# Spike: can an App Store Connect API key export a Developer ID build through
# cloud-managed signing? Exit 0 on PASS, 1 on FAIL, 2 on bad usage.
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") --archive <path.xcarchive> --team <TEAMID> --key-id <ID> \\
                        --issuer-id <ID> --key <AuthKey.p8> [--out <dir>]

  --archive     Path to a macOS .xcarchive to export
  --team        Apple Developer Team ID
  --key-id      App Store Connect API key ID
  --issuer-id   App Store Connect API issuer ID
  --key         Path to the AuthKey .p8 file
  --out         Output directory (default: a fresh temp dir)
USAGE
  exit 2
}

archive="" team="" key_id="" issuer_id="" key="" out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive|--team|--key-id|--issuer-id|--key|--out)
      [[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; usage; }
      case "$1" in
        --archive) archive="$2" ;;
        --team) team="$2" ;;
        --key-id) key_id="$2" ;;
        --issuer-id) issuer_id="$2" ;;
        --key) key="$2" ;;
        --out) out="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

for pair in archive:--archive team:--team key_id:--key-id issuer_id:--issuer-id key:--key; do
  var="${pair%%:*}"; flag="${pair#*:}"
  [[ -n "${!var}" ]] || { echo "error: missing $flag" >&2; usage; }
done
[[ -d "$archive" ]] || { echo "error: archive not found: $archive" >&2; exit 2; }
[[ -f "$key" ]] || { echo "error: key file not found: $key" >&2; exit 2; }

if [[ -z "$out" ]]; then
  out="$(mktemp -d "${TMPDIR:-/tmp}/hangar-spike.XXXXXX")"
else
  mkdir -p "$out"
fi

plist="$out/ExportOptions.plist"
export_path="$out/export"
log="$out/xcodebuild.log"
sign_log="$out/codesign.log"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$team</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>destination</key>
  <string>export</string>
</dict>
</plist>
PLIST

echo "Output directory: $out"

fail() {
  echo "RESULT: FAIL"
  echo "$1"
  echo "--- last 40 lines of $log ---"
  tail -n 40 "$log" 2>/dev/null || true
  exit 1
}

if ! xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$plist" \
    -exportPath "$export_path" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$key" \
    -authenticationKeyID "$key_id" \
    -authenticationKeyIssuerID "$issuer_id" >"$log" 2>&1; then
  fail "xcodebuild -exportArchive failed"
fi

shopt -s nullglob
apps=("$export_path"/*.app)
shopt -u nullglob
[[ ${#apps[@]} -gt 0 ]] || fail "export succeeded but no .app found in $export_path"

# codesign writes to stderr; capture both streams.
codesign -dvv --verbose=2 "${apps[0]}" >"$sign_log" 2>&1 || true
cat "$sign_log"

if grep -q 'Authority=Developer ID Application' "$sign_log"; then
  echo "RESULT: PASS"
  tail -n 40 "$log"
  exit 0
fi
fail "app is not signed with a Developer ID Application authority"
