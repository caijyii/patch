#!/bin/bash
set -euo pipefail
case "${1:-}" in --verify|--build-only) ;; *) echo 'Usage: scripts/verify-scroll-budget.sh --verify|--build-only'; exit 2;; esac
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_output="$screenleaf_root/.build/verification/scroll-budget"
mkdir -p "$task_output"
xcrun swiftc -O -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/ScrollStitcher.swift scripts/verify-scroll-budget.swift -o "$task_output/verify-scroll-budget"
if [[ "$1" == --build-only ]]; then echo "BUILT: $task_output/verify-scroll-budget"; exit 0; fi
for budget in 128 256 512; do "$task_output/verify-scroll-budget" "$budget" retina; done
"$task_output/verify-scroll-budget" 128 tall
