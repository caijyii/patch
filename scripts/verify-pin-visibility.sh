#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
visibility_work="$screenleaf_root/.build/verification/pin-visibility"
mkdir -p "$visibility_work"
visibility_sources=()
for visibility_source in Sources/ScreenLeaf/*.swift; do
    if [[ "$visibility_source" != Sources/ScreenLeaf/App.swift ]]; then visibility_sources+=("$visibility_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${visibility_sources[@]}" scripts/verify-pin-visibility.swift -o "$visibility_work/verify-pin-visibility"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: pin visibility verification (not launched)\n'
    exit 0
fi
"$visibility_work/verify-pin-visibility" --verify | tee "$visibility_work/results.log"
