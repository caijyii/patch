#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
options_work="$screenleaf_root/.build/verification/home-options"
mkdir -p "$options_work"
options_inputs=()
for options_source in Sources/ScreenLeaf/*.swift; do
    if [[ "$options_source" != Sources/ScreenLeaf/App.swift ]]; then options_inputs+=("$options_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${options_inputs[@]}" scripts/verify-home-options.swift -o "$options_work/probe"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: Home options verification (not launched)\n'
    exit 0
fi
"$options_work/probe" "$options_work" | tee "$options_work/results.log"
if ! grep -Fxq 'PASS: Home options verification completed' "$options_work/results.log"; then
    echo 'Home options verification did not complete.' >&2
    exit 1
fi
