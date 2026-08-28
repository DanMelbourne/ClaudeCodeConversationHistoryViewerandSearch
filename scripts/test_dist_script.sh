#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

test -x dist.sh
grep -q '^xcodebuild' dist.sh
grep -q '^    archive$' dist.sh
grep -q 'codesign --verify' dist.sh
grep -q 'xcrun notarytool submit' dist.sh
grep -q 'hdiutil create' dist.sh
grep -q 'codesign --force --sign "\$SIGN_IDENTITY" --timestamp "\$DMG_PATH"' dist.sh
grep -q 'SKIP_NOTARIZE' dist.sh
grep -q 'SKIP_INSTALL' dist.sh
grep -q 'Installed at \$INSTALLED_APP' dist.sh
grep -q 'scripts/sentry_dsyms.sh' dist.sh
