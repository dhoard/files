#!/bin/bash
# Installs an already-built dist/.build/Files.app to /Applications/Files.app
# and refreshes the icon/launcher caches. Never builds, never launches the app,
# never deletes preferences.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/dist/.build/Files.app"
DESTINATION="/Applications/Files.app"

if [[ ! -d "$SOURCE" ]]; then
    echo "error: $SOURCE was not found." >&2
    echo "Build it first with: $SCRIPT_DIR/build.sh" >&2
    exit 1
fi

EXECUTABLE="$SOURCE/Contents/MacOS/Files"
if [[ ! -f "$EXECUTABLE" ]]; then
    echo "error: $SOURCE does not contain Contents/MacOS/Files." >&2
    echo "Rebuild it with: $SCRIPT_DIR/build.sh" >&2
    exit 1
fi
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: $EXECUTABLE is not executable." >&2
    echo "Rebuild it with: $SCRIPT_DIR/build.sh" >&2
    exit 1
fi

ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || true)"
if [[ "$ARCHS" != *arm64* ]]; then
    echo "error: $EXECUTABLE is not an arm64 binary (architectures: ${ARCHS:-unknown})." >&2
    exit 1
fi

# Refuse to overwrite a running installation.
RUNNING="$(ps -Ao pid=,command= | grep -F -- "$DESTINATION/Contents/MacOS/Files" | grep -v grep || true)"
if [[ -n "$RUNNING" ]]; then
    echo "error: Files is currently running from an installation." >&2
    echo "Quit Files, then run this script again." >&2
    exit 1
fi

if [[ ! -d /Applications ]]; then
    echo "error: /Applications does not exist on this system." >&2
    exit 1
fi

if [[ ! -w /Applications ]]; then
    echo "error: you do not have permission to write to /Applications." >&2
    echo "Re-run this installer with administrator rights, for example:" >&2
    echo "  sudo \"$SCRIPT_DIR/install.sh\"" >&2
    exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STAMP="$(date +%Y%m%d%H%M%S)-$$"
STAGE="/Applications/.Files.app.staging.$STAMP"
BACKUP="/Applications/.Files.app.backup.$STAMP"
INSTALLED=0
KEEP_STAGE=0

