#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/toolbar-metrics"
mkdir -p "$task_work/module-cache"
cat Sources/Patch/AnnotationControls.swift scripts/verify-toolbar-metrics.swift > "$task_work/ToolbarVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/SelectionGeometry.swift \
    Sources/Patch/ImageTools.swift Sources/Patch/Localization.swift \
    Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift \
    Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/SubjectExtraction.swift Sources/Patch/SubjectSelection.swift \
    "$task_work/ToolbarVerification.swift" -o "$task_work/verify-toolbar-metrics"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: toolbar metrics verification (not launched)\n'
    exit 0
fi
"$task_work/verify-toolbar-metrics" --verify "$task_work"
