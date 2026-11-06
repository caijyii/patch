#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/recording-lifecycle"
mkdir -p "$task_work"
task_source="Sources/Patch/Recording.swift"
task_flags=(-swift-version 5)
if [[ "${1:-}" == "--baseline" && "$#" -eq 2 ]]; then
    task_source="$2"
    task_flags+=(-D RECORDING_CANCEL_BASELINE)
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: scripts/verify-recording-lifecycle.sh [--baseline Recording.swift]\n' >&2
    exit 2
fi
python3 scripts/extract-hud-controls.py Sources/Patch/AnnotationControls.swift "$task_work/SharedHUDControls.swift"
cat "$task_source" scripts/verify-recording-lifecycle.swift > "$task_work/RecordingLifecycleVerification.swift"
xcrun swiftc -parse-as-library -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_flags[@]}" Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/CaptureRegion.swift Sources/Patch/RecordingFileStorage.swift Sources/Patch/RecordingSegments.swift Sources/Patch/RecordingRegionOverlay.swift \
    "$task_work/SharedHUDControls.swift" "$task_work/RecordingLifecycleVerification.swift" -o "$task_work/verify-recording-lifecycle"
"$task_work/verify-recording-lifecycle"
