import AppKit
import Darwin

@main struct VerifyPermissions {
    @MainActor static func main() {
        var granted = false
        var events: [String] = []
        var choice = ScreenCapturePermission.Choice.later
        var nestedResult = true
        var gate: ScreenCapturePermission!
        gate = ScreenCapturePermission(check: { granted }, activate: { events.append("activate") }, present: {
            events.append("prompt")
            nestedResult = gate.ensurePermission()
            return choice
        }, request: { events.append("request"); return granted }, openSettings: { events.append("settings") })
        func require(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); exit(1) }
        }
        require(!gate.isGranted && events.isEmpty, "Reading status must not prompt or activate")
        require(!gate.ensurePermission(), "Later must not start capture")
        require(events == ["activate", "prompt"] && !nestedResult, "Prompt must activate first and reject reentry")
        events = []; choice = .settings
        require(!gate.ensurePermission() && events == ["activate", "prompt", "settings"], "Settings guidance failed")
        events = []; choice = .request
        require(!gate.ensurePermission() && events == ["activate", "prompt", "request"], "Denied request must not start capture")
        granted = true; events = []
        require(gate.isGranted && gate.ensurePermission() && events.isEmpty, "Grant must refresh without another prompt")
        granted = false
        require(!gate.isGranted, "Revocation is hidden by cached status")
        print("PASS: read-only permission status, foreground prompt order, reentry, denial, settings and grant/revocation refresh")
    }
}
