// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Functional windows use normal application activation. Desktop pins and
/// capture overlays do not register, so they can run with only a menu-bar icon.
@MainActor
final class WindowActivationCoordinator: NSObject {
    static let shared = WindowActivationCoordinator()

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var pendingDemotion: DispatchWorkItem?
    private var isTerminating = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: NSApp)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Call before ordering the window on screen or activating the application.
    /// A minimized window stays registered so its Dock entry can restore it.
    func register(_ window: NSWindow) {
        guard !isTerminating else { return }
        pendingDemotion?.cancel()
        pendingDemotion = nil
        windows.add(window)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// Closing is observed centrally. Hidden panels and inline editors whose
    /// host pin remains open must explicitly end their functional-window role.
    func unregister(_ window: NSWindow) {
        guard windows.contains(window) else { return }
        windows.remove(window)
        guard windows.allObjects.isEmpty, !isTerminating else { return }
        pendingDemotion?.cancel()
        let demotion = DispatchWorkItem { [weak self] in
            guard let self, !self.isTerminating, self.windows.allObjects.isEmpty else { return }
            self.pendingDemotion = nil
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        }
        pendingDemotion = demotion
        // Allow a close/show handoff within this event to retain the Dock entry.
        DispatchQueue.main.async(execute: demotion)
    }

    /// A Dock click returns to an existing functional window, including one
    /// that was minimized, before the app considers opening its settings home.
    func restoreWindow() -> Bool {
        let registered = windows.allObjects
        guard let window = NSApp.orderedWindows.first(where: { windows.contains($0) }) ?? registered.first else {
            return false
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        unregister(window)
    }

    @objc private func applicationWillTerminate() {
        isTerminating = true
        pendingDemotion?.cancel()
        pendingDemotion = nil
    }
}
