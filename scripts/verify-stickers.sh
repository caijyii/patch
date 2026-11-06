#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
sticker_work="$screenleaf_root/.build/verification/stickers"
mkdir -p "$sticker_work"
sticker_mode="${1:-}"
if [[ "$sticker_mode" != "" && "$sticker_mode" != "--build-only" && "$sticker_mode" != "--native-drag-build" ]]; then
    printf 'Usage: scripts/verify-stickers.sh [--build-only|--native-drag-build]\n' >&2
    exit 2
fi
cat Sources/Patch/ImageTools.swift scripts/verify-stickers.swift > "$sticker_work/StickerVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/AnnotationControls.swift Sources/Patch/SubjectExtraction.swift \
    Sources/Patch/SubjectSelection.swift "$sticker_work/StickerVerification.swift" \
    -o "$sticker_work/verify-stickers"
if [[ "$sticker_mode" == "--native-drag-build" ]]; then
    sticker_app="$sticker_work/StickerDragProbe.app"
    mkdir -p "$sticker_app/Contents/MacOS" "$sticker_app/Contents/Resources"
    cp "$sticker_work/verify-stickers" "$sticker_app/Contents/MacOS/StickerDragProbe"
    cp -R Resources/PatchStickers "$sticker_app/Contents/Resources/"
    python3 - "$sticker_app" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents' / 'Info.plist'
with path.open('wb') as output:
    plistlib.dump({'CFBundleIdentifier': 'dev.patch.sticker-drag-probe', 'CFBundleExecutable': 'StickerDragProbe',
                  'CFBundleName': 'StickerDragProbe', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '15.0'}, output)
PY
    printf 'BUILT: %s (launch through CUA; isolated preferences in verification directory)\n' "$sticker_app"
    exit 0
fi
if [[ "$sticker_mode" == "--build-only" ]]; then
    printf 'BUILT: sticker verification (not launched)\n'
    exit 0
fi
"$sticker_work/verify-stickers" "$sticker_work"