cleanup() {
    if [[ "$INSTALLED" -eq 0 && "$KEEP_STAGE" -eq 0 ]]; then
        # Installation did not complete: never leave normal staging output behind.
        [[ -d "$STAGE" ]] && rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

echo "Staging Files.app in /Applications…"
ditto "$SOURCE" "$STAGE"

STAGED_EXECUTABLE="$STAGE/Contents/MacOS/Files"
if [[ ! -x "$STAGED_EXECUTABLE" ]]; then
    echo "error: staged bundle is incomplete; the existing installation was not changed." >&2
    exit 1
fi
STAGED_ARCHS="$(lipo -archs "$STAGED_EXECUTABLE" 2>/dev/null || true)"
if [[ "$STAGED_ARCHS" != *arm64* ]]; then
    echo "error: staged bundle is not arm64; the existing installation was not changed." >&2
    exit 1
fi

if [[ -e "$DESTINATION" ]]; then
    echo "Moving the existing installation aside…"
    if ! mv "$DESTINATION" "$BACKUP"; then
        echo "error: could not move the existing installation aside; nothing was replaced." >&2
        exit 1
    fi
fi

restore_previous() {
    echo "error: could not install the new bundle." >&2
    if [[ -d "$BACKUP" ]]; then
        rm -rf "$DESTINATION" 2>/dev/null || true
        if mv "$BACKUP" "$DESTINATION"; then
            echo "The previous installation was restored at $DESTINATION." >&2
        else
            echo "Recovery: the previous bundle is at $BACKUP" >&2
        fi
    elif [[ -d "$STAGE" ]]; then
        # Nothing to roll back to, but keep the staged bundle so the user can
        # recover manually instead of deleting it.
        KEEP_STAGE=1
        echo "Recovery: the new bundle is at $STAGE" >&2
    fi
}

if ! mv "$STAGE" "$DESTINATION"; then
    restore_previous
    exit 1
fi

if [[ ! -x "$DESTINATION/Contents/MacOS/Files" ]]; then
    echo "error: installed bundle failed validation." >&2
    rm -rf "$DESTINATION" 2>/dev/null || true
    restore_previous
    exit 1
fi

# Success: remove the previous bundle.
if [[ -d "$BACKUP" ]]; then
    if ! rm -rf "$BACKUP"; then
        echo "warning: could not remove the previous bundle at $BACKUP." >&2
        echo "You can delete it manually." >&2
    fi
fi

# Register only the installed application with LaunchServices, under its
# Files.app path. Build products are not launcher entries.
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || true
fi

# The app is installed successfully. From here on, cache-refresh failures must
# not turn a successful installation into a failed one.
INSTALLED=1
trap - EXIT

# ---------------------------------------------------------------------------
# Icon / launcher cache refresh
#
# macOS caches app icons aggressively. Replacing an app bundle is not enough
# for Finder, the Dock, or the application launcher (Apps/Launchpad): the old
# icon can survive in IconServices caches. Clear the system cache when running
# with sudo, clear the invoking user's caches, re-index the bundle, and restart
# the Dock/Apps launcher so it reloads the new icon.
#
# All commands are best-effort; the cache is disposable and the installed app
# must remain valid even if a cache service is unavailable.
# ---------------------------------------------------------------------------
(
    set +e

    target_user=""
    if [[ "$EUID" -eq 0 ]]; then
        target_user="${SUDO_USER:-}"
        if [[ -z "$target_user" || "$target_user" == "root" ]]; then
            target_user="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
        fi
    else
        target_user="$(/usr/bin/id -un)"
    fi
    if [[ -z "$target_user" || "$target_user" == "root" ]]; then
        target_user="$(/usr/bin/id -un)"
    fi

    target_uid="$(/usr/bin/id -u "$target_user" 2>/dev/null || true)"
    target_home="$(/usr/bin/dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
    if [[ -z "$target_home" ]]; then
        target_home="${HOME:-}"
    fi

    echo "Refreshing icon and launcher caches (user: $target_user)…"

    # LaunchServices and Spotlight, for the invoking user when running under
    # sudo. Running lsregister as root alone can leave the user's database
    # untouched.
    if [[ "$EUID" -eq 0 && -n "$target_uid" && "$target_user" != "root" ]]; then
        /usr/bin/sudo -u "$target_user" "$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || true
        /usr/bin/sudo -u "$target_user" /usr/bin/mdimport "$DESTINATION" >/dev/null 2>&1 || true
    else
        "$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || true
        /usr/bin/mdimport "$DESTINATION" >/dev/null 2>&1 || true
    fi
    /usr/bin/touch "$DESTINATION" 2>/dev/null || true

    # System IconServices cache: only writable with administrator rights.
    system_icon_cache="/Library/Caches/com.apple.iconservices.store"
    if [[ "$EUID" -eq 0 ]]; then
        if [[ -d "$system_icon_cache" ]]; then
            if /bin/rm -rf "$system_icon_cache" 2>/dev/null; then
                echo "  cleared system icon cache"
            else
                echo "  warning: could not clear $system_icon_cache" >&2
            fi
        fi
    else
        echo "  note: system icon cache needs sudo; only user caches were cleared." >&2
    fi

    # Per-user IconServices cache, if present.
    user_icon_cache="$target_home/Library/Caches/com.apple.iconservices.store"
    if [[ -n "$target_home" && -d "$user_icon_cache" ]]; then
        if /bin/rm -rf "$user_icon_cache" 2>/dev/null; then
            echo "  cleared user icon cache"
        fi
    fi

    # Per-user iconservicesagent cache directory (usually in the user's TMPDIR).
    target_tmpdir=""
    if [[ "$EUID" -eq 0 && -n "$target_uid" ]]; then
        target_tmpdir="$(/bin/launchctl asuser "$target_uid" /bin/sh -c 'printf %s "${TMPDIR:-}"' 2>/dev/null || true)"
    elif [[ "$target_user" == "$(/usr/bin/id -un)" ]]; then
        target_tmpdir="${TMPDIR:-}"
    fi
    if [[ -n "$target_tmpdir" && -d "$target_tmpdir/com.apple.iconservicesagent" ]]; then
        /bin/rm -rf "$target_tmpdir/com.apple.iconservicesagent" 2>/dev/null || true
    fi

    # Drop in-memory icon caches; launchd restarts both services.
    /usr/bin/killall iconservicesagent >/dev/null 2>&1 || true
    if [[ "$EUID" -eq 0 ]]; then
        /usr/bin/killall iconservicesd >/dev/null 2>&1 || true
    fi

    # The Apps launcher and Dock cache icons for their lifetime. Restart them so
    # they reload from the now-clean caches. The Dock restarts automatically.
    /usr/bin/pkill -f "/System/Applications/Apps.app/Contents/MacOS/Apps" >/dev/null 2>&1 || true
    /usr/bin/killall Dock >/dev/null 2>&1 || true
    sleep 1

    if [[ "$EUID" -eq 0 ]]; then
        echo "Icon caches cleared; Dock and the Apps launcher were restarted."
    else
        echo "User icon caches cleared; Dock was restarted."
        echo "note: run this installer with sudo to clear the system icon cache as well."
    fi
) || true

echo "Installed: $DESTINATION"
