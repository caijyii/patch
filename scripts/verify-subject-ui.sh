#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
if [[ "$#" -ne 1 ]]; then
    printf 'Usage: bash scripts/verify-subject-ui.sh sample.png\n' >&2
    exit 2
fi
subject_work="$screenleaf_root/.build/verification/subject-ui"
mkdir -p "$subject_work"
# Exercise private views with local synthetic events. No screen capture or global input.
cat Sources/ScreenLeaf/SubjectSelection.swift Sources/ScreenLeaf/ImageTools.swift \
    scripts/verify-subject-ui.swift > "$subject_work/SubjectUIVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/CaptureRegion.swift \
    Sources/ScreenLeaf/Preferences.swift Sources/ScreenLeaf/AnnotationControls.swift \
    "$subject_work/SubjectUIVerification.swift" -o "$subject_work/probe"
"$subject_work/probe" "$1" "$subject_work"
