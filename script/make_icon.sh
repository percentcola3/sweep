#!/usr/bin/env bash
# Regenerate Support/AppIcon.icns from the ImageGen master artwork.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$ROOT_DIR/SimpleMole/Support/AppIcon-1024.png"
if [[ ! -f "$MASTER" ]]; then
    echo "error: icon master not found at $MASTER" >&2
    exit 1
fi

cp "$MASTER" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    if [[ $double -le 1024 ]]; then
        sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
cp "$WORK/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

perl "$ROOT_DIR/script/pack_icns.pl" \
    "$ICONSET" "$ROOT_DIR/SimpleMole/Support/AppIcon.icns"
echo "Wrote $ROOT_DIR/SimpleMole/Support/AppIcon.icns"
