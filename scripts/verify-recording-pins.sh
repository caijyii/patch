#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
pin_work="$screenleaf_root/.build/verification/recording-pins"
mkdir -p "$pin_work"
pin_inputs=()
for pin_source in Sources/Patch/*.swift; do
    if [[ "$pin_source" != Sources/Patch/App.swift ]]; then pin_inputs+=("$pin_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" "${pin_inputs[@]}" scripts/verify-recording-pins.swift -o "$pin_work/probe"
"$pin_work/probe"
