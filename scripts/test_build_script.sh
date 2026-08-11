#!/bin/bash
# Guards for the build pipeline's version + provenance discipline.
# Run: ./scripts/test_build_script.sh
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  ✓ %s\n' "$1"
    else
        printf '  ✗ %s\n' "$1"
        fail=1
    fi
}

echo "build.sh"
check "is executable"                       'test -x build.sh'
check "verifies the build base first"       'grep -q "scripts/verify-build-base.sh" build.sh'
check "derives the build number from the shared helper" 'grep -q "scripts/build-number.sh" build.sh && grep -q "compute_build_number" build.sh'
check "passes the version to xcodebuild"    'grep -q "MARKETING_VERSION=" build.sh && grep -q "CURRENT_PROJECT_VERSION=" build.sh'
check "stamps the build date"               'grep -q "CCCBuildDate" build.sh'
check "stamps source branch and commit"     'grep -q "CCCBuildSourceBranch" build.sh && grep -q "CCCBuildSourceCommit" build.sh'
check "records uncommitted changes"         'grep -q "CCCBuildDirty" build.sh'
check "re-signs after stamping the plist"   'grep -q "codesign --force" build.sh'
check "re-signs nested debug dylibs"        'grep -q -- "--deep" build.sh'
check "verifies installed version matches"  'grep -q "does not match this build" build.sh'
check "verifies binary is newer than source" 'grep -q "older than the Swift sources" build.sh'
check "re-registers with LaunchServices"    'grep -q "lsregister" build.sh'
check "warns about stale copies"            'grep -q "Older copy still on disk" build.sh'

echo "scripts/verify-build-base.sh"
check "is executable"                       'test -x scripts/verify-build-base.sh'
check "blocks builds behind origin/main"    'grep -q "behind origin/main" scripts/verify-build-base.sh'
check "blocks moving the install backwards" 'grep -q "backwards" scripts/verify-build-base.sh'
check "has an explicit override"            'grep -q "CCC_ALLOW_STALE_BASE" scripts/verify-build-base.sh'

echo "dist.sh"
check "shares the version rule with build.sh" 'grep -q "scripts/build-number.sh" dist.sh && grep -q "compute_build_number" dist.sh'
check "does not compute its own build number" '! grep -q "rev-list --count HEAD" dist.sh'

# CFBundleVersion must only ever increase. A history rewrite on 2026-08-11 cut
# the commit count from 60 to 48, which without an offset would have regressed
# the build number from 59 to 48 — an app that cannot say which build it is
# costs a whole test cycle.
echo "build number monotonicity"
check "helper exists and is sourceable"     'test -f scripts/build-number.sh && bash -n scripts/build-number.sh'
check "offset and floor are both set"       '. ./scripts/build-number.sh; test -n "$BUILD_NUMBER_OFFSET" && test -n "$BUILD_NUMBER_FLOOR"'
check "never returns below the floor"       '. ./scripts/build-number.sh; test "$(compute_build_number "$PWD")" -ge "$BUILD_NUMBER_FLOOR"'
check "exceeds the installed build"         '
    plist="/Applications/Claude Code Companion.app/Contents/Info.plist"
    if [ -f "$plist" ]; then
        installed="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || echo 0)"
        . ./scripts/build-number.sh
        test "$(compute_build_number "$PWD")" -ge "$installed"
    fi'
check "rises with the commit count"         '
    . ./scripts/build-number.sh
    count="$(git rev-list --count HEAD)"
    test "$(compute_build_number "$PWD")" -eq "$(( count + BUILD_NUMBER_OFFSET ))" \
        || test "$(compute_build_number "$PWD")" -eq "$BUILD_NUMBER_FLOOR"'
check "stamps provenance before signing"     'grep -q "stamp_key CCCBuildSourceCommit" dist.sh'
check "stamps the build date"                'grep -q "stamp_key CCCBuildDate" dist.sh'

echo "app reads the stamps"
check "BuildInfo reads CCCBuildDate"        'grep -q "CCCBuildDate" ClaudeCodeCompanion/ClaudeCodeCompanion/Services/BuildInfo.swift'
check "sidebar shows the build stamp"       'grep -q "BuildStampView" ClaudeCodeCompanion/ClaudeCodeCompanion/Views/Sidebar/SidebarView.swift'

echo "shell syntax"
for script in build.sh dist.sh scripts/verify-build-base.sh scripts/build-number.sh; do
    check "$script parses" "bash -n $script"
done

if [ "$fail" -ne 0 ]; then
    echo "❌ build pipeline checks failed"
    exit 1
fi
echo "✅ build pipeline checks passed"
