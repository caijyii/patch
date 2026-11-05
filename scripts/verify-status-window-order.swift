// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT
// Two-process AppKit fixture using programmatic menu clicks and cooperative
// activation. The wrapper supplies distinct application bundles and identities.
// Each mode reuses one StatusBarControls for three menu cycles.
// --handoff explicitly activates the helper before menuWillOpen,
// --late-handoff during tracking, and --post-close-handoff after menuDidClose.
// All explicit helper activations must remain with that application.
// The post-close mode verifies that a subsequent explicit helper activation is
// allowed to remain in front while the Patch windows retain their relative order.
// The foreground/background checks sample order every 20 ms while tracking.
// This does not verify real MenuBarAgent clicks or changes shorter than the
// sample interval. It never operates user apps.
import AppKit
import Darwin
func L(_ value: String) -> String { value }

@MainActor final class MenuLifecycleObserver: NSObject, NSMenuDelegate {
    let controls: StatusBarControls
    let forwardsCallbacks: Bool
    var closedMenus = 0

    init(controls: StatusBarControls, forwardsCallbacks: Bool) {
        self.controls = controls
        self.forwardsCallbacks = forwardsCallbacks
    }

    func menuWillOpen(_ menu: NSMenu) {
        if forwardsCallbacks { controls.menuWillOpen(menu) }
    }

