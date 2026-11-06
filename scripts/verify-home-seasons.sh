#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$task_root/scripts/environment.sh"
task_sdk="${SCREENLEAF_VERIFY_SDK:-$screenleaf_sdk}"
task_work="$task_root/.build/verification/home-seasons"

if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
if [[ "$#" -ne 0 ]]; then
    printf 'Usage: scripts/verify-home-seasons.sh\n' >&2
    exit 2
fi
mkdir -p "$task_work/module-cache"
printf 'Verifying local calendar seasons with SDK: %s\n' "$task_sdk"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    "$task_root/Sources/Patch/HomeSeason.swift" \
    "$task_root/scripts/verify-home-seasons.swift" -o "$task_work/verify-home-seasons"
"$task_work/verify-home-seasons"
# Launch arguments override preferences only for this process; no user defaults
# are persisted. This catches accidental use of Calendar.current in the model.
"$task_work/verify-home-seasons" -AppleLocale 'en_US@calendar=hebrew' --expect-hebrew-calendar
