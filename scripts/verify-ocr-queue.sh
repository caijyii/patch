#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_work="$task_root/.build/verification/ocr-queue"
task_sdk="${SCREENLEAF_VERIFY_SDK:-$(xcrun --show-sdk-path)}"
task_source="$task_root/Sources/Patch/ImageTools.swift"
mkdir -p "$task_work/module-cache"
cat "$task_source" "$task_root/scripts/verify-ocr-queue.swift" > "$task_work/OCRQueueVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$task_sdk" \
    -module-cache-path "$task_work/module-cache" -target arm64-apple-macosx15.0 \
    "$task_root/Sources/Patch/CaptureRegion.swift" \
    "$task_root/Sources/Patch/DemoImage.swift" \
    "$task_root/Sources/Patch/Localization.swift" "$task_root/Sources/Patch/WindowTitle.swift" "$task_root/Sources/Patch/WindowActivation.swift" "$task_root/Sources/Patch/HomeSeason.swift" "$task_root/Sources/Patch/WindowAmbientBackground.swift" "$task_root/Sources/Patch/Preferences.swift" "$task_root/Sources/Patch/AnnotationControls.swift" \
    "$task_root/Sources/Patch/SubjectExtraction.swift" "$task_root/Sources/Patch/SubjectSelection.swift" \
    "$task_work/OCRQueueVerification.swift" -o "$task_work/verify-ocr-queue"
"$task_work/verify-ocr-queue" "$@"
