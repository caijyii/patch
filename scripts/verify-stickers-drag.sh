#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
sticker_work="$screenleaf_root/.build/verification/sticker-event-chain"
mkdir -p "$sticker_work"
cat Sources/ScreenLeaf/RegionSelector.swift scripts/verify-stickers-drag.swift > "$sticker_work/StickerEventVerification.swift"
cat Sources/ScreenLeaf/AnnotationControls.swift > "$sticker_work/AnnotationControlsForTesting.swift"
cat >> "$sticker_work/AnnotationControlsForTesting.swift" <<'SWIFT'

extension AnnotationControls {
    var probePicker: StickerPickerController? { stickerPicker }
    var probePopover: NSPopover? { stickerPopover }
}
SWIFT
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/SelectionGeometry.swift \
    Sources/ScreenLeaf/InlineSubjectSelection.swift Sources/ScreenLeaf/ScrollEventRouting.swift Sources/ScreenLeaf/ImageTools.swift \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/SubjectSelection.swift Sources/ScreenLeaf/Localization.swift Sources/ScreenLeaf/WindowTitle.swift Sources/ScreenLeaf/WindowActivation.swift Sources/ScreenLeaf/WindowAmbientBackground.swift \
    Sources/ScreenLeaf/Preferences.swift "$sticker_work/AnnotationControlsForTesting.swift" Sources/ScreenLeaf/DemoImage.swift \
    "$sticker_work/StickerEventVerification.swift" -o "$sticker_work/verify-sticker-event-chain"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: production sticker event-chain verification (not launched)\n'
    exit 0
fi
"$sticker_work/verify-sticker-event-chain"
