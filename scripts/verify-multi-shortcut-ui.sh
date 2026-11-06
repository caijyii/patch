#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/multi-shortcut-ui"
mkdir -p "$task_work"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--build-only" ) ]]; then
    printf 'Usage: scripts/verify-multi-shortcut-ui.sh [--build-only]\n' >&2
    exit 2
fi
task_sources=()
for task_source in Sources/Patch/*.swift; do
    if [[ "$task_source" != Sources/Patch/App.swift ]]; then task_sources+=("$task_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_sources[@]}" scripts/verify-multi-shortcut-ui.swift -o "$task_work/verify-multi-shortcut-ui"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: multi-shortcut UI verification (not launched)\n'
    exit 0
fi
"$task_work/verify-multi-shortcut-ui" "$task_work" > "$task_work/output.log" 2>&1 || {
    task_status=$?
    cat "$task_work/output.log"
    exit "$task_status"
}
cat "$task_work/output.log"
