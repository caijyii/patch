// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Patch exposes its menu only; macOS owns the standalone recording control.
@MainActor
final class StatusBarControls: NSObject, NSMenuDelegate {
    static let buttonWidth: CGFloat = 22
    let item: NSStatusItem
    let menu: NSMenu
    let menuButton: NSStatusBarButton
    private var clickMonitor: Any?

    init(menu: NSMenu) {
        self.menu = menu
        item = NSStatusBar.system.statusItem(withLength: Self.buttonWidth)
        menuButton = item.button!
        super.init()
        // Functional windows select regular app activation before appearing.
        // Native menu tracking can then keep their focus and stacking order.
        item.menu = menu
        menu.delegate = self
        menuButton.title = ""
        menuButton.image = IconArtwork.menuBarImage()
        menuButton.imagePosition = .imageOnly
        menuButton.imageScaling = .scaleProportionallyDown
        menuButton.setAccessibilityLabel("Patch")
        menuButton.toolTip = L("patch · 截图、长截图、贴图和录屏")
        if WindowActivationDiagnostics.shared != nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, event.window === self.menuButton.window {
                        WindowActivationDiagnostics.shared?.record("status-button.mouse-down")
                    }
                }
                return event
            }
            WindowActivationDiagnostics.shared?.record("status-item.created")
        }
    }

    func remove() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        menu.cancelTrackingWithoutAnimation()
        if menu.delegate === self { menu.delegate = nil }
        NSStatusBar.system.removeStatusItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        WindowActivationDiagnostics.shared?.record("status-menu.will-open")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        WindowActivationDiagnostics.shared?.record("status-menu.did-close")
    }

}

/// Opt-in, bounded metadata log for local development builds. No window text,
/// images, clipboard contents, keystrokes, or pointer positions are recorded.
@MainActor
final class WindowActivationDiagnostics: NSObject {
    static var shared: WindowActivationDiagnostics?
    private let file: URL
    private var lines: [String] = []

    static func startIfRequested() {
        guard Bundle.main.object(forInfoDictionaryKey: "PatchWindowDiagnosticsEnabled") as? Bool == true else { return }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Patch/Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            shared = WindowActivationDiagnostics(file: directory.appendingPathComponent("window-activation.log"))
        } catch {
            NSLog("Patch window diagnostics could not start: %@", error.localizedDescription)
        }
    }

    private init(file: URL) {
        self.file = file
        super.init()
        for name in [NSApplication.didFinishLaunchingNotification, NSApplication.willResignActiveNotification,
                     NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(observe(_:)), name: name, object: nil)
        }
        record("diagnostics.start")
    }

    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func observe(_ note: Notification) { record(note.name.rawValue) }

    func record(_ event: String) {
        let visible = NSApp.orderedWindows.filter { $0.isVisible }.map { "\($0.windowNumber):\($0.level.rawValue)" }
        let state = "active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
            + "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") "
            + "presentation=\(NSApp.presentationOptions.rawValue)/\(NSApp.currentSystemPresentationOptions.rawValue) "
            + "menuBar=\(NSMenu.menuBarVisible()) mainMenuItems=\(NSApp.mainMenu?.numberOfItems ?? 0) "
            + "windows=\(visible)"
        let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        lines.append("\(Date().ISO8601Format()) uptime=\(uptime) \(event) \(state)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Patch window diagnostics could not write: %@", error.localizedDescription)
        }
    }
}
