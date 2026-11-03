#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
sticker_work="$screenleaf_root/.build/verification/stickers"
mkdir -p "$sticker_work"
cat Sources/ScreenLeaf/ImageTools.swift scripts/verify-stickers.swift > "$sticker_work/StickerVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/Preferences.swift \
    Sources/ScreenLeaf/AnnotationControls.swift Sources/ScreenLeaf/SubjectExtraction.swift \
    Sources/ScreenLeaf/SubjectSelection.swift "$sticker_work/StickerVerification.swift" \
    -o "$sticker_work/verify-stickers"
"$sticker_work/verify-stickers" "$sticker_work"
