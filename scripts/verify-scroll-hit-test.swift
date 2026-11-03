import AppKit
import CoreGraphics

@main
enum ScrollHitVerification {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { exit(1) }
        let area = CGRect(x: screen.visibleFrame.minX + 24, y: screen.visibleFrame.minY + 24,
                          width: 180, height: 100)
        let target = window(area: area, color: .systemGreen)
        let overlay = window(area: area, color: .systemOrange)
        let point = CGPoint(x: area.midX, y: area.midY)
        target.orderFrontRegardless()
        overlay.ignoresMouseEvents = true
        overlay.orderFrontRegardless()
        settle()
        var failures = 0
        func check(_ name: String, expected: Int) {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            let owner = ScrollEventRouting.owner(ofWindow: number, windows: windows)
            let passed = number == expected && owner == ProcessInfo.processInfo.processIdentifier
            print("\(passed ? "PASS" : "FAIL") \(name): hit=\(number), expected=\(expected)")
            if !passed { failures += 1 }
        }
        check("忽略鼠标的浮窗不会误挡目标", expected: target.windowNumber)
        overlay.ignoresMouseEvents = false
        settle()
        check("实际接收鼠标的浮窗阻挡目标", expected: overlay.windowNumber)
        // Visual transparency does not establish whether a window accepts mouse input.
        overlay.orderOut(nil)
        target.orderOut(nil)
        print("输入命中验证：2 个场景，\(failures) 项失败。无截图、输入事件或授权申请。")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor private static func window(area: CGRect, color: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: area, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(area, display: false)
        window.backgroundColor = color
        window.isOpaque = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        return window
    }

    private static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
}
