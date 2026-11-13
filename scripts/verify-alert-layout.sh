#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/alert-layout"
mkdir -p "$task_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/Localization.swift Sources/Patch/WindowActivation.swift \
    Sources/Patch/CaptureRegion.swift Sources/Patch/ScrollCapturePermission.swift \
    scripts/verify-alert-layout.swift -o "$task_work/probe"
if [[ "${1:-}" == "--build-only" ]]; then printf 'BUILT: alert layout verification (not launched)\n'; exit 0; fi
"$task_work/probe" "$task_work" | tee "$task_work/results.log"
rg -Fxq 'PASS: alert layout verification completed' "$task_work/results.log"
