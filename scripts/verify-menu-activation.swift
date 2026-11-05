// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT
import AppKit
import Darwin

@MainActor private final class ActivationChecks: NSObject, NSApplicationDelegate {
    private let coordinator = WindowActivationCoordinator.shared
    private var windows: [NSWindow] = []

    private func makeWindow(_ title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 140, y: 180, width: 300, height: 180),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "WindowActivationVerification", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitFor(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            try require(Date() < deadline, "Timed out: " + description)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await checkLifecycle()
                windows.forEach { $0.close() }
                await nextTurn()
                print("PASS: functional-window activation lifecycle")
                fflush(stdout)
                exit(0)
            } catch {
                windows.forEach { $0.close() }
                print("FAIL: \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
        }
    }

    private func checkLifecycle() async throws {
        let pin = makeWindow("Ordinary pin fixture")
        pin.level = .floating
        pin.orderFront(nil)
        try require(NSApp.activationPolicy() == .accessory, "An unregistered pin enabled the Dock")
        try require(!coordinator.restoreWindow(), "A Dock reopen targeted an unregistered pin")

        let first = makeWindow("Functional window one")
        let second = makeWindow("Functional window two")
        coordinator.register(first)
        try require(NSApp.activationPolicy() == .regular, "Registration must promote before the window is shown")
        try require(!first.isVisible, "Registration itself made a window visible")
        coordinator.register(first)
        first.makeKeyAndOrderFront(nil)
        coordinator.register(second)
        second.makeKeyAndOrderFront(nil)
        first.close()
        await nextTurn()
        try require(NSApp.activationPolicy() == .regular, "Closing one of two windows removed the Dock")
        second.close()
        await nextTurn()
        try require(NSApp.activationPolicy() == .accessory, "Duplicate registration kept a closed window registered")
        try require(pin.isVisible, "Closing functional windows hid an ordinary pin")

        coordinator.register(first)
        first.makeKeyAndOrderFront(nil)
        first.miniaturize(nil)
        try await waitFor("minimizing a functional window", condition: { first.isMiniaturized })
        await nextTurn()
        try require(NSApp.activationPolicy() == .regular, "Minimizing removed the Dock restore entry")
        try require(coordinator.restoreWindow(), "Dock reopen did not find the minimized window")
        try await waitFor("restoring a functional window", condition: { !first.isMiniaturized && first.isVisible })
        try require(!second.isVisible, "Dock reopen opened another functional window")
        first.close()
        await nextTurn()
        try require(NSApp.activationPolicy() == .accessory, "Closing a reopened window did not demote")

        coordinator.register(first)
        first.makeKeyAndOrderFront(nil)
        first.orderOut(nil)
        coordinator.unregister(first)
        coordinator.unregister(first)
        await nextTurn()
        try require(NSApp.activationPolicy() == .accessory, "Explicit hiding did not release the Dock entry")
        try require(!coordinator.restoreWindow(), "Dock reopen restored an explicitly hidden window")

        coordinator.register(first)
        first.makeKeyAndOrderFront(nil)
        first.close()
        coordinator.register(second)
        second.makeKeyAndOrderFront(nil)
        try require(NSApp.activationPolicy() == .regular, "A same-event window handoff demoted immediately")
        await nextTurn()
        try require(NSApp.activationPolicy() == .regular, "An old demotion ran after a new window opened")
        second.orderOut(nil)
        coordinator.unregister(second)
        coordinator.register(second)
        second.makeKeyAndOrderFront(nil)
        await nextTurn()
        try require(NSApp.activationPolicy() == .regular, "A hide/show handoff kept a stale demotion")
        second.close()
        await nextTurn()
        try require(NSApp.activationPolicy() == .accessory, "The last functional window did not release the Dock")
        print("Checked multi-window close, duplicate/reopen, minimize/Dock restore, hide, handoff, and pin-only state")
    }
}

@main private struct VerifyMenuActivation {
    @MainActor static func main() {
        let app = NSApplication.shared
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            print("SKIP: unlock the screen before running native activation verification")
            exit(77)
        }
        app.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let root = NSMenuItem()
        root.submenu = NSMenu(title: "Window activation verification")
        root.submenu!.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(root)
        app.mainMenu = menu
        let delegate = ActivationChecks()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
