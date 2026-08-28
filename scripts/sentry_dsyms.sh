#!/bin/bash
# Generate and upload dSYMs so Sentry can symbolicate this app's crash and
# app-hang reports. This is deliberately best-effort: telemetry must not block
# a local build or a release when Sentry, the CLI, or credentials are absent.
#
# Usage: scripts/sentry_dsyms.sh <binary> [binary…]
#
# Environment:
#   SENTRY_UPLOAD_DSYMS=0     Skip uploads for an intentional throwaway build.
#   SENTRY_INCLUDE_SOURCES=1  Also upload source context (off by default).
#   SENTRY_AUTH_TOKEN         Overrides the Keychain credential.
#   SENTRY_ORG / SENTRY_PROJECT / SENTRY_URL override the defaults.
#
# Credential setup (token needs project:read and project:write):
#   security add-generic-password -s code-companion-sentry -a auth-token -w

set -uo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/sentry_dsyms.sh <binary> [binary…]" >&2
    exit 2
fi

if [ "${SENTRY_UPLOAD_DSYMS:-1}" = "0" ]; then
    echo "Sentry debug-file upload skipped (SENTRY_UPLOAD_DSYMS=0)."
    exit 0
fi

SENTRY_ORG="${SENTRY_ORG:-trulyuseful}"
SENTRY_PROJECT="${SENTRY_PROJECT:-code-companion}"
SENTRY_URL="${SENTRY_URL:-https://us.sentry.io}"

if ! command -v dsymutil >/dev/null 2>&1; then
    echo "Sentry debug-file upload skipped: dsymutil is unavailable."
    exit 0
fi
if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "Sentry debug-file upload skipped: install sentry-cli to symbolicate reports."
    exit 0
fi

TOKEN="${SENTRY_AUTH_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    TOKEN="$(security find-generic-password -s code-companion-sentry -a auth-token -w 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
    echo "Sentry debug-file upload skipped: no code-companion-sentry credential in Keychain."
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER_DIR="$REPO_ROOT/.build/sentry-uploaded"
mkdir -p "$MARKER_DIR"

PENDING=()
MARKERS=()
for binary in "$@"; do
    if [ ! -f "$binary" ]; then
        echo "Sentry debug-file upload skipped: binary missing: $binary"
        continue
    fi

    name="$(basename "$binary")"
    uuid="$(dwarfdump --uuid "$binary" 2>/dev/null | awk '/^UUID:/ {print $2; exit}')"
    if [ -z "$uuid" ]; then
        echo "Sentry debug-file upload skipped: $name has no LC_UUID."
        continue
    fi

    marker="$MARKER_DIR/$SENTRY_PROJECT-$uuid"
    if [ -f "$marker" ]; then
        echo "Sentry debug file already uploaded for $name ($uuid)."
        continue
    fi

    dsym="$(dirname "$binary")/$name.dSYM"
    dsym_uuid="$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '/^UUID:/ {print $2; exit}')"
    if [ "$dsym_uuid" != "$uuid" ]; then
        echo "Generating $name.dSYM…"
        rm -rf "$dsym"
        if ! dsymutil "$binary" -o "$dsym" 2>/dev/null; then
            echo "Sentry debug-file upload skipped: could not generate $name.dSYM."
            continue
        fi
    fi

    PENDING+=("$dsym")
    MARKERS+=("$marker")
done

if [ "${#PENDING[@]}" -eq 0 ]; then
    exit 0
fi

flags=(--wait)
if [ "${SENTRY_INCLUDE_SOURCES:-0}" = "1" ]; then
    flags+=(--include-sources)
fi

echo "Uploading Sentry debug files for ${SENTRY_ORG}/${SENTRY_PROJECT}…"
if SENTRY_AUTH_TOKEN="$TOKEN" SENTRY_ORG="$SENTRY_ORG" SENTRY_PROJECT="$SENTRY_PROJECT" SENTRY_URL="$SENTRY_URL" \
    sentry-cli debug-files upload "${flags[@]}" "${PENDING[@]}"; then
    for marker in "${MARKERS[@]}"; do : > "$marker"; done
    echo "Sentry debug files uploaded."
else
    echo "Sentry debug-file upload failed; continuing without interrupting the build."
fi
