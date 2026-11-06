#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
status_work="$screenleaf_root/.build/verification/status-recording"
status_app="$status_work/Status Recording Check.app"
mkdir -p "$status_app/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    Sources/Patch/Localization.swift Sources/Patch/IconArtwork.swift Sources/Patch/StatusBarControls.swift \
    scripts/verify-status-recording.swift -o "$status_app/Contents/MacOS/StatusRecordingCheck"
python3 - "$status_app/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib, sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleName': 'Patch Status Recording Check', 'CFBundleIdentifier': 'dev.screenleaf.verify.status-recording',
    'CFBundleExecutable': 'StatusRecordingCheck', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '15.0',
    'LSUIElement': True, 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
}))
PY
codesign --force --sign - "$status_app"
"$status_app/Contents/MacOS/StatusRecordingCheck" | tee "$status_work/results.log"
rg -q '^(PASS: real self-window stream|SKIP: existing screen-capture authorization)' "$status_work/results.log"
