#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/selection-ui"

if [[ ! -d "$task_sdk" ]]; then
    printf 'FAIL: verification SDK does not exist: %s\n' "$task_sdk" >&2
    exit 1
fi
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--scroll-only" && "$1" != "--overlay-only" && "$1" != "--build-only" ) ]]; then
    printf 'Usage: scripts/verify-selection-ui.sh [--scroll-only|--overlay-only|--build-only]\n' >&2
    exit 2
fi
mkdir -p "$task_work/module-cache"
# The probe shares the private view implementation, with synthetic view events only.
# It never calls RegionSelector.select(), captures a screen, posts CGEvents, or opens a modal.
cat "$task_root/Sources/Patch/RegionSelector.swift" "$task_root/scripts/verify-selection-ui.swift" \
    > "$task_work/SelectionUIVerification.swift"
printf 'Verifying selection UI with SDK: %s\n' "$task_sdk"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target arm64-apple-macosx15.0 \
    "$task_root/Sources/Patch/CaptureRegion.swift" \
    "$task_root/Sources/Patch/SelectionGeometry.swift" \
    "$task_root/Sources/Patch/InlineSubjectSelection.swift" \
    "$task_root/Sources/Patch/ScrollEventRouting.swift" \
    "$task_root/Sources/Patch/ImageTools.swift" \
    "$task_root/Sources/Patch/SubjectExtraction.swift" "$task_root/Sources/Patch/SubjectSelection.swift" \
    "$task_root/Sources/Patch/Localization.swift" "$task_root/Sources/Patch/WindowTitle.swift" "$task_root/Sources/Patch/WindowActivation.swift" "$task_root/Sources/Patch/HomeSeason.swift" "$task_root/Sources/Patch/WindowAmbientBackground.swift" "$task_root/Sources/Patch/Preferences.swift" \
    "$task_root/Sources/Patch/AnnotationControls.swift" \
    "$task_root/Sources/Patch/DemoImage.swift" \
    "$task_work/SelectionUIVerification.swift" -o "$task_work/verify-selection-ui"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: selection UI verification (not launched)\n'
    exit 0
fi
"$task_work/verify-selection-ui" "$task_work" "${1:-}"
