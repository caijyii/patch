import AppKit
import Darwin

// Native menu binding regression. No capture or input events are synthesized.
func L(_ value: String) -> String { value }
@main private struct VerifyStatusForwarding {
    @MainActor static func main() {
        _ = NSApplication.shared
        func require(_ value: Bool, _ message: String) { if !value { print("FAIL: \(message)"); exit(1) } }
        let menu = NSMenu()
        menu.addItem(withTitle: "Verification", action: nil, keyEquivalent: "")
        let controls = StatusBarControls(menu: menu)
        require(controls.item.menu === menu && menu.delegate === controls,
                "The status item must use AppKit's native menu dispatch")
        require(controls.item.button === controls.menuButton
                && controls.item.length == StatusBarControls.buttonWidth,
                "The status item no longer owns one fixed-width native button")
        require(controls.menuButton.image?.isTemplate == true && controls.menuButton.title.isEmpty
                && controls.menuButton.imagePosition == .imageOnly,
                "The native menu button lost its appearance or gained text")
        controls.remove()
        require(menu.delegate == nil, "Removing status controls retained their delegate")
        print("PASS: one native template menu button owns AppKit menu dispatch and releases its delegate")
    }
}
