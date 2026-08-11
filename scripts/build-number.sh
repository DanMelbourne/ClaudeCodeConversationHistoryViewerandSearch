#!/bin/bash
# Single source of truth for CFBundleVersion. Sourced by build.sh and dist.sh —
# never duplicate this arithmetic, because the two drifting apart is how a
# release ends up with a lower build number than the copy it replaces.
#
#   BUILD = <commit count> + OFFSET, floored at FLOOR
#
# The commit count alone is monotonic only while history is append-only. On
# 2026-08-11 a filter-repo pass removed committed build output and dropped 12
# commits that became empty, taking the count from 60 to 48 — which would have
# regressed the build number from 59 to 48. OFFSET restores continuity while
# keeping one distinct number per commit; FLOOR is the backstop that guarantees
# monotonicity even if a future rewrite outpaces the offset.
#
# After any history rewrite that shortens the log:
#   1. raise BUILD_NUMBER_OFFSET by the number of commits removed, and
#   2. raise BUILD_NUMBER_FLOOR to at least the highest build ever shipped.

BUILD_NUMBER_OFFSET=12
BUILD_NUMBER_FLOOR=60

compute_build_number() {
    local repo_dir="${1:-$(pwd)}"
    local count build
    count="$(git -C "$repo_dir" rev-list --count HEAD 2>/dev/null || echo 0)"
    build=$(( count + BUILD_NUMBER_OFFSET ))
    if [ "$build" -lt "$BUILD_NUMBER_FLOOR" ]; then
        build="$BUILD_NUMBER_FLOOR"
    fi
    printf '%s' "$build"
}
