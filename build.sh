#!/bin/bash
# Builds Files in Release configuration and stages it at dist/.build/Files.app.
# Does not install, run tests, or touch /Applications.
#
# The output lives under a hidden directory on purpose, following the pattern
# used by ../quadrant: Spotlight does not index hidden items, and Spotlight's
# application index is what the macOS launcher lists. A bundle built in a
# visible directory appears as another Files beside the installed one.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild was not found." >&2
    echo "Install Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: xcodebuild is present but not usable." >&2
    echo "Install a full Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

DIST="$SCRIPT_DIR/dist"
APP="$DIST/.build/Files.app"
DERIVED_DATA="$DIST/.derivedData"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Remove stale visible build output and unregister it from LaunchServices, so
# those copies no longer appear in the launcher. All current output is hidden
# (dist/.build, dist/.derivedData).
STALE_APPS=(
    "$SCRIPT_DIR/build/Files.app"
    "$SCRIPT_DIR/build/DerivedData/Build/Products/Release/Files.app"
)
if [[ -x "$LSREGISTER" ]]; then
    for stale in "${STALE_APPS[@]}"; do
        if [[ -d "$stale" ]]; then
            "$LSREGISTER" -u "$stale" >/dev/null 2>&1 || true
        fi
    done
fi
for stale in "${STALE_APPS[@]}"; do
    if [[ -e "$stale" ]]; then
        rm -rf "$stale"
    fi
done
rm -rf "$SCRIPT_DIR/build/DerivedData"

mkdir -p "$DIST/.build"
rm -rf "$APP"

echo "Building Files (Release, arm64)…"
xcodebuild \
    -project "$SCRIPT_DIR/Files.xcodeproj" \
    -scheme Files \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Files.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: build succeeded but $BUILT_APP was not found." >&2
    exit 1
fi

# Stage a complete copy in a hidden directory and validate it.
ditto "$BUILT_APP" "$APP"

EXECUTABLE="$APP/Contents/MacOS/Files"
if [[ ! -f "$EXECUTABLE" ]]; then
    echo "error: staged bundle is missing Contents/MacOS/Files." >&2
    rm -rf "$APP"
    exit 1
fi
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: staged executable is not executable." >&2
    rm -rf "$APP"
    exit 1
fi

ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
if [[ "$ARCHS" != *arm64* ]]; then
    echo "error: staged executable is not an arm64 binary (architectures: ${ARCHS:-unknown})." >&2
    rm -rf "$APP"
    exit 1
fi

# xcodebuild registers its product with LaunchServices. Unregister the build
# copies again: only the installed application should be a launcher entry.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
fi

echo "Built: $APP"
echo "Install: ./install.sh"
