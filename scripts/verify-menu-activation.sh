#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
activation_work="$screenleaf_root/.build/verification/menu-activation"
mkdir -p "$activation_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/Patch/WindowActivation.swift \
    scripts/verify-menu-activation.swift -o "$activation_work/probe"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: functional-window activation verification (not launched)\n'
    exit 0
fi
"$activation_work/probe"
