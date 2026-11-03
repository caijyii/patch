#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
if [[ "$#" -ne 1 ]]; then
    printf 'Usage: bash scripts/verify-inline-subject.sh DUCK_SAMPLE_IMAGE\n' >&2
    exit 2
fi
inline_work="$screenleaf_root/.build/verification/inline-subject"
mkdir -p "$inline_work"
# Local view events only: no screen capture, global input or save panels.
cat Sources/ScreenLeaf/RegionSelector.swift Sources/ScreenLeaf/InlineSubjectSelection.swift \
    scripts/verify-inline-subject.swift > "$inline_work/InlineSubjectVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/ScreenLeaf/CaptureRegion.swift Sources/ScreenLeaf/SelectionGeometry.swift \
    Sources/ScreenLeaf/ScrollEventRouting.swift Sources/ScreenLeaf/ImageTools.swift \
    Sources/ScreenLeaf/SubjectExtraction.swift Sources/ScreenLeaf/SubjectSelection.swift \
    Sources/ScreenLeaf/Preferences.swift Sources/ScreenLeaf/AnnotationControls.swift \
    "$inline_work/InlineSubjectVerification.swift" -o "$inline_work/probe"
"$inline_work/probe" "$1" "$inline_work"
