#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/capture-pages"
mkdir -p "$task_work"
task_sources=()
for task_source in Sources/Patch/*.swift; do
    if [[ "$task_source" != Sources/Patch/App.swift ]]; then task_sources+=("$task_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_sources[@]}" scripts/verify-capture-pages.swift -o "$task_work/verify-capture-pages"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: capture page visibility verification (not launched)\n'; exit 0
fi
"$task_work/verify-capture-pages" | tee "$task_work/results.log"
rg -Fqx 'PASS: capture page visibility verification completed' "$task_work/results.log"
