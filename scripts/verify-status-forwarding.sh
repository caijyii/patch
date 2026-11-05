#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
forward_work="$screenleaf_root/.build/verification/status-forwarding"
mkdir -p "$forward_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/ScreenLeaf/IconArtwork.swift Sources/ScreenLeaf/StatusBarControls.swift \
    scripts/verify-status-forwarding.swift -o "$forward_work/probe"
"$forward_work/probe" | tee "$forward_work/results.log"
