#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/scroll-ui"
mkdir -p "$task_work/module-cache"
# Compile the capture HUD together with the production inline annotation workspace.
cat Sources/ScreenLeaf/ScrollCapture.swift scripts/verify-scroll-ui.swift > "$task_work/ScrollUIVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/SelectionGeometry.swift \
    Sources/ScreenLeaf/ScrollStitcher.swift Sources/ScreenLeaf/ScrollEventRouting.swift \
    Sources/ScreenLeaf/HorizontalScrollFilter.swift Sources/ScreenLeaf/AnnotationControls.swift \
    Sources/ScreenLeaf/ImageTools.swift Sources/ScreenLeaf/Localization.swift Sources/ScreenLeaf/WindowTitle.swift Sources/ScreenLeaf/WindowActivation.swift Sources/ScreenLeaf/WindowAmbientBackground.swift Sources/ScreenLeaf/Preferences.swift \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/SubjectSelection.swift \
    "$task_work/ScrollUIVerification.swift" \
    -o "$task_work/verify-scroll-ui"
if "$task_work/verify-scroll-ui" > "$task_work/output.log" 2>&1; then
    probe_status=0
else
    probe_status=$?
fi
cat "$task_work/output.log"
if rg -q '^FAIL:' "$task_work/output.log"; then exit 1; fi
if ! rg -q '^COMPLETE: scroll HUD verification: [0-9]+ PASS, [0-9]+ SKIP, [0-9]+ FAIL$' "$task_work/output.log"; then
    printf 'FAIL: scroll HUD probe did not complete all checks\n' >&2
    exit 1
fi
exit "$probe_status"