    func menuDidClose(_ menu: NSMenu) {
        if forwardsCallbacks { controls.menuDidClose(menu) }
        closedMenus += 1
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var hiddenWindow: NSWindow!
    var controls: StatusBarControls!
    var menuObserver: MenuLifecycleObserver!
    var helper: Process?
    var baseline: [Int] = []
    var observations = 0
    var cycle = 0
    let cycleCount = 3
    var cycleFailure: String?
    var failure: String?
    var timers: [Timer] = []
    var samplingTimer: Timer?
    let background = CommandLine.arguments.contains("--background")
    let handoff = CommandLine.arguments.contains("--handoff")
    let lateHandoff = CommandLine.arguments.contains("--late-handoff")
    let postCloseHandoff = CommandLine.arguments.contains("--post-close-handoff")
    let outside = CommandLine.arguments.contains("--outside")

    func order() -> [Int] {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter {
            let pid = $0[kCGWindowOwnerPID as String] as? Int32
            return (pid == getpid() || pid == helper?.processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0
        }.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { action() } }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        timers.append(timer)
    }

    func waitFor(_ description: String, condition: @escaping @MainActor () -> Bool,
                 then action: @escaping @MainActor () -> Void, deadline: Date = Date().addingTimeInterval(5)) {
        if condition() { action(); return }
        guard Date() < deadline else {
            print("front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) "
                + "self=\(getpid()) helper=\(helper?.processIdentifier ?? 0) order=\(order()) active=\(NSApp.isActive) "
                + "bundle=\(Bundle.main.bundleIdentifier ?? "nil") "
                + "hidden=\(NSApp.isHidden) policy=\(NSApp.activationPolicy().rawValue) "
                + "windows=\(windows.map { "\($0.windowNumber):visible=\($0.isVisible),space=\($0.isOnActiveSpace)" })")
            finish("Timed out: " + description)
            return
        }
        after(0.05) { self.waitFor(description, condition: condition, then: action, deadline: deadline) }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let helperMode = CommandLine.arguments.contains("--helper")
        for index in 0..<(helperMode ? 1 : 2) {
            let window = NSWindow(contentRect: CGRect(x: 150 + index * 40, y: 180 + index * 40, width: 360, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Keep all fixture windows on the current desktop even if the host
            // has per-app Spaces assignments. Production window behavior is
            // unchanged; this check compares stacking within one desktop.
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.title = helperMode ? "Other application fixture" : "Patch ordering fixture \(index)"
            window.backgroundColor = helperMode ? .systemGreen : .systemBlue
            windows.append(window)
            if !helperMode && !CommandLine.arguments.contains("--baseline") {
                WindowActivationCoordinator.shared.register(window)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if helperMode { return }
        hiddenWindow = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        hiddenWindow.isReleasedWhenClosed = false
        let process = Process()
        var helperExecutable = CommandLine.arguments[0]
        if let index = CommandLine.arguments.firstIndex(of: "--helper-executable") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                finish("Missing path after --helper-executable")
                return
            }
            helperExecutable = CommandLine.arguments[index + 1]
        }
        process.executableURL = URL(fileURLWithPath: helperExecutable)
        process.arguments = ["--helper"]
        do { try process.run() } catch { finish(error.localizedDescription); return }
        helper = process
        waitFor("helper activation", condition: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier && self.order().count == 3
        }) {
            if CommandLine.arguments.contains("--helper-executable") {
                let ownID = Bundle.main.bundleIdentifier
                let helperID = NSRunningApplication(processIdentifier: process.processIdentifier)?.bundleIdentifier
                print("Application identities: parent=\(ownID ?? "nil") helper=\(helperID ?? "nil")")
                guard ownID != nil, helperID != nil, ownID != helperID else {
                    self.finish("Parent and helper must have distinct registered application identities")
                    return
                }
            }
            self.startCheck()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Cooperative activation makes the synthetic handoff repeatable. It
        // does not establish the activation behavior of real user applications.
        if CommandLine.arguments.contains("--helper"),
           let parent = NSRunningApplication(processIdentifier: getppid()) {
            NSApp.yieldActivation(to: parent)
        }
    }

    func startCheck() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Test menu", action: nil, keyEquivalent: "")
        controls = StatusBarControls(menu: menu)
        let baselineMode = CommandLine.arguments.contains("--baseline")
        menuObserver = MenuLifecycleObserver(controls: controls, forwardsCallbacks: !baselineMode)
        menu.delegate = menuObserver
        // --baseline leaves the fixture in accessory mode for comparison.
        // Programmatic clicks cannot prove the real MenuBarAgent regression.
        print("Synthetic fixture: three cycles; programmatic clicks, cooperative helper")
        prepareCycle()
    }

    func prepareCycle() {
        cycle += 1
        cycleFailure = nil
        if background {
            handFocusToHelper()
            waitFor("background fixture activation", condition: {
                !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == self.helper?.processIdentifier
            }) { self.beginCycle() }
            return
        }
        // Reproduce the user bringing the same windows forward again between
        // clicks without rebuilding the status item or its activation state.
        for window in windows { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        waitFor("fixture activation for cycle \(cycle)", condition: {
            NSApp.isActive && self.order().first == self.windows.last!.windowNumber
        }) {
            for window in self.windows { window.makeKeyAndOrderFront(nil) }
            self.after(0.1) { self.beginCycle() }
        }
    }

    func beginCycle() {
        baseline = order()
        print("cycle=\(cycle) before active=\(NSApp.isActive) order=\(baseline)"); fflush(stdout)
        if handoff {
            handFocusToHelper()
            waitFor("focus handed to helper", condition: { !NSApp.isActive && self.order().first != self.windows.last!.windowNumber }) {
                print("cycle=\(self.cycle) handoff active=\(NSApp.isActive) order=\(self.order())"); fflush(stdout)
                self.baseline = self.order()
                self.openMenu()
            }
        } else { openMenu() }
    }

    func handFocusToHelper() {
        let other = NSRunningApplication(processIdentifier: helper!.processIdentifier)!
        NSApp.yieldActivation(to: other)
        other.activate(options: [.activateAllWindows])
    }

    func snapshot(_ phase: String) {
        let current = order()
        let front = NSWorkspace.shared.frontmostApplication
        print("cycle=\(cycle) \(phase) active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) "
            + "front=\(front?.bundleIdentifier ?? String(front?.processIdentifier ?? 0)) "
            + "self=\(getpid()) helper=\(helper?.processIdentifier ?? 0) order=\(current)")
        fflush(stdout)
        let own = Set(windows.map(\.windowNumber))
        let expectsHelperInFront = handoff || lateHandoff || outside || (postCloseHandoff && phase == "after")
        if expectsHelperInFront {
            if current.first.map(own.contains) != false || current.filter(own.contains) != baseline.filter(own.contains) {
                cycleFailure = "Explicit helper activation changed the expected window order"
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != helper?.processIdentifier {
                cycleFailure = "Explicit helper activation did not keep the helper in front"
            }
        } else if current != baseline {
            cycleFailure = "Menu changed the order of the two Patch windows and the other app"
        }
        if windows.contains(where: { $0.level != .normal }) || hiddenWindow.isVisible {
            cycleFailure = "Menu changed window levels or revealed a hidden window"
        }
        if NSApp.isActive == (background || expectsHelperInFront) { cycleFailure = "Menu changed the foreground application" }
    }

    func sampleMenuOrder() {
        // Explicit outside activation is checked after it has settled. The
        // stable foreground/background cases also catch short-lived changes.
        guard !lateHandoff && !outside else { return }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                if self.order() != self.baseline {
                    self.cycleFailure = "Window order changed while tracking the menu"
                }
                if NSApp.isActive == (self.background || self.handoff) {
                    self.cycleFailure = "Foreground application changed while tracking the menu"
                }
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        samplingTimer = timer
    }

    func openMenu() {
        sampleMenuOrder()
        let expectedClosures = menuObserver.closedMenus + 1
        if lateHandoff || outside { after(0.1) { self.handFocusToHelper() } }
        after(0.45) {
            self.snapshot("during")
            self.observations += 1
            self.samplingTimer?.invalidate()
            self.samplingTimer = nil
            self.controls.menu.cancelTrackingWithoutAnimation()
        }
        controls.menuButton.performClick(nil)
        waitFor("menu close for cycle \(cycle)", condition: {
            self.observations == self.cycle && self.menuObserver.closedMenus >= expectedClosures
        }) {
            // The observer increments only after forwarding menuDidClose.
            // Keep the synthetic transfer separate from menu close processing.
            // This explicit activation must remain with the helper. It provides
            // no evidence of a delayed handoff caused by the status menu itself.
            self.after(0.1) {
                if self.postCloseHandoff {
                    print("cycle=\(self.cycle) post-close handoff"); fflush(stdout)
                    self.handFocusToHelper()
                }
                self.after(0.3) { self.completeCycle() }
            }
        }
    }

    func completeCycle() {
        snapshot("after")
        if let cycleFailure {
            print("cycle=\(cycle) FAIL: \(cycleFailure)")
            if failure == nil { failure = "Cycle \(cycle): \(cycleFailure)" }
        } else {
            print("cycle=\(cycle) PASS")
        }
        fflush(stdout)
        if cycle < cycleCount {
            prepareCycle()
        } else {
            finish(failure)
        }
    }

    func finish(_ error: String?) {
        timers.forEach { $0.invalidate() }
        samplingTimer?.invalidate()
        if let helper, helper.isRunning {
            helper.terminate()
            helper.waitUntilExit()
        }
        controls?.remove()
        print(error.map { "FAIL: " + $0 } ?? "PASS: menu window ordering")
        fflush(stdout)
        exit(error == nil ? 0 : 1)
    }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
            print("SKIP: unlock the screen before running native window-order verification")
            exit(77)
        }
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(CommandLine.arguments.contains("--helper") ? .regular : .accessory)
        let mainMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = NSMenu(title: "Window ordering verification")
        root.submenu!.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(root)
        app.mainMenu = mainMenu
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
