#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v iconutil >/dev/null 2>&1; then
  echo "This script requires iconutil (macOS)." >&2
  exit 1
fi
iconutil -c icns "$DIR/FilesIcon.iconset" -o "$DIR/FilesIcon.icns"
echo "Generated: $DIR/FilesIcon.icns"
