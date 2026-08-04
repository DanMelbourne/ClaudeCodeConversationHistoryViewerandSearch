#!/bin/bash
# Refuse to replace the installed app with a build from stale source.
#
# Two checks:
#   1. HEAD must contain origin/main (not building from behind).
#   2. HEAD must contain the commit the currently installed app was built from
#      (not moving the installed app backwards in history).
#
# Override for an intentional historical/offline build:
#   CCC_ALLOW_STALE_BASE=1 ./build.sh

set -euo pipefail

REPO_DIR="${1:-$(pwd)}"
INSTALLED_APP="${CCC_INSTALLED_APP:-/Applications/Claude Code Companion.app}"

if [ "${CCC_ALLOW_STALE_BASE:-0}" = "1" ]; then
    echo "⚠ Stale-build ancestry check bypassed (CCC_ALLOW_STALE_BASE=1)."
    exit 0
fi

if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Build-base check requires a Git worktree: $REPO_DIR" >&2
    exit 1
fi

BRANCH="$(git -C "$REPO_DIR" branch --show-current)"
[ -n "$BRANCH" ] || BRANCH="detached-HEAD"
COMMIT="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD)"

# An offline machine or a repo without a remote should still be able to build;
# it just cannot verify ancestry against origin.
if ! git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
    echo "⚠ No origin remote — skipping the origin/main ancestry check ($BRANCH @ $COMMIT)."
elif ! git -C "$REPO_DIR" fetch --quiet origin 2>/dev/null; then
    echo "⚠ Could not reach origin — skipping the origin/main ancestry check ($BRANCH @ $COMMIT)."
elif git -C "$REPO_DIR" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    MAIN_REF="refs/remotes/origin/main"
    if ! git -C "$REPO_DIR" merge-base --is-ancestor "$MAIN_REF" HEAD; then
        BEHIND="$(git -C "$REPO_DIR" rev-list --count HEAD.."$MAIN_REF")"
        echo "❌ Refusing to build $BRANCH: $BEHIND commit(s) behind origin/main." >&2
        echo "   Rebase or merge onto origin/main first." >&2
        echo "   For an intentional historical build: CCC_ALLOW_STALE_BASE=1 ./build.sh" >&2
        exit 1
    fi
fi

# Never move the installed app backwards: its source commit must be an
# ancestor of what is about to replace it.
INSTALLED_PLIST="$INSTALLED_APP/Contents/Info.plist"
if [ -f "$INSTALLED_PLIST" ]; then
    INSTALLED_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CCCBuildSourceCommit' "$INSTALLED_PLIST" 2>/dev/null || true)"
    if [ -n "$INSTALLED_COMMIT" ] && git -C "$REPO_DIR" cat-file -e "${INSTALLED_COMMIT}^{commit}" 2>/dev/null; then
        if ! git -C "$REPO_DIR" merge-base --is-ancestor "$INSTALLED_COMMIT" HEAD; then
            echo "❌ Refusing to build $BRANCH: it would move the installed app backwards." >&2
            echo "   Installed source: ${INSTALLED_COMMIT:0:12}" >&2
            echo "   Merge that commit into this branch, or: CCC_ALLOW_STALE_BASE=1 ./build.sh" >&2
            exit 1
        fi
    fi
fi

echo "✓ Build base verified ($BRANCH @ $COMMIT)."
