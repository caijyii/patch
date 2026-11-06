#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/toolbar-metrics"
mkdir -p "$task_work/module-cache"
cat Sources/ScreenLeaf/AnnotationControls.swift scripts/verify-toolbar-metrics.swift > "$task_work/ToolbarVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/SelectionGeometry.swift \
    Sources/ScreenLeaf/ImageTools.swift Sources/ScreenLeaf/Localization.swift \
    Sources/ScreenLeaf/WindowTitle.swift Sources/ScreenLeaf/WindowActivation.swift \
    Sources/ScreenLeaf/WindowAmbientBackground.swift Sources/ScreenLeaf/Preferences.swift \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/SubjectSelection.swift \
    "$task_work/ToolbarVerification.swift" -o "$task_work/verify-toolbar-metrics"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: toolbar metrics verification (not launched)\n'
    exit 0
fi
"$task_work/verify-toolbar-metrics" --verify "$task_work"
