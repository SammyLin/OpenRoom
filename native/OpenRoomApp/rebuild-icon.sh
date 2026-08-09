#!/bin/bash
# Rebuild Resources/OpenRoom.icns from deterministic SVG source.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="Resources/OpenRoom.svg"
ICONSET="$(mktemp -d)/OpenRoom.iconset"
trap 'rm -rf "${ICONSET%/*}"' EXIT
mkdir -p "$ICONSET"

if ! command -v magick >/dev/null 2>&1; then
  echo "error: ImageMagick 'magick' is required" >&2
  exit 1
fi

render() {
  local pixels="$1"
  local output="$2"
  magick -background none "$SOURCE" -resize "${pixels}x${pixels}" \
    -depth 8 -define png:color-type=6 "$ICONSET/$output"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

if ! iconutil -c icns "$ICONSET" -o Resources/OpenRoom.icns; then
  # macOS 26 iconutil can reject valid iconsets, including its own round trips.
  # ICNS stores PNG payloads in typed, big-endian chunks.
  python3 - "$ICONSET" Resources/OpenRoom.icns <<'PY'
import pathlib
import struct
import sys

iconset = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
chunks = (
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)
payload = b"".join(
    kind + struct.pack(">I", len(data) + 8) + data
    for kind, name in chunks
    for data in [(iconset / name).read_bytes()]
)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
fi
echo "rebuilt: $(pwd)/Resources/OpenRoom.icns"
