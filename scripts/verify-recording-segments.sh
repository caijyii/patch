#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/recording-segments"
mkdir -p "$task_work"
task_fixtures="$(mktemp -d "$task_work/run-XXXXXX")"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/ScreenLeaf/Localization.swift Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/WindowActivation.swift \
    Sources/ScreenLeaf/RecordingFileStorage.swift Sources/ScreenLeaf/RecordingSegments.swift \
    scripts/verify-recording-segments.swift -o "$task_work/verify-recording-segments"
"$task_work/verify-recording-segments" "$task_fixtures"
