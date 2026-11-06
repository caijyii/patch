#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
order_work="$screenleaf_root/.build/verification/status-window-order"
mkdir -p "$order_work"
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" -module-cache-path "$screenleaf_cache" \
    -target "$(uname -m)-apple-macosx15.0" Sources/Patch/IconArtwork.swift Sources/Patch/StatusBarControls.swift Sources/Patch/WindowActivation.swift \
    scripts/verify-status-window-order.swift -o "$order_work/probe"
python3 - "$order_work" <<'PY_BUNDLES'
from pathlib import Path
import plistlib
import shutil
import sys

work = Path(sys.argv[1])
for role, accessory in [("Parent", True), ("Helper", False)]:
    name = "Patch Order " + role
    executable = "MenuOrder" + role
    contents = work / (name + ".app") / "Contents"
    (contents / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copy2(work / "probe", contents / "MacOS" / executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.screenleaf.verify.menu-order." + role.lower(),
        "CFBundleName": name,
        "CFBundleExecutable": executable,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "15.0",
        "LSUIElement": accessory,
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
    }))
PY_BUNDLES
order_parent_app="$order_work/Patch Order Parent.app"
order_helper_app="$order_work/Patch Order Helper.app"
codesign --force --sign - "$order_parent_app"
codesign --force --sign - "$order_helper_app"
order_parent="$order_parent_app/Contents/MacOS/MenuOrderParent"
order_helper="$order_helper_app/Contents/MacOS/MenuOrderHelper"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: menu window-order verification (not launched)\n'
    exit 0
fi
for order_mode in --foreground --background --handoff --late-handoff --outside --post-close-handoff; do
    "$order_parent" "$order_mode" --helper-executable "$order_helper" | tee "$order_work/$order_mode.log"
    grep -Fxq 'PASS: menu window ordering' "$order_work/$order_mode.log"
done
