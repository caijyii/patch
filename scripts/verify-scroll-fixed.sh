#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--build-only" ) ]]; then
    echo "Usage: bash scripts/verify-scroll-fixed.sh [--build-only]"
    exit 2
fi
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
output="$screenleaf_root/.build/verification/scroll-fixed"
mkdir -p "$output"
xcrun swiftc -O -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/ScrollStitcher.swift scripts/verify-scroll-fixed.swift \
    -o "$output/verify-scroll-fixed"
if [[ "${1:-}" == "--build-only" ]]; then
    echo "Built $output/verify-scroll-fixed"
    exit 0
fi
"$output/verify-scroll-fixed" --output "$output"
