#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/recent-quotas"
mkdir -p "$task_work"
task_sources=()
for task_source in Sources/Patch/*.swift; do
    if [[ "$task_source" != Sources/Patch/App.swift ]]; then task_sources+=("$task_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_sources[@]}" scripts/verify-recent-quotas.swift -o "$task_work/verify-recent-quotas"
"$task_work/verify-recent-quotas" "$task_work" | tee "$task_work/results.log"
