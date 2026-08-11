#!/bin/bash
# Build Claude Code Companion into /Applications with a version number that
# always moves forward and provenance you can read back from the running app.
#
# Usage:
#   ./build.sh                 # Release build into /Applications
#   ./build.sh --debug         # Debug configuration
#   ./build.sh --clean         # Clean build folder first
#   ./build.sh --no-open       # Build without launching the app
#
# Environment:
#   CCC_ALLOW_STALE_BASE=1     # skip the source-ancestry guard
#   CCC_APP_DIR=<path>         # install somewhere other than /Applications

set -euo pipefail
cd "$(dirname "$0")"

PROJECT_DIR="ClaudeCodeCompanion"
SCHEME="ClaudeCodeCompanion"
APP_NAME="Claude Code Companion"
INFO_PLIST="ClaudeCodeCompanion/ClaudeCodeCompanion/Resources/Info.plist"
ENTITLEMENTS="ClaudeCodeCompanion/ClaudeCodeCompanion/Resources/ClaudeCodeCompanion.entitlements"
APP_DIR="${CCC_APP_DIR:-/Applications/$APP_NAME.app}"

CONFIG="Release"
CLEAN=0
OPEN_APP=1
for arg in "$@"; do
    case "$arg" in
        --debug)   CONFIG="Debug" ;;
        --release) CONFIG="Release" ;;
        --clean)   CLEAN=1 ;;
        --no-open) OPEN_APP=0 ;;
        *) echo "Unknown option: $arg" >&2; exit 64 ;;
    esac
done

# ---------------------------------------------------------------- provenance

./scripts/verify-build-base.sh "$PWD"

BUILD_SOURCE_BRANCH="$(git branch --show-current 2>/dev/null || true)"
[ -n "$BUILD_SOURCE_BRANCH" ] || BUILD_SOURCE_BRANCH="detached-HEAD"
BUILD_SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BUILD_DIRTY="NO"
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    BUILD_DIRTY="YES"
fi
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ------------------------------------------------------------------ version
#
# CFBundleVersion must only ever increase. It comes from the commit count plus
# an offset, so repeated builds of one commit agree, no commit of its own is
# needed, and a history rewrite cannot regress it. The arithmetic lives in
# scripts/build-number.sh so dist.sh cannot drift from this.
# MAJOR.MINOR comes from Info.plist — bump that by hand for a release.

# shellcheck source=scripts/build-number.sh
. "$(dirname "$0")/scripts/build-number.sh"
NEW_BUILD="$(compute_build_number "$(dirname "$0")")"

CURRENT_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
MAJOR_MINOR="$(printf '%s' "$CURRENT_VER" | cut -d. -f1-2)"
NEW_VER="${MAJOR_MINOR}.${NEW_BUILD}"

# Keep the source plist in step so dist.sh and Xcode-in-the-IDE agree with a
# command-line build.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

echo "Building $APP_NAME $NEW_VER ($NEW_BUILD, $CONFIG)"
echo "  Source: $BUILD_SOURCE_BRANCH @ ${BUILD_SOURCE_COMMIT:0:12}$([ "$BUILD_DIRTY" = YES ] && echo ' (uncommitted changes)')"

# -------------------------------------------------------------------- build

DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/ccc-build.XXXXXX")"
trap 'rm -rf "$DERIVED"' EXIT

XCODEBUILD_ARGS=(
    -project "$PROJECT_DIR/ClaudeCodeCompanion.xcodeproj"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$DERIVED"
    MARKETING_VERSION="$NEW_VER"
    CURRENT_PROJECT_VERSION="$NEW_BUILD"
)

if [ "$CLEAN" -eq 1 ]; then
    echo "→ Cleaning…"
    xcodebuild "${XCODEBUILD_ARGS[@]}" clean >/dev/null
fi

BUILD_LOG="$DERIVED/build.log"
if ! xcodebuild "${XCODEBUILD_ARGS[@]}" build > "$BUILD_LOG" 2>&1; then
    echo "❌ Build failed:" >&2
    grep -E "error:" "$BUILD_LOG" | head -20 >&2
    echo "   Full log: $BUILD_LOG" >&2
    cp "$BUILD_LOG" "${TMPDIR:-/tmp}/ccc-build-failure.log" 2>/dev/null || true
    echo "   Copied to ${TMPDIR:-/tmp}/ccc-build-failure.log" >&2
    exit 1
