#!/bin/bash
set -euo pipefail
case "${1:-}" in
    --build-only|--verify|--interactive|--interactive-active) ;;
    *) printf 'Usage: %s --build-only|--verify|--interactive|--interactive-active\n' "$0" >&2; exit 2 ;;
esac
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/pin-gestures"
mkdir -p "$task_work/module-cache"
cat Sources/Patch/ImageTools.swift scripts/verify-pin-gestures.swift > "$task_work/Verification.swift"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$task_work/module-cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/CaptureRegion.swift Sources/Patch/Localization.swift Sources/Patch/WindowTitle.swift \
    Sources/Patch/WindowActivation.swift Sources/Patch/HomeSeason.swift Sources/Patch/WindowAmbientBackground.swift Sources/Patch/Preferences.swift \
    Sources/Patch/AnnotationControls.swift Sources/Patch/DemoImage.swift \
    Sources/Patch/SubjectExtraction.swift Sources/Patch/SubjectSelection.swift \
    "$task_work/Verification.swift" -o "$task_work/verify-pin-gestures"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: nonactivating-window pin gesture probe (not launched)\n'
    exit 0
fi
if [[ "$1" == --interactive* ]]; then
    # Use LaunchServices for hardware tests to match the installed app.
    # A naked executable can receive scrolling while never receiving magnify events.
    python3 - "$task_work" <<'PYAPP'
from pathlib import Path
import plistlib, shutil, sys
base = Path(sys.argv[1])
contents = base / "PatchGestureProbe.app" / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
shutil.copy2(base / "verify-pin-gestures", contents / "MacOS" / "PatchGestureProbe")
(contents / "Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "dev.screenleaf.gesture-probe", "CFBundleExecutable": "PatchGestureProbe",
    "CFBundleName": "Patch Gesture Probe", "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True, "LSUIElement": True,
}))
PYAPP
    codesign --force --sign - "$task_work/PatchGestureProbe.app"
    open -g -n "$task_work/PatchGestureProbe.app" --stdout "$task_work/interactive.log" \
        --stderr "$task_work/interactive-errors.log" --args "$1"
    printf 'Interactive gesture log: %s/interactive.log\n' "$task_work"
else
    "$task_work/verify-pin-gestures" "$1"
fi
