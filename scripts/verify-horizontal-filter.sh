#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/horizontal-filter"

if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
if [[ "$#" -gt 1 ]] || [[ "$#" -eq 1 && "$1" != "--legacy" ]]; then
    printf 'Usage: scripts/verify-horizontal-filter.sh [--legacy]\n' >&2
    exit 2
fi
mkdir -p "$task_work/module-cache"
task_sources=("$task_root/scripts/verify-horizontal-filter.swift")
task_compile_arguments=(-parse-as-library -O -swift-version 5 -sdk "$task_sdk"
    -module-cache-path "$task_work/module-cache" -target arm64-apple-macosx15.0)
if [[ "$#" -eq 1 ]]; then
    task_compile_arguments+=(-D LEGACY_FILTER)
else
    task_sources+=("$task_root/Sources/Patch/HorizontalScrollFilter.swift")
fi
xcrun swiftc "${task_compile_arguments[@]}" "${task_sources[@]}" -o "$task_work/verify-horizontal-filter"
"$task_work/verify-horizontal-filter"
