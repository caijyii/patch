#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/environment.sh"
cd "$screenleaf_root"
task_work="$screenleaf_root/.build/verification/workflow"
mkdir -p "$task_work"
python3 - "$task_work/AppUnderTest.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/ScreenLeaf/App.swift').read_text()
source = source[source.index('@MainActor\nfinal class AppDelegate'):]
for signature, event in [
    ('func applicationDidFinishLaunching(_ notification: Notification) {', 'did-finish-launching'),
    ('func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {', 'reopen'),
    ('@objc private func showHome() {', 'show-home'),
]:
    assert source.count(signature) == 1
    source = source.replace(signature, signature + '\n        workflowTrace("' + event + '")')
Path(sys.argv[1]).write_text('import AppKit\nimport Carbon\nimport Darwin\n\n' + source + '''
extension AppDelegate {
    var workflowHistory: RecentContentStore { recentContent }
    var workflowHistoryController: RecentContentWindowController? { recentController }
    var workflowMenu: NSMenu { statusControls.menu }
    var workflowMenuShortcuts: Set<KeyboardShortcut> { (statusControls.menu as? GlobalShortcutMenu)?.globalShortcuts ?? [] }
    var workflowHome: HomeWindowController? { homeController }
    var workflowImageTools: ImageToolsCoordinator { imageTools }
    var workflowRecording: RecordingCoordinator { recording }
    var workflowStatusControls: StatusBarControls { statusControls }
    func workflowApplyOptions() { applyOptions() }
    func workflowTrace(_ event: String) {
        let visible = NSApp.windows.filter(\\.isVisible).map {
            "\\($0.windowNumber):\\($0.title):key=\\($0.isKeyWindow):frame=\\($0.frame)"
        }
        print("WORKFLOW_TRACE: \\(event) bundle=\\(Bundle.main.bundleIdentifier ?? "nil") policy=\\(NSApp.activationPolicy().rawValue) active=\\(NSApp.isActive) home=\\(homeController?.window?.isVisible == true) windows=\\(visible)")
    }
}
''')
probe = Path('scripts/verify-workflow.swift').read_text()
signature = '@MainActor static func main() {'
assert probe.count(signature) == 1
probe = probe.replace(signature, signature + '''
        print("WORKFLOW_IDENTITY: bundle=\\(Bundle.main.bundleIdentifier ?? "nil") running=\\(NSRunningApplication.current.bundleIdentifier ?? "nil") executable=\\(Bundle.main.executableURL?.lastPathComponent ?? "nil")")
        guard Bundle.main.bundleIdentifier == "dev.screenleaf.verify.workflow",
              NSRunningApplication.current.bundleIdentifier == "dev.screenleaf.verify.workflow",
              Bundle.main.executableURL?.lastPathComponent == "WorkflowVerification" else {
            print("FAIL: launch Workflow Verification.app through LaunchServices")
            exit(1)
        }
''')
probe = probe.replace('            home.close()', '            delegate.workflowTrace("before-home-close")\n            home.close()\n            delegate.workflowTrace("after-home-close")')
probe = probe.replace('            await settlePolicy(.accessory)', '            await settlePolicy(.accessory)\n            delegate.workflowTrace("after-accessory-wait")')
Path(sys.argv[1]).with_name('WorkflowVerification.swift').write_text(probe)
Path(sys.argv[1]).with_name('RecordingUnderTest.swift').write_text(Path('Sources/ScreenLeaf/Recording.swift').read_text() + '''
extension RecordingCoordinator {
    var workflowPanel: NSPanel? { panel }
    func workflowSetPhase(_ value: String) {
        switch value {
        case "preparing": phase = .preparing
        case "countdown": phase = .countdown
        case "starting": phase = .starting
        case "recording": phase = .recording
        case "paused": phase = .paused
        default: phase = .idle
        }
        stopRequested = false
        let status = ["preparing": L("选择 MP4 保存位置"), "countdown": LF("%d 秒后开始录制", 3),
            "starting": L("正在开始录制…"), "recording": L("录制中"), "paused": L("已暂停")][value] ?? L("准备录制")
        setStatus(status)
        updateControls()
    }
}
''')
PY
task_sources=()
for task_source in Sources/ScreenLeaf/*.swift; do
    if [[ "$task_source" != Sources/ScreenLeaf/App.swift && "$task_source" != Sources/ScreenLeaf/Recording.swift ]]; then task_sources+=("$task_source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -sdk "$screenleaf_sdk" \
    -module-cache-path "$screenleaf_cache" -target "$(uname -m)-apple-macosx15.0" \
    "${task_sources[@]}" "$task_work/AppUnderTest.swift" "$task_work/RecordingUnderTest.swift" "$task_work/WorkflowVerification.swift" -o "$task_work/verify-workflow"
python3 - "$task_work" <<'PY'
from pathlib import Path
import plistlib, shutil, sys
work = Path(sys.argv[1])
contents = work / 'Workflow Verification.app' / 'Contents'
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
shutil.copy2(work / 'verify-workflow', contents / 'MacOS' / 'WorkflowVerification')
resources = contents / 'Resources'
resources.mkdir(parents=True, exist_ok=True)
shutil.copytree('Resources/PatchStickers', resources / 'PatchStickers', dirs_exist_ok=True)
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleName': 'Patch Workflow Verification', 'CFBundleIdentifier': 'dev.screenleaf.verify.workflow',
    'CFBundleExecutable': 'WorkflowVerification', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '15.0',
    'CFBundleVersion': '1',
    'LSUIElement': True, 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True,
}))
PY
task_app="$task_work/Workflow Verification.app"
task_executable="$task_app/Contents/MacOS/WorkflowVerification"
codesign --force --sign - "$task_app"
if [[ "${1:-}" == "--build-only" ]]; then
    printf 'BUILT: %s (not launched)\n' "$task_executable"
    exit 0
fi
run_workflow() {
    local task_log="$task_work/$1.log"
    local task_errors="$task_work/$1.stderr.log"
    local task_pass="$2"
    shift 2
    : > "$task_log"
    : > "$task_errors"
    /usr/bin/open -n -W --stdout "$task_log" --stderr "$task_errors" "$task_app" --args "$@"
    cat "$task_log"
    if [[ -s "$task_errors" ]]; then cat "$task_errors" >&2; fi
    # open waits for exit but does not propagate the application's exit status.
    grep -Fxq "$task_pass" "$task_log"
}
if [[ "${1:-}" == "--status-layout" ]]; then
    run_workflow status-layout-native-app 'PASS: real-run-loop status layout keeps only the Patch icon across phases and appearances' --status-layout
    exit 0
fi
if [[ "${1:-}" == "--startup-only" ]]; then
    run_workflow startup 'PASS: complete startup initializes menu before hotkeys, then refreshes shortcuts and shows Home' --startup-only
    exit 0
fi
run_workflow results 'PASS: workflow verification completed'
run_workflow results-en 'PASS: workflow verification completed' --english
