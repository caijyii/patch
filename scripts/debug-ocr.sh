#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_sdk="${SCREENLEAF_VERIFY_SDK:-${SCREENLEAF_SDK:-$(xcrun --show-sdk-path)}}"
task_work="$task_root/.build/verification/ocr-debug"
mkdir -p "$task_work/module-cache"
cat "$task_root/Sources/ScreenLeaf/ImageTools.swift" "$task_root/scripts/debug-ocr.swift" \
    > "$task_work/ImageToolsOCRDebug.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target arm64-apple-macosx15.0 \
    "$task_root/Sources/ScreenLeaf/CaptureRegion.swift" "$task_root/Sources/ScreenLeaf/DemoImage.swift" \
    "$task_root/Sources/ScreenLeaf/Preferences.swift" "$task_root/Sources/ScreenLeaf/AnnotationControls.swift" \
    "$task_work/ImageToolsOCRDebug.swift" -o "$task_work/debug-ocr"
"$task_work/debug-ocr" "$task_work"
