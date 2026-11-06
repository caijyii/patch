#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
capture_work="$screenleaf_root/.build/verification/capture-windows"
mkdir -p "$capture_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/Patch/Localization.swift Sources/Patch/CaptureRegion.swift Sources/Patch/WindowActivation.swift \
    Sources/Patch/CaptureService.swift scripts/verify-capture-windows.swift -o "$capture_work/verify"
"$capture_work/verify" | tee "$capture_work/results.log"
