import AppKit
import Darwin

@MainActor private final class WorkflowHotKeys: HotKeyBackend {
    var callback: ((UInt32) -> Void)?
    var ids: [KeyboardShortcut: UInt32] = [:]
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 { self.callback = callback; return 0 }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> {
        ids[shortcut] = eventID; return .success(.init(rawValue: UInt64(eventID)))
    }
    func unregister(_ token: HotKeyToken) -> Int32 { 0 }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> { .success([]) }
    func fire(_ shortcut: KeyboardShortcut) { callback?(ids[shortcut]!) }
}

@main private struct VerifyWorkflow {
    @MainActor private static var launchObserver: NSObjectProtocol?
    @MainActor static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            fputs("FAIL: workflow verification timed out\n", stderr)
            exit(1)
        }
        AppLocalization.language = CommandLine.arguments.contains("--english") ? .english : .simplifiedChinese
        if CommandLine.arguments.contains("--status-layout") { runStatusLayoutProbe(); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var permitted = false
        var activations = 0
        var prompts = 0
        let permission = ScreenCapturePermission(check: { permitted }, activate: { activations += 1 },
            present: { prompts += 1; return .later }, request: { false }, openSettings: {})
        let backend = WorkflowHotKeys()
        let memory = MemoryPreferencesStorage()
        let preferences = PreferencesStore(storage: memory)
        let delegate = AppDelegate(preferences: preferences, hotKeyBackend: backend, monitorsClipboard: false,
                                   captureService: CaptureService(permission: permission))
        app.delegate = delegate
        func verifyAfterLaunch() async {
            func require(_ condition: Bool, _ message: String) {
                if !condition { print("FAIL: \(message)"); exit(1) }
            }
            func settleActiveWindow(_ window: NSWindow, line: Int = #line) async {
                let deadline = Date().addingTimeInterval(5)
                while !(app.isActive && window.isKeyWindow) && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if !app.isActive || !window.isKeyWindow {
                    delegate.workflowTrace("activation-timeout at line \(line)")
                }
                require(app.isActive && window.isKeyWindow,
                        "Native activation did not finish at line \(line): \(window.title)")
            }
            let home = delegate.workflowHome!
            await settleActiveWindow(home.window!)
            print("PASS: native application activation and Home key-window state are ready")
            require(app.activationPolicy() == .regular, "Home must enable normal application activation before showing")
            require(prompts == 0 && activations == 0, "Opening Home unexpectedly requests access")
            if CommandLine.arguments.contains("--startup-only") {
                require(home.window?.isVisible == true, "Startup did not present Home")
                let screenshotItem = delegate.workflowMenu.items.first { $0.title == ShortcutAction.screenshot.title }
                require(screenshotItem?.keyEquivalent == preferences.shortcuts[.screenshot]?.menuKeyEquivalent,
                        "Startup menu did not refresh after shortcut registration")
                require(delegate.workflowMenuShortcuts == Set(preferences.shortcutBindings.values.flatMap { $0 }),
                        "Startup menu did not receive the registered shortcuts")
                print("PASS: complete startup initializes menu before hotkeys, then refreshes shortcuts and shows Home")
                app.terminate(nil)
                return
            }
            home.tiles[.screenshot]!.launchButton.performClick(nil)
            require(prompts == 1 && activations == 1, "Home click missed foreground permission guidance")
            backend.fire(preferences.shortcuts[.screenshot]!)
            require(prompts == 2 && activations == 2, "Shortcut differs from Home permission path")
            permitted = true
            delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
            require(prompts == 2 && permission.isGranted, "Activation requests permission rather than refreshing it")
            print("PASS: Home and shortcut share permission guidance; launch and return only read status")

            backend.fire(preferences.shortcuts[.recentContent]!)
            require(app.windows.contains { $0.isVisible && $0.title == L("Patch · 剪贴记录") },
                    "Clipboard history shortcut did not open its window")

            let store = delegate.workflowHistory
            let historyController = delegate.workflowHistoryController!
            let status = delegate.workflowStatusControls
            status.menuWillOpen(status.menu)
            status.menuDidClose(status.menu)
            let historyItem = status.menu.items.first { $0.action == NSSelectorFromString("showRecentContent") }!
            status.menu.performActionForItem(at: status.menu.index(of: historyItem))
            require(delegate.workflowHistoryController === historyController && historyController.window?.isVisible == true,
                    "Menu and shortcut must reuse the same history without capturing a paste destination")
            let historyContent = historyController.window!.contentView!
            func historyViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(historyViews) }
            let historyFilter = historyViews(historyContent).compactMap { $0 as? NSSegmentedControl }.first!
            historyFilter.selectedSegment = 2
            historyFilter.sendAction(historyFilter.action, to: historyFilter.target)
            weak var closedCard: NSView?
            autoreleasepool {
                store.addText("closed history fixture")
                closedCard = historyViews(historyContent).first {
                    $0.identifier?.rawValue.hasPrefix("history.card.") == true
                }
                require(closedCard != nil, "Visible history did not reload its cards")
                historyController.close()
                let remaining = historyViews(historyContent).filter {
                    $0.identifier?.rawValue.hasPrefix("history.card.") == true
                }.count
                print("HISTORY_CLOSE: cards=\(remaining), attached=\(closedCard?.superview != nil), window=\(closedCard?.window != nil)")
                require(remaining == 0, "Closing history did not remove its card views")
            }
            // AppKit can keep removed views in autoreleased subview arrays and
            // pending display work until the current event has finished.
            let releaseDeadline = Date().addingTimeInterval(2)
            while closedCard != nil && Date() < releaseDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("HISTORY_RELEASE: released=\(closedCard == nil)")
            require(closedCard == nil, "Closing history retained its card content")
            store.addText("copied while history closed")
            require(!historyViews(historyContent).contains { $0.identifier?.rawValue.hasPrefix("history.card.") == true },
                    "Closed history rebuilt cards on a clipboard update")
            backend.fire(preferences.shortcuts[.recentContent]!)
            require(delegate.workflowHistoryController === historyController && historyFilter.selectedSegment == 2
                    && historyViews(historyContent).filter { $0.identifier?.rawValue.hasPrefix("history.card.") == true }.count == 2,
                    "Reopening history lost its filter or failed to reload current records")
            store.clear()
            historyFilter.selectedSegment = 0
            historyFilter.sendAction(historyFilter.action, to: historyFilter.target)
            print("PASS: closed history releases card content and defers rebuilding until reopen, preserving the filter")
            store.addText("earliest")
            store.addImage(DemoImage.make(), pixelScale: 2)
            for index in 1...4 { store.addText("text \(index)") }
            let ids = store.items.map(\.id)
            let menu = delegate.workflowMenu
            let batch = menu.items.first { $0.title == L("贴出最近 5 条") }!
            let visibilityItem = menu.items.first { $0.action == NSSelectorFromString("togglePins") }!
            let visibleMenuItems = menu.items.filter { !$0.isHidden }
            let visibilityIndex = visibleMenuItems.firstIndex(of: visibilityItem)!
            require(visibilityIndex == visibleMenuItems.firstIndex(of: batch)! + 1
                    && visibleMenuItems[visibilityIndex + 1].isSeparatorItem
                    && visibleMenuItems[visibilityIndex + 2].title == L("设置"),
                    "Pin visibility must stay with pin actions, separated from Settings and Quit")
            require(delegate.validateMenuItem(batch), "Populated history disabled batch action")
            menu.performActionForItem(at: menu.index(of: batch))
            let pins = app.windows.filter { $0.isVisible && [L("Patch · 图片贴图"), L("Patch · 文字贴图")].contains($0.title) }
            require(pins.count == 5 && pins.filter { $0.title == L("Patch · 图片贴图") }.count == 1,
                    "Batch must pin first five mixed records, including text and image")
            require(store.items.map(\.id) == ids, "Batch reordered or duplicated history")
            delegate.workflowImageTools.closeAll()
            preferences.setPinRecentCount(1); delegate.workflowApplyOptions()
            require(batch.title == preferences.pinRecentTitle && home.tiles[.pinRecent]?.launchButton.title == preferences.pinRecentTitle,
                    "Count setting did not update the actual menu and pane titles")
            backend.fire(preferences.shortcuts[.pinRecent]!)
            let single = app.windows.filter { $0.isVisible && [L("Patch · 图片贴图"), L("Patch · 文字贴图")].contains($0.title) }
            require(single.count == 1 && single.first?.title == L("Patch · 文字贴图"), "Batch shortcut ignored count or latest mixed content")
            require(PreferencesStore(storage: memory).pinRecentCount == 1, "Batch size did not persist")
            delegate.workflowImageTools.closeAll()
            preferences.setPinRecentCount(20); delegate.workflowApplyOptions()
            menu.performActionForItem(at: menu.index(of: batch))
            let all = app.windows.filter { $0.isVisible && [L("Patch · 图片贴图"), L("Patch · 文字贴图")].contains($0.title) }
            require(all.count == 6 && store.items.map(\.id) == ids, "Fewer records than configured count must pin all available without altering history")
            store.clear()
            require(!delegate.validateMenuItem(batch) && all.allSatisfy(\.isVisible)
                    && home.tiles[.pinRecent]?.launchButton.isEnabled == false,
                    "History clear must disable menu/pane batch actions without closing pins")
            require(menu.items.filter { $0.title == L("设置") }.count == 1 && !menu.items.contains { $0.title == L("外观与历史") },
                    "Settings menu is not unified")
            print("PASS: history/batch shortcuts, configurable mixed batching, live titles, empty states and independent desktop pins")

            let tools = delegate.workflowImageTools
            tools.closeAll()
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            func visiblePins() -> [NSWindow] {
                app.windows.filter { $0.isVisible && [L("Patch · 图片贴图"), L("Patch · 文字贴图")].contains($0.title) }
            }
            for isImage in [true, false] {
                tools.pinImage(DemoImage.make(), recordsHistory: false)
                let older = visiblePins()
                backend.fire(preferences.shortcuts[.togglePins]!)
                require(tools.arePinsHidden && older.allSatisfy { !$0.isVisible }, "Hide all left old pins visible")
                pasteboard.clearContents()
                if isImage {
                    let representation = NSBitmapImageRep(cgImage: DemoImage.make())
                    pasteboard.setData(representation.representation(using: .png, properties: [:])!, forType: .png)
                } else {
                    pasteboard.setString("new clipboard text", forType: .string)
                }
                tools.pinClipboard(from: pasteboard)
                let newlyPinned = visiblePins()
                require(newlyPinned.count == 1 && older.allSatisfy { !$0.isVisible },
                        "Pin after hide all must show only the new \(isImage ? "image" : "text"), leaving old pins hidden")
                require(!tools.arePinsHidden, "A visible new pin still reports all pins hidden")
                let visibilityMenu = menu.items.first { $0.action == NSSelectorFromString("togglePins") }!
                require(visibilityMenu.title == L("隐藏全部贴图")
                        && home.tiles[.togglePins]?.launchButton.title == L("隐藏全部贴图"),
                        "Menu or Home did not immediately update after adding the only visible pin")
                newlyPinned.forEach { $0.close() }
                require(tools.arePinsHidden && visibilityMenu.title == L("显示全部贴图")
                        && home.tiles[.togglePins]?.launchButton.title == L("显示全部贴图"),
                        "Closing the only visible pin did not update all-hidden state and action titles")
                backend.fire(preferences.shortcuts[.togglePins]!)
                require(older.allSatisfy(\.isVisible) && !tools.arePinsHidden, "Explicit show all did not restore hidden pins")
                tools.closeAll()
                require(!tools.hasPins && !tools.arePinsHidden, "Closing all pins left stale visibility state")
            }
            store.clear()
            store.addText("batch text")
            store.addImage(DemoImage.make(), pixelScale: 2)
            tools.pinText("older hidden pin", recordsHistory: false)
            let olderBatch = visiblePins()
            backend.fire(preferences.shortcuts[.togglePins]!)
            backend.fire(preferences.shortcuts[.pinRecent]!)
            require(visiblePins().count == 2 && olderBatch.allSatisfy { !$0.isVisible },
                    "Batch pin unexpectedly restored previously hidden pins")
            backend.fire(preferences.shortcuts[.togglePins]!)
            require(visiblePins().isEmpty && tools.arePinsHidden, "Hide all did not hide mixed old and new pins")
            backend.fire(preferences.shortcuts[.togglePins]!)
            require(visiblePins().count == 2 && olderBatch.allSatisfy { !$0.isVisible } && !tools.arePinsHidden,
                    "Restore must show only the most recently hidden group")
            store.clear()
            require(visiblePins().count == 2, "Deleting clipboard records closed independent desktop pins")
            let restoredBatch = visiblePins()
            tools.togglePins()
            restoredBatch.forEach { $0.close() }
            require(!tools.canTogglePins && olderBatch.allSatisfy { !$0.isVisible }
                    && !delegate.validateMenuItem(visibilityItem),
                    "Closing the latest hidden group made an older hidden group restorable")
            tools.togglePins()
            require(visiblePins().isEmpty, "A stale restore action revived an older group")
            tools.closeAll()
            print("PASS: image/text pins preserve older hidden groups; only the latest hidden group restores; history deletion leaves pins independent")

            let recorder = delegate.workflowRecording
            let screen = NSScreen.main!
            let fixtureRegion = CaptureRegion(rect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 160, height: 100),
                displayID: CGMainDisplayID(), screenFrame: screen.frame, scale: 1, targetPID: nil)
            recorder.showControls(region: fixtureRegion)
            await settleActiveWindow(recorder.workflowPanel!)
            let showControls = menu.items.first { $0.action == NSSelectorFromString("showRecordingControls") }!
            let pauseRecording = menu.items.first { $0.action == NSSelectorFromString("toggleRecordingPause") }!
            let recordingAction = menu.items.first { $0.action == NSSelectorFromString("recordScreen") }!
            require(showControls.isHidden && pauseRecording.isHidden && delegate.workflowStatusControls.item.menu === menu,
                    "Idle recording controls exposed active recording actions")
            let statusControls = delegate.workflowStatusControls
            for phase in ["preparing", "countdown", "starting", "recording", "paused"] {
                recorder.workflowSetPhase(phase)
                require(statusControls.menuButton.bounds.width == StatusBarControls.buttonWidth && statusControls.item.menu === statusControls.menu,
                        "Patch must not duplicate the macOS recording control")
            }
            recorder.workflowSetPhase("recording")
            recorder.workflowSetPhase("idle")
            require(delegate.workflowStatusControls.item.menu === menu && pauseRecording.isHidden && recordingAction.title == L("录屏"),
                    "Recording menu actions did not reset after finishing")
            recorder.workflowPanel?.performClose(nil)
            require(!recorder.hasControls && showControls.isHidden && !delegate.validateMenuItem(showControls),
                    "Closing idle recording controls left a stale Show Controls action")
            menu.performActionForItem(at: menu.index(of: showControls))
            require(!recorder.hasControls, "A stale Show Controls action reopened a closed recording")
            print("PASS: single menu-bar icon and recording menu state cleanup without capturing a screen")

            func settlePolicy(_ expected: NSApplication.ActivationPolicy, line: Int = #line) async {
                let deadline = Date().addingTimeInterval(2)
                while (app.activationPolicy() != expected || (expected == .regular && !app.isActive)) && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if app.activationPolicy() != expected || (expected == .regular && !app.isActive) {
                    delegate.workflowTrace("policy-timeout at line \(line)")
                }
                require(app.activationPolicy() == expected && (expected != .regular || app.isActive),
                        "Activation policy mismatch at line \(line): expected \(expected.rawValue), actual \(app.activationPolicy().rawValue), active=\(app.isActive)")
            }
            func settleClosedWindow(_ window: NSWindow, line: Int = #line) async {
                let deadline = Date().addingTimeInterval(2)
                while window.isVisible && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if window.isVisible {
                    let visible = app.windows.filter(\.isVisible).map {
                        "\($0.windowNumber) \($0.title) frame=\($0.frame) key=\($0.isKeyWindow) minimized=\($0.isMiniaturized)"
                    }
                    print("CLOSE_TIMEOUT: line=\(line) window=\(window.windowNumber) policy=\(app.activationPolicy().rawValue) frame=\(window.frame) visible=\(visible)")
                }
                require(!window.isVisible, "Window close did not finish at line \(line): \(window.title)")
            }
            home.close()
            await settleClosedWindow(home.window!)
            await settlePolicy(.regular)
            historyController.close()
            await settleClosedWindow(historyController.window!)
            tools.closeAll()
            await settlePolicy(.accessory)
            require(home.window?.isVisible == false, "Home remained visible after closing all functional windows")
            tools.pinImage(DemoImage.make(), recordsHistory: false)
            await settlePolicy(.accessory)
            require(home.window?.isVisible == false, "An ordinary pin reopened Home")
            tools.showEditor(DemoImage.make())
            await settlePolicy(.regular)
            require(home.window?.isVisible == false, "Showing the editor reopened Home before the Dock action")
            _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true)
            require(home.window?.isVisible == false, "A Dock click opened Home instead of returning to the editor")
            tools.closeAll()
            await settlePolicy(.accessory)
            recorder.showControls(region: fixtureRegion)
            await settlePolicy(.regular)
            recorder.hideControls()
            await settlePolicy(.accessory)
            recorder.showControls()
            await settlePolicy(.regular)
            recorder.workflowPanel?.performClose(nil)
            await settlePolicy(.accessory)
            home.showWindow(nil)
            await settlePolicy(.regular)
            home.close()
            await settleClosedWindow(home.window!)
            await settlePolicy(.accessory)
            print("PASS: production Home/history/editor/recording entries manage Dock lifetime; ordinary pins stay independent")
            print("PASS: workflow verification completed")
            app.terminate(nil)
        }
        launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
            object: app, queue: .main) { _ in
                // The delegate and all launch observers finish before checks run.
                Task { @MainActor in
                    guard let observer = launchObserver else { return }
                    NotificationCenter.default.removeObserver(observer)
                    launchObserver = nil
                    await verifyAfterLaunch()
                }
            }
        app.run()
        withExtendedLifetime(delegate) {}

    }

    /// A real application run loop is required for status items to be hosted.
    /// This mode checks the production controls without starting media capture.
    @MainActor private static func runStatusLayoutProbe() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let permission = ScreenCapturePermission(check: { false }, activate: {}, present: { .later }, request: { false }, openSettings: {})
        let delegate = AppDelegate(preferences: PreferencesStore(storage: MemoryPreferencesStorage()),
            hotKeyBackend: WorkflowHotKeys(), monitorsClipboard: false, captureService: CaptureService(permission: permission))
        app.delegate = delegate
        func require(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); fflush(stdout); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { delegate.workflowHome?.window?.orderOut(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let controls = delegate.workflowStatusControls
            let originalItem = ObjectIdentifier(controls.item)
            require(controls.menuButton.bounds.width == 22 && controls.item.menu === controls.menu,
                    "Idle does not contain only the main icon")
            let recorder = delegate.workflowRecording
            for phase in ["preparing", "countdown", "starting"] {
                recorder.workflowSetPhase(phase)
                require(recorder.isRecording && controls.item.menu === controls.menu,
                        "Preparation phase \(phase) exposed Stop before recording began")
            }
            for phase in ["recording", "paused"] {
                delegate.workflowRecording.workflowSetPhase(phase)
                controls.menuButton.layoutSubtreeIfNeeded()
                require(ObjectIdentifier(controls.item) == originalItem && controls.menuButton.bounds.width == 22
                        && controls.item.menu === controls.menu,
                        "Patch duplicated the system recording control")

            }
            let originalAppearance = app.appearance
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                app.appearance = NSAppearance(named: appearance)
                controls.menuButton.layoutSubtreeIfNeeded()
                require(controls.menuButton.image?.isTemplate == true,
                        "Main icon lost native template appearance")
                for button in [controls.menuButton] {
                    require(button.title.isEmpty && button.attributedTitle.string.isEmpty && button.imagePosition == .imageOnly,
                            "Status controls contain title text")
                    require(button.accessibilityRole() == .button && button.acceptsFirstResponder,
                            "Status menu button lost its button role or keyboard focus")
                }
                if let bitmap = controls.menuButton.bitmapImageRepForCachingDisplay(in: controls.menuButton.bounds) {
                    controls.menuButton.cacheDisplay(in: controls.menuButton.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(".build/verification/workflow/native-status-menu-\(name).png")
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
                print("NATIVE_STATUS_APPEARANCE: app=\(name) menuBar=\(controls.menuButton.effectiveAppearance.name.rawValue)")
            }
            app.appearance = originalAppearance
            delegate.workflowRecording.workflowSetPhase("idle")
            require(controls.item.menu === controls.menu && controls.menuButton.bounds.width == 22,
                    "Idle retained an active Stop control or its extra space")
            print("PASS: real-run-loop status layout keeps only the Patch icon across phases and appearances")
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
