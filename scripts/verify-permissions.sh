#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/permissions"
mkdir -p "$task_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/Localization.swift Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/WindowActivation.swift Sources/ScreenLeaf/CaptureService.swift \
    scripts/verify-permissions.swift -o "$task_work/verify-permissions"
"$task_work/verify-permissions" | tee "$task_work/results.log"
