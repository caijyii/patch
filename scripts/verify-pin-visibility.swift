// Synthetic windows only; no system clipboard, capture, or posted input.
import AppKit
import Darwin

private struct VisibilityFailure: Error, CustomStringConvertible { let description: String }

@main private struct VerifyPinVisibility {
    @MainActor static func main() {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--verify"] else {
            print("Run scripts/verify-pin-visibility.sh from Terminal."); return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        defer { previous?.activate(options: []) }
        do { try verify() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw VisibilityFailure(description: message) }
    }
    @MainActor private static func verify() throws {
        guard !NSScreen.screens.isEmpty else { throw VisibilityFailure(description: "Desktop unavailable") }
        let tools = ImageToolsCoordinator()
        defer { tools.closeAll() }
        func pinWindows() -> [NSWindow] {
            NSApp.windows.filter { [L("Patch · 图片贴图"), L("Patch · 文字贴图")].contains($0.title) }
        }
        tools.pinImage(DemoImage.make(), recordsHistory: false)
        let older = pinWindows()
        try require(older.count == 1, "Initial image pin is missing")
        tools.togglePins()
        try require(older.allSatisfy { !$0.isVisible } && tools.canTogglePins, "Initial hide group was not saved")
        tools.pinText("Synthetic recent text", recordsHistory: false)
        tools.pinImage(DemoImage.make(), recordsHistory: false)
        let recent = pinWindows().filter(\.isVisible)
        let positions = recent.map(\.frame)
        try require(recent.count == 2 && older.allSatisfy { !$0.isVisible }, "New pins revived the older group")
        tools.togglePins(); tools.togglePins()
        try require(recent.allSatisfy(\.isVisible) && older.allSatisfy { !$0.isVisible },
                    "Restore mixed an older hidden group into the most recent group")
        try require(recent.map(\.frame) == positions, "Restore moved the latest group's windows")
        tools.togglePins()
        recent.forEach { $0.close() }
        try require(!tools.canTogglePins && older.allSatisfy { !$0.isVisible },
                    "Closing the last group made an older hidden group restorable")
        tools.togglePins()
        try require(older.allSatisfy { !$0.isVisible }, "A stale restore action revived older pins")
        tools.closeAll()
        try require(!tools.hasPins && !tools.canTogglePins, "Close all retained pin state")

        tools.pinImage(DemoImage.make(), recordsHistory: false)
        let first = pinWindows().filter(\.isVisible)
        try require(first.count == 1, "Second scenario did not start with one visible pin")
        tools.togglePins()
        tools.pinText("Synthetic temporary text", recordsHistory: false)
        pinWindows().filter(\.isVisible).forEach { $0.close() }
        try require(tools.canTogglePins && tools.arePinsHidden, "Closing a new pin erased the previous hide operation")
        tools.togglePins()
        try require(first.allSatisfy(\.isVisible), "The last hide group was lost when a newer pin closed")
        print("PASS: only the latest hidden group restores, positions persist, closing a group does not revive older groups, and close-all clears state")
    }
}
