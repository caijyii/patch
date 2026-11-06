#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
sticker_work="$screenleaf_root/.build/verification/sticker-event-chain"
mkdir -p "$sticker_work"
cat Sources/Patch/RegionSelector.swift scripts/verify-stickers-drag.swift > "$sticker_work/StickerEventVerification.swift"
cat Sources/Patch/AnnotationControls.swift > "$sticker_work/AnnotationControlsForTesting.swift"
cat >> "$sticker_work/AnnotationControlsForTesting.swift" <<'SWIFT'

extension AnnotationControls {
    var probePicker: StickerPickerController? { stickerPicker }
    var probePopover: NSPopover? { stickerPopover }
}
SWIFT
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/Patch/CaptureRegion.swift Sources/Patch/SelectionGeometry.swift \
    Sources/Patch/InlineSubjectSelection.swift Sources/Patch/ScrollEventRouting.swift Sources/Patch/ImageTools.swift \
    Sources/Patch/SubjectExtraction.swift Sources/Patch/SubjectSelection.swift Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift \
    Sources/Patch/Preferences.swift "$sticker_work/AnnotationControlsForTesting.swift" Sources/Patch/DemoImage.swift \
    "$sticker_work/StickerEventVerification.swift" -o "$sticker_work/verify-sticker-event-chain"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: production sticker event-chain verification (not launched)\n'
    exit 0
fi
"$sticker_work/verify-sticker-event-chain"
