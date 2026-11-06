#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/scroll-ui"
mkdir -p "$task_work/module-cache"
# Compile the capture HUD together with the production inline annotation workspace.
cat Sources/Patch/ScrollCapture.swift scripts/verify-scroll-ui.swift > "$task_work/ScrollUIVerification.swift"
cp Sources/Patch/ScrollStitcher.swift "$task_work/ScrollStitcher.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/SelectionGeometry.swift \
    "$task_work/ScrollStitcher.swift" Sources/Patch/ScrollEventRouting.swift \
    Sources/Patch/HorizontalScrollFilter.swift Sources/Patch/AnnotationControls.swift \
    Sources/Patch/ImageTools.swift Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/SubjectExtraction.swift Sources/Patch/SubjectSelection.swift \
    "$task_work/ScrollUIVerification.swift" \
    -o "$task_work/verify-scroll-ui"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: scroll HUD verification (not launched)\n'
    exit 0
fi
if "$task_work/verify-scroll-ui" --verify > "$task_work/output.log" 2>&1; then
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
