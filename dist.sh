#!/bin/bash
# Claude Code Companion release pipeline: archive -> sign -> notarize -> DMG.
#
# Prerequisites:
#   1. A Developer ID Application certificate in the login keychain.
#   2. A notarization profile created with xcrun notarytool store-credentials.
#
# Usage:
#   ./dist.sh
#   SKIP_NOTARIZE=1 ./dist.sh
#
# Output: dist/ClaudeCodeCompanion-<version>.dmg

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Code Companion"
ARCHIVE_NAME="ClaudeCodeCompanion"
PROJECT="ClaudeCodeCompanion/ClaudeCodeCompanion.xcodeproj"
SCHEME="ClaudeCodeCompanion"
ENTITLEMENTS="ClaudeCodeCompanion/ClaudeCodeCompanion/Resources/ClaudeCodeCompanion.entitlements"
INFO_PLIST="ClaudeCodeCompanion/ClaudeCodeCompanion/Resources/Info.plist"
DIST_DIR="dist"
STAGING_DIR="$DIST_DIR/staging"
ARCHIVE_PATH="$STAGING_DIR/$ARCHIVE_NAME.xcarchive"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-code-companion-notarize}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DMG_PATH="$DIST_DIR/$ARCHIVE_NAME-$VERSION.dmg"

SIGN_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | head -1 | awk '{print $2}' || true)"
fi

if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Developer ID Application certificate found." >&2
    echo "Install one in the login keychain, or pass SIGNING_IDENTITY=<identity>." >&2
    exit 1
fi

if [ "${SKIP_NOTARIZE:-0}" != "1" ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notarization profile '$NOTARY_PROFILE' was not found." >&2
    echo "Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE ..." >&2
    echo "For a local signed build, run SKIP_NOTARIZE=1 ./dist.sh." >&2
    exit 1
fi

echo "Building $APP_NAME $VERSION ($BUILD)"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"

# Archive without Xcode-managed signing, then sign all bundled code with the
# selected Developer ID identity. This avoids requiring a development team in
# the project while preserving the exact release identity used for notarization.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Archive did not produce $APP_NAME.app." >&2
    exit 1
fi

echo "Signing with $SIGN_IDENTITY"
xattr -cr "$APP_PATH" 2>/dev/null || true
while IFS= read -r framework; do
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$framework"
done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' 2>/dev/null | sort)

codesign --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_PATH"
codesign --verify --verbose --deep --strict "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" || \
    echo "Gatekeeper assessment will pass after notarization and stapling."

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    NOTARY_ZIP="$STAGING_DIR/$ARCHIVE_NAME-$VERSION-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
else
    echo "Skipping notarization; the resulting DMG is for local testing only."
fi

DMG_STAGE="$STAGING_DIR/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

codesign --verify --verbose "$DMG_PATH"
shasum -a 256 "$DMG_PATH"

# Install the exact app bundle that was signed and, when enabled, notarized.
# Quit first so macOS does not retain stale executable pages from a bundle that
# is being replaced. SKIP_INSTALL is useful for CI or packaging-only jobs.
INSTALLED_APP="/Applications/$APP_NAME.app"
INSTALL_TEMP="/Applications/.$ARCHIVE_NAME-installing.app"
INSTALL_BACKUP="/Applications/.$ARCHIVE_NAME-previous.app"
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    echo "Installing to $INSTALLED_APP"
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
            pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
            sleep 0.4
        done
        if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            echo "$APP_NAME is still running; quit it and run dist.sh again." >&2
            exit 1
        fi
    fi

    rm -rf "$INSTALL_TEMP" "$INSTALL_BACKUP"
    ditto "$APP_PATH" "$INSTALL_TEMP"
    if [ -d "$INSTALLED_APP" ]; then
        mv "$INSTALLED_APP" "$INSTALL_BACKUP"
    fi
    if ! mv "$INSTALL_TEMP" "$INSTALLED_APP"; then
        [ -d "$INSTALL_BACKUP" ] && mv "$INSTALL_BACKUP" "$INSTALLED_APP"
        exit 1
    fi
    rm -rf "$INSTALL_BACKUP"
    echo "Installed at $INSTALLED_APP"
fi

echo "Distribution ready: $DMG_PATH"
