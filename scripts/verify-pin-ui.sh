#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/pin-ui"
mkdir -p "$task_work/module-cache"
cat Sources/Patch/ImageTools.swift scripts/verify-pin-ui.swift > "$task_work/PinUIVerification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/AnnotationControls.swift Sources/Patch/DemoImage.swift \
    Sources/Patch/SubjectExtraction.swift Sources/Patch/SubjectSelection.swift \
    "$task_work/PinUIVerification.swift" -o "$task_work/verify-pin-ui"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: pin native UI verification (not launched)\n'
    exit 0
fi
if [[ "${1:-}" == "--app" ]]; then
task_app="$task_work/PinUIVerification.app"
mkdir -p "$task_app/Contents/MacOS"
cp "$task_work/verify-pin-ui" "$task_app/Contents/MacOS/verify-pin-ui"
python3 - "$task_app/Contents/Info.plist" <<'PLIST'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleName': 'Patch UI Verification',
    'CFBundleIdentifier': 'dev.screenleaf.pin-ui-verification',
    'CFBundleExecutable': 'verify-pin-ui',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'LSUIElement': True,
    'NSPrincipalClass': 'NSApplication',
    'NSHighResolutionCapable': True
}))
PLIST
codesign --force --sign - "$task_app" >/dev/null 2>&1
: > "$task_work/output.log"
# A native UI test needs LaunchServices registration and foreground activation.
if open -W -n --stdout "$task_work/output.log" --stderr "$task_work/output.log" "$task_app" --args "$task_work"; then
    probe_status=0
else
    probe_status=$?
fi
elif [[ "$#" -eq 0 ]]; then
    if "$task_work/verify-pin-ui" "$task_work" > "$task_work/output.log" 2>&1; then
        probe_status=0
    else
        probe_status=$?
    fi
else
    printf 'Usage: scripts/verify-pin-ui.sh [--app|--build-only]\n' >&2
    exit 2
fi
cat "$task_work/output.log"
if rg -q '^FAIL:' "$task_work/output.log"; then exit 1; fi
if ! rg -q '^COMPLETE: pin native UI verification: [0-9]+ PASS, [0-9]+ SKIP, [0-9]+ FAIL$' "$task_work/output.log"; then
    printf 'FAIL: pin UI probe did not complete all checks\n' >&2
    exit 1
fi
exit "$probe_status"