fi

BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "❌ Build reported success but produced no app at $BUILT_APP" >&2
    exit 1
fi

# ------------------------------------------------------------------- install

if pgrep -f "$APP_DIR/Contents/MacOS/" >/dev/null 2>&1; then
    echo "→ Quitting the running copy…"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -f "$APP_DIR/Contents/MacOS/" 2>/dev/null || true
fi

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
cp -R "$BUILT_APP" "$APP_DIR"

# --------------------------------------------------------------- stamp + sign

INSTALLED_PLIST="$APP_DIR/Contents/Info.plist"
stamp() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$INSTALLED_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$INSTALLED_PLIST"
}
stamp CCCBuildSourceBranch string "$BUILD_SOURCE_BRANCH"
stamp CCCBuildSourceCommit string "$BUILD_SOURCE_COMMIT"
stamp CCCBuildDate         string "$BUILD_DATE"
stamp CCCBuildDirty        bool   "$BUILD_DIRTY"
stamp CCCBuildConfiguration string "$CONFIG"

# Editing Info.plist invalidates the signature, so re-sign after stamping.
# Debug builds contain a companion `*.debug.dylib` next to the main executable.
# It must be signed with the same identity as the app or dyld rejects the app
# before SwiftUI can create a window.
SIGN_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi
codesign --verify --verbose --deep --strict "$APP_DIR"

# ------------------------------------------------------------- verify install

INSTALLED_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALLED_PLIST")"
INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_PLIST")"
if [ "$INSTALLED_VER" != "$NEW_VER" ] || [ "$INSTALLED_BUILD" != "$NEW_BUILD" ]; then
    echo "❌ Installed version ($INSTALLED_VER/$INSTALLED_BUILD) does not match this build ($NEW_VER/$NEW_BUILD)." >&2
    exit 1
fi

INSTALLED_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CCCBuildSourceCommit' "$INSTALLED_PLIST")"
if [ "$INSTALLED_COMMIT" != "$BUILD_SOURCE_COMMIT" ]; then
    echo "❌ Installed provenance does not match the source checkout." >&2
    exit 1
fi

# Catch the "BUILD SUCCEEDED but nothing was rebuilt" case: the shipped binary
# must be newer than the newest Swift file that went into it.
NEWEST_SRC_TS="$(find "$PROJECT_DIR" -name '*.swift' -type f -print0 \
    | xargs -0 stat -f '%m' 2>/dev/null | sort -n | tail -1)"
BINARY_TS="$(stat -f '%m' "$APP_DIR/Contents/MacOS/$APP_NAME")"
if [ -n "$NEWEST_SRC_TS" ] && [ "$BINARY_TS" -lt "$NEWEST_SRC_TS" ]; then
    echo "❌ Installed binary is older than the Swift sources." >&2
    echo "   Binary: $(date -r "$BINARY_TS" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "   Source: $(date -r "$NEWEST_SRC_TS" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "   Try: ./build.sh --clean" >&2
    exit 1
fi

# Stop LaunchServices routing `open -a` to an older copy it registered first.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true

# Surface stale copies rather than deleting them behind the user's back.
for candidate in "$HOME/Applications/$APP_NAME.app" "$HOME/Desktop/$APP_NAME.app" \
                 "$HOME/Downloads/$APP_NAME.app" "/Applications/Debug/$APP_NAME.app"; do
    [ -d "$candidate" ] || continue
    [ "$candidate" = "$APP_DIR" ] && continue
    other_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist" 2>/dev/null || echo '?')"
    echo "⚠ Older copy still on disk: $candidate ($other_ver)"
done

echo "✓ $APP_NAME $NEW_VER ($NEW_BUILD) installed to $APP_DIR"
echo "  Built: $BUILD_DATE (just now)"
echo "  Source: $BUILD_SOURCE_BRANCH @ ${BUILD_SOURCE_COMMIT:0:12}$([ "$BUILD_DIRTY" = YES ] && echo ' (uncommitted changes)')"

if [ "$OPEN_APP" -eq 1 ]; then
    open "$APP_DIR"
    echo "  Launched. The sidebar footer shows this version and how long ago it was built."
fi
