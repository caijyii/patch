#!/bin/bash
set -euo pipefail
case "${1:-}" in
    --build-only|--verify) ;;
    *) printf 'Usage: %s --build-only|--verify\n' "$0" >&2; exit 2 ;;
esac
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/pin-gestures"
mkdir -p "$task_work/module-cache"
cat Sources/ScreenLeaf/ImageTools.swift scripts/verify-pin-gestures.swift > "$task_work/Verification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/Localization.swift Sources/ScreenLeaf/WindowTitle.swift \
    Sources/ScreenLeaf/WindowActivation.swift Sources/ScreenLeaf/WindowAmbientBackground.swift Sources/ScreenLeaf/Preferences.swift \
    Sources/ScreenLeaf/AnnotationControls.swift Sources/ScreenLeaf/DemoImage.swift \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/SubjectSelection.swift \
    "$task_work/Verification.swift" -o "$task_work/verify-pin-gestures"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: nonactivating-window pin gesture probe (not launched)\n'
    exit 0
fi
"$task_work/verify-pin-gestures" --verify
