#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /path/to/Files.app" >&2
  exit 2
fi
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
if [ ! -d "$APP/Contents" ] || [ ! -f "$APP/Contents/Info.plist" ]; then
  echo "Expected an existing macOS .app bundle containing Contents/Info.plist: $APP" >&2
  exit 2
fi
if [ ! -f "$DIR/FilesIcon.icns" ]; then
  echo "Missing $DIR/FilesIcon.icns" >&2
  exit 2
fi
if [ ! -x /usr/libexec/PlistBuddy ]; then
  echo "PlistBuddy not found (this helper runs on macOS)." >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources"
cp "$DIR/FilesIcon.icns" "$APP/Contents/Resources/FilesIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile FilesIcon' "$APP/Contents/Info.plist"   || /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string FilesIcon' "$APP/Contents/Info.plist"
echo "Embedded Files icon into: $APP"
