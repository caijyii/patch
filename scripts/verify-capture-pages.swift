// Synthetic windows, injected choices, and memory preferences only. No capture,
// general pasteboard, system input, or permission requests.
import AppKit
import Darwin

private struct PageFailure: Error { let message: String }
private final class SyntheticPin: NSPanel, CapturePinWindow {}

@main private struct VerifyCapturePages {
    @MainActor static func main() {
        do { try run(); print("PASS: capture page visibility verification completed") }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PageFailure(message: message) }
    }
    @MainActor private static func run() throws {
        _ = NSApplication.shared
        let storage = MemoryPreferencesStorage()
        let preferences = PreferencesStore(storage: storage)
        try require(preferences.capturePageVisibility == .automatic, "Fresh settings must automatically hide pages")
        for choice in CapturePageVisibilityPreference.allCases {
            preferences.setCapturePageVisibility(choice)
            try require(PreferencesStore(storage: storage).capturePageVisibility == choice, "Visibility choice did not persist")
        }
        let legacy = PreferencesStore(storage: MemoryPreferencesStorage(data: Data(#"{"version":1,"pinRecentCount":6,"annotations":{},"shortcuts":{},"capturePageVisibility":"future-value"}"#.utf8)))
        try require(legacy.capturePageVisibility == .automatic && legacy.pinRecentCount == 6,
                    "Unknown/missing visibility preference must preserve other settings and default to automatic")
        let previous = PreferencesStore(storage: MemoryPreferencesStorage(data: Data(#"{"version":1,"pinRecentCount":6,"annotations":{},"shortcuts":{}}"#.utf8)))
        try require(previous.capturePageVisibility == .automatic && previous.pinRecentCount == 6,
                    "Upgrade default overwrote existing settings")
        let page = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 130),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        page.isReleasedWhenClosed = false
        let text = NSTextField(string: "Synthetic editable page")
        page.contentView = text
        let frame = page.frame
        let hiddenPage = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        hiddenPage.isReleasedWhenClosed = false
        let pin = SyntheticPin(contentRect: frame.offsetBy(dx: 260, dy: 0), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pin.isReleasedWhenClosed = false
        let hud = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hud.isReleasedWhenClosed = false; hud.level = .floating
        defer { page.close(); hiddenPage.close(); pin.close(); hud.close() }
        for window in [page, pin, hud] { window.orderFrontRegardless() }
        let coordinator = CapturePageVisibility()
        var prompts = 0
        let windows = [page, pin, hud, hiddenPage]
        try require(CaptureWindowPolicy.includedWindowIDs.contains(CGWindowID(page.windowNumber))
                    && !CaptureWindowPolicy.includedWindowIDs.contains(CGWindowID(hiddenPage.windowNumber)),
                    "Only visible pages may remain in the capture/candidate whitelist")
        let first = coordinator.begin(preference: .automatic, windows: windows) { prompts += 1; return .cancel }!
        try require(prompts == 0 && !page.isVisible && pin.isVisible && hud.isVisible && !hiddenPage.isVisible,
                    "Automatic hiding must affect only initially visible ordinary pages")
        try require(!CaptureWindowPolicy.includedWindowIDs.contains(CGWindowID(page.windowNumber)),
                    "Auto-hidden page remained eligible for stale WindowServer candidates or pixels")
        coordinator.restore(ifCurrent: first)
        try require(page.isVisible && page.frame == frame && text.stringValue == "Synthetic editable page"
                    && !hiddenPage.isVisible, "Restore lost content/position or opened a previously hidden page")
        try require(CaptureWindowPolicy.includedWindowIDs.contains(CGWindowID(page.windowNumber)),
                    "Restored visible page did not rejoin the capture whitelist")
        let keep = coordinator.begin(preference: .never, windows: windows) { prompts += 1; return .cancel }!
        try require(page.isVisible && prompts == 0, "Keep visible must not hide or prompt")
        coordinator.restore(ifCurrent: keep)
        let cancelled = coordinator.begin(preference: .ask, windows: windows) { prompts += 1; return .cancel }
        try require(cancelled == nil && page.isVisible && prompts == 1, "Cancelling the prompt must leave pages visible")
        let declined = coordinator.begin(preference: .ask, windows: windows) { prompts += 1; return .keepVisible }!
        try require(page.isVisible && !coordinator.hasHiddenPages, "Declining hiding changed visibility")
        coordinator.restore(ifCurrent: declined)
        let accepted = coordinator.begin(preference: .ask, windows: windows) { prompts += 1; return .hide }!
        try require(!page.isVisible && coordinator.hasHiddenPages, "Accepting hiding did not hide pages")
        let newer = coordinator.begin(preference: .automatic, windows: windows) { .cancel }!
        coordinator.restore(ifCurrent: accepted)
        try require(!page.isVisible && coordinator.token == newer, "Stale completion restored a newer capture's pages")
        coordinator.restore(ifCurrent: newer)
        page.orderOut(nil)
        let empty = coordinator.begin(preference: .ask, windows: windows) { prompts += 1; return .cancel }!
        try require(prompts == 3, "Ask mode prompted despite no visible pages")
        coordinator.restore(ifCurrent: empty)
        page.orderFrontRegardless()
        let closed = coordinator.begin(preference: .automatic, windows: windows) { .cancel }!
        page.close(); coordinator.restore(ifCurrent: closed)
        try require(!page.isVisible, "Restoration reopened a page closed during capture")
        print("PASS: automatic/never/ask, cancel, no-window prompt suppression, independent pin/HUD visibility, content, closed pages and stale-session guards")

        let display = NSScreen.main
        let region = CaptureRegion(rect: CGRect(x: 100, y: 100, width: 180, height: 120),
            displayID: CGMainDisplayID(), screenFrame: display?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800), scale: 1, targetPID: nil)
        var endings = 0
        let scroll = ScrollCaptureCoordinator(capture: { _ in throw PageFailure(message: "Unexpected screen capture") }, onComplete: { _, _ in })
        scroll.onSessionEnd = { endings += 1 }
        scroll.start(region: region)
        scroll.start(region: region)
        try require(endings == 0, "Starting/reselecting a scroll capture restored pages early")
        scroll.cancel(); scroll.cancel()
        try require(endings == 1, "Scroll session end did not notify once")
        print("PASS: long-capture replacement retains visibility ownership; cancellation ends it exactly once")
    }
}
