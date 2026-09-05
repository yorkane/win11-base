#!/bin/bash
# Rebuild image/vda/vda-payload.tar.gz from the official spice-guest-tools installer.
# The win32 binaries (vioser driver + vdservice/vdagent) cannot be produced on this
# Linux box by compiling, but they CAN be extracted from the signed upstream installer --
# unlike node_modules, nothing here is version-locked to a live guest.
# usage: vda_build_payload.sh [path-to-spice-guest-tools.exe]
set -euo pipefail
EXE="${1:-/home/aigc/ChatGPT/docker-w11-wx/shared/spice-guest-tools.exe}"
DST_DIR="$(cd "$(dirname "$0")/.." && pwd)/image/vda"
test -f "$EXE" || { echo "installer not found: $EXE"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
7z x -y -o"$TMP/x" "$EXE" >/dev/null
# NSIS: the real payload lives in one of the inner bins (app.7z / *.dll stubs). Extract
# recursively until the wanted files surface.
for inner in "$TMP"/x/app.7z "$TMP"/x/*.7z; do
  [ -f "$inner" ] || continue
  7z x -y -o"$TMP/inner" "$inner" >/dev/null || true
done
find "$TMP" -iname "vdagent.exe" -o -iname "vdservice.exe" | head
D=$(find "$TMP" -type d -iname "VdiGuestTools" -o -type d -iname "*guest*" | head -1)
test -n "$D" || { echo "could not locate the extracted tools dir -- inspect $TMP manually"; exit 1; }
mkdir -p "$TMP/stage/vioserial"
cp "$D/vdagent.exe" "$D/vdservice.exe" "$TMP/stage/"
cp "$D"/vioserial/* "$TMP/stage/vioserial/"
tar -czf "$DST_DIR/vda-payload.tar.gz" -C "$TMP/stage" .
sha256sum "$DST_DIR/vda-payload.tar.gz" | cut -c1-12
