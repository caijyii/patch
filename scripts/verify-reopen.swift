import AppKit
import Darwin

/// Memory preferences and fake registrations: no Carbon hotkeys, screen capture, or posted input.
@MainActor private final class ReopenHotKeyBackend: HotKeyBackend {
    private var next: UInt64 = 0
    private(set) var bindings: [HotKeyToken: KeyboardShortcut] = [:]
    var blocked: Set<KeyboardShortcut> = []
    var reserved: Set<KeyboardShortcut> = []
    var checkFailure: Int32?
    var releaseBlocked: Set<HotKeyToken> = []
    private var callback: ((UInt32) -> Void)?
    private var eventIDs: [HotKeyToken: UInt32] = [:]
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 { self.callback = callback; return 0 }
    func fire(_ shortcut: KeyboardShortcut) {
        guard let token = bindings.first(where: { $0.value == shortcut })?.key, let id = eventIDs[token] else { return }
        callback?(id)
    }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> {
        if blocked.contains(shortcut) { return .failure(.init(status: -9877)) }
        next += 1
        let token = HotKeyToken(rawValue: next)
        bindings[token] = shortcut
        eventIDs[token] = eventID
        return .success(token)
    }
    func unregister(_ token: HotKeyToken) -> Int32 {
        if releaseBlocked.contains(token) { return -50 }
        bindings.removeValue(forKey: token)
        eventIDs.removeValue(forKey: token)
        return 0
    }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> {
        if let checkFailure { return .failure(.init(status: checkFailure)) }
        return .success(reserved)
    }
}

@main struct ReopenProbe {
    @MainActor static var completedGroups = 0
    @MainActor static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); fflush(stdout); exit(1) }
    }
    @MainActor static func passed(_ message: String) {
        completedGroups += 1
        print("PASS: \(message)"); fflush(stdout)
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func buttons(_ content: NSView) -> [NSButton] {
        descendants(content).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }
    @MainActor static func button(_ title: String, _ content: NSView) -> NSButton {
        guard let result = buttons(content).first(where: { $0.title == title }) else {
            fatalError("missing visible \(title) button")
        }
        return result
    }
    @MainActor static func click(_ title: String, _ content: NSView) {
        let control = button(title, content)
        require(control.isEnabled, "\(title) is unexpectedly disabled")
        control.performClick(nil)
    }
    @MainActor static func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map { menuItems($0) } ?? []) }
    }
    @MainActor static func invoke(_ item: NSMenuItem, in menu: NSMenu) {
        let index = menu.index(of: item)
        require(index >= 0 && item.isEnabled, "attempted to invoke a missing or disabled menu item")
        menu.performActionForItem(at: index)
    }
    @MainActor static func key(_ window: NSWindow, _ code: UInt16, _ text: String,
                              _ modifiers: NSEvent.ModifierFlags = [.control, .option]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    @MainActor static func enter(_ home: HomeWindowController, _ action: ShortcutAction,
                                _ code: UInt16, _ text: String,
                                _ modifiers: NSEvent.ModifierFlags = [.control, .option]) {
        home.beginEditing(action)
        require(home.window!.performKeyEquivalent(with: key(home.window!, code, text, modifiers)),
                "shortcut key was not consumed by Home")
        require(home.isEditing && home.editor.recordingAction == action,
                "input stopped continuous recording")
    }
    @MainActor static func controls(_ home: HomeWindowController, editing: Bool) {
        let titles = buttons(home.window!.contentView!).map(\.title)
        require(!titles.contains("完成"), "Home exposes the obsolete Done label")
        require(titles.contains("恢复默认") && titles.contains("保存") == editing && titles.contains("取消") == editing && titles.contains("关闭") != editing,
                "footer does not follow the edit session")
        require(home.tiles.filter { $0.key != .togglePins }.values.allSatisfy { $0.launchButton.isEnabled != editing }, "feature launch state disagrees with editing")
    }
    @MainActor static func status(_ home: HomeWindowController) -> String {
        descendants(home.window!.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "home.shortcut-status" }?.stringValue ?? ""
    }
    @MainActor static func settle(_ content: NSView) {
        content.layoutSubtreeIfNeeded(); CATransaction.flush()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        content.layoutSubtreeIfNeeded()
    }
    @MainActor static func fixedLayout(_ home: HomeWindowController) {
        let window = home.window!, content = window.contentView!
        content.layoutSubtreeIfNeeded()
        require(abs(content.bounds.width - 648) < 0.1 && abs(content.bounds.height - 536) < 0.1,
                "Home changed its fixed 648 by 536 content size")
        require(!window.styleMask.contains(.resizable), "Home unexpectedly allows resizing")
        for control in buttons(content) {
            let frame = control.convert(control.bounds, to: content)
            require(content.bounds.contains(frame), "a visible control is clipped: \(control.title)")
        }
        let footerControls = buttons(content).filter { ["恢复默认", "保存", "取消", "关闭"].contains($0.title) }
        require(footerControls.allSatisfy { $0.image != nil && $0.imagePosition == .imageLeading },
                "footer actions do not share icon-and-title presentation")
        let restore = footerControls.first { $0.title == "恢复默认" }!
        let restoreRect = restore.convert(restore.bounds, to: content)
        require(abs(restoreRect.minX - 24) < 1 && restoreRect.minY >= 484,
                "Restore Defaults moved away from the fixed page margin")
        for (index, control) in footerControls.enumerated() {
            for other in footerControls.dropFirst(index + 1) {
                require(!control.convert(control.bounds, to: content).intersects(other.convert(other.bounds, to: content)),
                        "footer controls overlap")
            }
        }
        if let note = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "home.shortcut-status" }), !note.isHidden {
            let frame = note.convert(note.bounds, to: content)
            require(content.bounds.contains(frame), "status label is clipped")
            let buttonCaption = restore.convert(restore.cell!.titleRect(forBounds: restore.bounds), to: content)
            let statusCaption = note.convert(note.cell!.titleRect(forBounds: note.bounds), to: content)
            require(abs(buttonCaption.midY - statusCaption.midY) < 0.5 && note.font == restore.font,
                    "native status caption is not aligned with Restore Defaults text")
            for control in footerControls {
                require(!frame.intersects(control.convert(control.bounds, to: content)), "status overlaps footer controls")
            }
        }
    }
    /// Renders only the app's own content view; no desktop image or capture permission.
    @MainActor static func preview(_ home: HomeWindowController, _ name: String, _ directory: URL) {
        let content = home.window!.contentView!
        settle(content)
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { fatalError("native render allocation failed") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("native render encoding failed") }
        do { try data.write(to: directory.appendingPathComponent(name + ".png")) }
        catch { require(false, "native preview write failed: \(error)") }
        require(bitmap.pixelsWide >= 648 && bitmap.pixelsHigh >= 536, "native preview is incomplete")
    }
    @MainActor static func counts(_ home: HomeWindowController) -> [ShortcutAction: Int] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.displayOrder.map { ($0, home.tiles[$0]!.polishCount) })
    }
    @MainActor static func polished(_ home: HomeWindowController, since before: [ShortcutAction: Int], only changed: Set<ShortcutAction>) {
        for action in ShortcutAction.displayOrder {
            require(home.tiles[action]!.polishCount == before[action]! + (changed.contains(action) ? 1 : 0),
                    "incorrect polish count for \(action)")
            require(home.tiles[action]!.surface.mask?.animationKeys()?.isEmpty != false,
                    "save feedback uncovers the dark scenery instead of softly lighting the glass")
        }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".build/verification/reopen")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { require(false, "verification directory creation failed: \(error)") }
        let store = PreferencesStore(storage: MemoryPreferencesStorage())
        let delegate = AppDelegate(preferences: store, hotKeyBackend: ReopenHotKeyBackend())
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let window = app.windows.first(where: { $0.identifier?.rawValue == "patch.home" }),
              let home = window.windowController as? HomeWindowController, let content = window.contentView else {
            require(false, "initial Home controller did not appear"); return
        }
        require(window.isVisible, "initial Home is hidden")
        click("关闭", content)
        require(!window.isVisible, "Close button did not close Home")
        let callbacks: NSApplicationDelegate = delegate
        _ = callbacks.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        require(window.isVisible, "reopening after Close did not restore Home")
        window.orderOut(nil)
        _ = callbacks.applicationShouldHandleReopen?(app, hasVisibleWindows: false)
        require(window.isVisible, "reopening after hiding did not restore Home")
        require(app.windows.filter { $0.identifier?.rawValue == "patch.home" }.count == 1, "duplicate Home windows")
        passed("reopening restores the same closed or hidden Home controller")

        settle(content); fixedLayout(home)
        require(window.level == .normal && window.titlebarAppearsTransparent && window.isOpaque && content.isOpaque,
                "Home chrome or opacity is incorrect")
        let names = ["截图", "长截图", "主体截图", "录屏", "提取文字", "贴图"]
        let tiles = home.allTiles
        require(tiles.count == 8 && Array(tiles.prefix(6)).map { $0.launchButton.title } == names, "eight panes do not follow the requested order")
        require(buttons(content).count == 18, "idle Home must expose eight launches, eight keycaps, Restore Defaults and Close")
        require(Array(delegate.verificationMenuTitles.prefix(6)) == ShortcutAction.displayOrder.map {
            "\($0.title)"
        }, "status menu feature order disagrees with Home")
        for (index, tile) in tiles.enumerated() {
            let rect = tile.convert(tile.bounds, to: content)
            require(content.bounds.contains(rect) && tile.fixedFrame.frame == tile.bounds && tile.bounds.contains(tile.surface.frame), "tile is clipped")
            require(tile.surface.frame.minX > 1 && tile.surface.frame.minY > 1, "glass does not leave clearance for stationary frame")
            require(tile.frame.minY == tiles[index / 4 * 4].frame.minY, "tile is not in its grid row")
            if index % 4 > 0 { require(tile.frame.minX > tiles[index - 1].frame.maxX, "grid columns overlap") }
            if index >= 4 { require(tile.frame.minY > tiles[index - 4].frame.maxY, "grid rows overlap") }
            require(!tile.launchButton.isBordered && !tile.shortcutButton.isBordered, "native controls gained separate chrome")
        }
        require(home.tiles[.subject]?.shortcutButton.title == "⌥6" && delegate.responds(to: Selector(("subjectScreenshot"))),
                "subject screenshot lacks its default key or delegate action")
        controls(home, editing: false); preview(home, "home-idle", directory)
        func hover(_ tile: HomeFeatureTile, over control: NSButton) {
            let location = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            tile.mouseMoved(with: event)
        }
        let emptyPins = home.tiles[.togglePins]!
        require(!emptyPins.launchButton.isEnabled && emptyPins.shortcutButton.isEnabled, "empty pins must retain shortcut editing")
        hover(emptyPins, over: emptyPins.shortcutButton)
        require(emptyPins.isShortcutHovered && !emptyPins.isLaunchHovered && emptyPins.isHovered, "disabled function swallowed editable shortcut hover")
        require(CATransform3DIsIdentity(emptyPins.surface.superlayer!.transform), "disabled pane opened")
        preview(home, "home-disabled-shortcut-hover", directory)
        hover(emptyPins, over: emptyPins.launchButton)
        require(!emptyPins.isShortcutHovered && !emptyPins.isLaunchHovered && emptyPins.isHovered, "disabled function gained active feedback or lost glass feedback")
        emptyPins.resetInteraction()
        let capture = home.tiles[.screenshot]!
        let restingFont = capture.launchButton.font!
        hover(capture, over: capture.launchButton)
        require(capture.isLaunchHovered && !capture.isShortcutHovered, "function hover is missing")
        require(capture.launchButton.superview === capture && capture.shortcutButton.superview === capture,
                "native controls still rotate with the glass and become resampled")
        require(capture.launchButton.font == restingFont && CATransform3DIsIdentity(capture.launchButton.layer!.transform),
                "hover changes text weight or applies a transform to native controls")
        let sash = capture.surface.superlayer!
        require(sash.superlayer !== capture.layer, "3D glass shares the controls' compositing plane")
        require(capture.fixedFrame.superlayer === capture.layer && capture.fixedFrame.zPosition > sash.zPosition,
                "fixed frame is not above the moving sash")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            require(!CATransform3DIsIdentity(sash.transform), "hover did not open the sash")
            let glassFrontZ = capture.bounds.width * abs(sash.transform.m13)
            require(capture.launchButton.layer!.zPosition > glassFrontZ && capture.shortcutButton.layer!.zPosition > glassFrontZ,
                    "lifted glass can wash out the enabled controls")
            require(capture.launchButton.isEnabled && capture.launchButton.contentTintColor!.usingColorSpace(.sRGB)!.redComponent < 0.21,
                    "hovered launch is disabled or lighter than its normal color")
            require(sash.transform.m13 > 0 && sash.transform.m14 < 0,
                    "free edge must lift toward the viewer, not away")
            require(CATransform3DIsIdentity(capture.fixedFrame.transform), "fixed frame rotates with glass")
            require(sash.shadowOpacity > 0 && sash.shadowOpacity < 0.2, "open sash lacks a subtle shadow")
            // Check the projected glass corners stay inside the fixed rim, including perspective.
            for x in [capture.surface.frame.minX, capture.surface.frame.maxX] {
                for y in [capture.surface.frame.minY, capture.surface.frame.maxY] {
                    let localY = y - capture.bounds.midY, t = sash.transform
                    let w = x * t.m14 + localY * t.m24 + t.m44
                    let projected = NSPoint(x: (x * t.m11 + localY * t.m21 + t.m41) / w,
                                            y: (x * t.m12 + localY * t.m22 + t.m42) / w + capture.bounds.midY)
                    require(capture.bounds.insetBy(dx: 1, dy: 1).contains(projected), "opened glass overlaps fixed frame")
                }
            }
            let restingOpen = sash.transform
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            require(CATransform3DEqualToTransform(sash.transform, restingOpen), "sash did not remain open after transition")
            require(sash.presentation().map { !CATransform3DIsIdentity($0.transform) } == true,
                    "composited sash did not remain open after transition")
            preview(home, "home-hover-open", directory)
        }
        hover(capture, over: capture.shortcutButton)
        require(!capture.isLaunchHovered && capture.isShortcutHovered, "shortcut hover also emphasizes function")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            require(!CATransform3DIsIdentity(sash.transform), "moving to shortcut closed the sash")
        }
        let exitEvent = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        capture.mouseExited(with: exitEvent)
        require(CATransform3DIsIdentity(sash.transform) && !capture.isHovered, "pointer exit did not close sash")
        require(sash.shadowOpacity == 0, "closed sash retains shadow")
        hover(capture, over: capture.launchButton)
        capture.resetInteraction()
        require(CATransform3DIsIdentity(sash.transform), "reset left the sash open")
        hover(home.quitTile, over: home.quitTile.launchButton)
        require(home.quitTile.isLaunchHovered && !home.quitTile.isShortcutHovered, "quit lacks active function feedback")
        preview(home, "home-quit-hover", directory)
        hover(home.quitTile, over: home.quitTile.shortcutButton)
        require(!home.quitTile.isLaunchHovered && !home.quitTile.isShortcutHovered && !home.quitTile.shortcutButton.isEnabled,
                "fixed Command-Q appears editable")
        home.quitTile.resetInteraction()
        require(!home.quitTile.isHovered, "quit hover was not cleared")
        passed("opaque fixed-size Home lays out eight native controls in the approved four-by-two order")

        let statusMenu = delegate.verificationStatusMenu
        for (action, item) in zip(ShortcutAction.displayOrder, statusMenu.items.prefix(6)) {
            require(item.title == action.title && item.keyEquivalent == action.defaultShortcut.menuKeyEquivalent
                    && item.keyEquivalentModifierMask == [.option], "global shortcuts do not use the native right-hand menu column")
            require(!statusMenu.performKeyEquivalent(with: key(window, UInt16(action.defaultShortcut.keyCode), item.keyEquivalent, [.option])),
                    "menu duplicates dispatch owned by the global shortcut handler")
        }
        for code in KeyboardShortcut.keyNames.keys {
            let chord = KeyboardShortcut(keyCode: code, modifiers: [.control, .option])
            require(chord.menuKeyEquivalent.unicodeScalars.count == 1, "key code \(code) lacks a native menu equivalent")
        }
        statusMenu.update()
        let settingsAction = Selector(("showSettings"))
        let settingsEntries = statusMenu.items.filter { $0.action == settingsAction }
        let mainSettingsEntries = menuItems(app.mainMenu!).filter { $0.action == settingsAction }
        require(settingsEntries.count == 1 && mainSettingsEntries.count == 1, "Settings menu action is duplicated or missing")
        require(!statusMenu.items.contains { $0.title.contains("打开小贴") || $0.title.contains("修改快捷键") || $0.title.contains("设置快捷键") }, "obsolete settings entry remains")
        for item in settingsEntries + mainSettingsEntries {
            require(item.title == "设置" && item.target === delegate && item.keyEquivalent == "," && item.keyEquivalentModifierMask == [.command],
                    "Settings lost its target or Command-comma shortcut")
        }
        window.close(); invoke(settingsEntries[0], in: statusMenu)
        require(window.isVisible && !home.isEditing, "status Settings failed to reopen idle Home")
        window.close()
        require(app.mainMenu!.performKeyEquivalent(with: key(window, 43, ",", [.command])), "Command-comma did not dispatch")
        require(window.isVisible && !home.isEditing && !app.windows.contains { $0.isVisible && $0.windowController is SettingsController }, "Command-comma opened an incorrect editor")
        let original = store.shortcuts, originalMenu = delegate.verificationMenuTitles
        enter(home, .screenshot, 25, "9")
        require(store.shortcuts == original && delegate.verificationMenuTitles == originalMenu, "draft changed preferences or live menu")
        controls(home, editing: true); click("保存", content)
        require(store.shortcuts[.screenshot]?.keyCode == 25 && !home.isEditing && home.tiles[.screenshot]?.shortcutButton.title == "⌃⌥9" && delegate.verificationStatusMenu.items.first?.keyEquivalent == "9" && delegate.verificationStatusMenu.items.first?.keyEquivalentModifierMask == [.control, .option], "Done did not synchronize preferences, keycap and real menu")
        enter(home, .screenshot, 26, "7")
        _ = window.performKeyEquivalent(with: key(window, 53, "", []))
        require(store.shortcuts[.screenshot]?.keyCode == 25 && delegate.verificationStatusMenu.items.first?.keyEquivalent == "9" && delegate.verificationStatusMenu.items.first?.keyEquivalentModifierMask == [.control, .option], "cancel changed the real menu")
        controls(home, editing: false); window.close()
        passed("single Settings action and Command-comma reuse Home; only Done synchronizes the real menu")

        guard let pinItem = statusMenu.items.first(where: { $0.action == Selector(("togglePins")) }) else {
            require(false, "status menu lost its pin visibility action"); return
        }
        let coordinator = delegate.verificationImageTools
        func requirePinAction(_ title: String, enabled: Bool, hidden: Bool) {
            // Run AppKit's actual target validation, as opening the menu does.
            statusMenu.update()
            require(pinItem.title == title && pinItem.keyEquivalent == store.shortcuts[.togglePins]?.menuKeyEquivalent && pinItem.isEnabled == enabled,
                    "pin menu state is \(pinItem.title), enabled=\(pinItem.isEnabled); expected \(title), enabled=\(enabled)")
            require(coordinator.hasPins == enabled && coordinator.arePinsHidden == hidden,
                    "coordinator state disagrees with its live menu action")
        }
        requirePinAction("隐藏全部贴图", enabled: false, hidden: false)
        let existingWindowIDs = Set(app.windows.map(ObjectIdentifier.init))
        let generatedImage = DemoImage.make()
        coordinator.pinImage(generatedImage)
        coordinator.pinImage(generatedImage)
        coordinator.pinText("仅用于菜单验证的文字贴图。")
        let pinTitles: Set<String> = ["小贴 · 图片贴图", "小贴 · 文字贴图"]
        let pins = app.windows.filter { !existingWindowIDs.contains(ObjectIdentifier($0)) && pinTitles.contains($0.title) }
        require(pins.count == 3 && pins.filter { $0.title == "小贴 · 图片贴图" }.count == 2 &&
                pins.filter { $0.title == "小贴 · 文字贴图" }.count == 1 && pins.allSatisfy(\.isVisible),
                "two generated image pins and one text pin did not coexist visibly")
        requirePinAction("隐藏全部贴图", enabled: true, hidden: false)
        invoke(pinItem, in: statusMenu)
        require(pins.allSatisfy { !$0.isVisible }, "Hide did not hide every image and text pin")
        requirePinAction("显示全部贴图", enabled: true, hidden: true)
        invoke(pinItem, in: statusMenu)
        require(pins.allSatisfy(\.isVisible), "Restore did not restore every image and text pin")
        requirePinAction("隐藏全部贴图", enabled: true, hidden: false)
        invoke(pinItem, in: statusMenu)
        requirePinAction("显示全部贴图", enabled: true, hidden: true)
        let beforeNewPin = Set(app.windows.map(ObjectIdentifier.init))
        coordinator.pinImage(generatedImage)
        let newPins = app.windows.filter { !beforeNewPin.contains(ObjectIdentifier($0)) && pinTitles.contains($0.title) }
        require(newPins.count == 1 && newPins[0].isVisible && pins.allSatisfy(\.isVisible),
                "adding a pin while hidden did not restore the existing pins")
        requirePinAction("隐藏全部贴图", enabled: true, hidden: false)
        let allPins = pins + newPins
        for (index, pin) in allPins.enumerated() {
            pin.close()
            requirePinAction("隐藏全部贴图", enabled: index < allPins.count - 1, hidden: false)
        }
        require(allPins.allSatisfy { !$0.isVisible }, "closing the generated pins left a pin window visible")
        passed("live pin menu validates empty/visible/hidden states across multiple image and text pins, additions and individual closes")


        let memory = MemoryPreferencesStorage()
        let fixtureStore = PreferencesStore(storage: memory), backend = ReopenHotKeyBackend()
        let hotKeys = HotKeys(backend: backend)
        var launches: [ShortcutAction] = [], saveCount = 0
        let actions = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, {}) })
        require(hotKeys.installShortcuts(fixtureStore.shortcuts, actions: actions).isEmpty, "fake registration failed")
        let fixture = HomeWindowController(hotKeys: hotKeys, store: fixtureStore, onSave: { saveCount += 1 }, onLaunch: { launches.append($0) })
        let w = fixture.window!, c = w.contentView!
        fixture.showWindow(nil); settle(c)
        for action in ShortcutAction.displayOrder {
            let tile = fixture.tiles[action]!
            for control in [tile.launchButton, tile.shortcutButton] {
                // Top outer corners lie outside the arch; only visible glass is a launch target.
                let points = control === tile.launchButton
                    ? [NSPoint(x: control.bounds.midX, y: control.bounds.midY), NSPoint(x: 2, y: control.bounds.midY), NSPoint(x: control.bounds.maxX - 2, y: control.bounds.maxY - 2)]
                    : [NSPoint(x: control.bounds.midX, y: control.bounds.midY), NSPoint(x: 2, y: 2), NSPoint(x: control.bounds.maxX - 2, y: control.bounds.maxY - 2)]
                for point in points {
                    let hit = c.hitTest(control.convert(point, to: c.superview))
                    require(hit === control, "actual hit test missed \(control.identifier?.rawValue ?? control.title)")
                }
            }
            let opens = tile.openingCount
            tile.launchButton.performClick(nil)
            require(launches.last == action && tile.openingCount == opens + 1, "feature click lost launch or opening feedback")
            tile.shortcutButton.performClick(nil)
            require(fixture.editor.recordingAction == action && hotKeys.isRecordingShortcut && w.firstResponder === tile.shortcutButton, "keycap recording lost first responder")
            require(tile.openingCount == opens + 1, "editing shortcut incorrectly opened the sash")
            controls(fixture, editing: true); fixedLayout(fixture)
            fixture.cancelEditing(); controls(fixture, editing: false)
        }
        require(launches == ShortcutAction.displayOrder, "shortcut editing dispatched a feature")
        passed("actual hit tests reach native controls; six launches open their sash and keycaps retain independent focus")

        let initialSaved = fixtureStore.shortcuts, initialWrites = memory.writeCount
        let tile = fixture.tiles[.screenshot]!, beforeManual = counts(fixture)
        fixture.beginEditing(.screenshot)
        w.makeFirstResponder(tile.launchButton)
        w.sendEvent(key(w, 8, "c", [.control]))
        require(fixture.editor.draft[.screenshot] == KeyboardShortcut(keyCode: 8, modifiers: [.control]) && fixture.isEditing && hotKeys.isRecordingShortcut, "window lost Control-C when focus moved away from keycap")
        require(w.performKeyEquivalent(with: key(w, 25, "9")), "valid-to-valid replacement was not captured")
        require(fixture.editor.draft[.screenshot] == KeyboardShortcut(keyCode: 25, modifiers: [.control, .option])
                && fixture.editor.recordingAction == .screenshot && hotKeys.isRecordingShortcut
                && tile.shortcutButton.title == "⌃⌥9", "valid replacement stopped listening or lost displayed chord")
        backend.fire(ShortcutAction.text.defaultShortcut)
        require(fixture.editor.hasIssue(.screenshot) && hotKeys.isRecordingShortcut,
                "registered shortcut after valid input was dispatched instead of recorded")
        require(w.performKeyEquivalent(with: key(w, 8, "c", [.control])), "second replacement was not captured")
        require(!fixture.editor.hasIssues && hotKeys.isRecordingShortcut, "valid correction ended listening")
        require(fixtureStore.shortcuts == initialSaved && hotKeys.registeredShortcuts == initialSaved && saveCount == 0 && memory.writeCount == initialWrites, "manual input committed before Done")
        require(status(fixture).isEmpty, "valid shortcuts should not display a success hint")
        polished(fixture, since: beforeManual, only: []); fixedLayout(fixture)
        click("保存", c)
        let saved = fixtureStore.shortcuts
        require(saved[.screenshot] == KeyboardShortcut(keyCode: 8, modifiers: [.control]) && hotKeys.registeredShortcuts == saved && saveCount == 1 && !fixture.isEditing, "Done did not commit the complete draft")
        polished(fixture, since: beforeManual, only: [.screenshot])
        let beforeNoop = counts(fixture)
        enter(fixture, .screenshot, 8, "c", [.control]); click("保存", c)
        polished(fixture, since: beforeNoop, only: [])
        require(memory.writeCount == initialWrites + 1, "unchanged Done rewrote preferences")
        passed("native Control-C remains a draft until Done; only a changed saved shortcut polishes its tile")

        let lifecycleWrites = memory.writeCount, lifecycleSaves = saveCount, lifecyclePolish = counts(fixture)
        func requireCancelled(_ reason: String) {
            require(!fixture.isEditing && !hotKeys.isRecordingShortcut && fixture.editor.draft == saved && fixtureStore.shortcuts == saved && hotKeys.registeredShortcuts == saved && memory.writeCount == lifecycleWrites && saveCount == lifecycleSaves, "\(reason) did not discard only unconfirmed input")
            polished(fixture, since: lifecyclePolish, only: []); fixedLayout(fixture)
        }
        enter(fixture, .text, 25, "9")
        fixture.beginEditing(.pin)
        require(w.performKeyEquivalent(with: key(w, 53, "", [])), "Esc during recording was not consumed")
        requireCancelled("recording Esc"); require(w.isVisible, "first Esc closed Home")
        enter(fixture, .subject, 26, "7")
        _ = w.performKeyEquivalent(with: key(w, 53, "", [])); requireCancelled("draft Esc")
        fixture.beginEditing(.record)
        fixture.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: w)); requireCancelled("unchanged blur")
        fixture.beginEditing(.pin); w.close(); requireCancelled("unchanged close")
        fixture.showWindow(nil); controls(fixture, editing: false)
        enter(fixture, .text, 25, "9")
        let beforeTab = fixture.editor.draft
        fixture.beginEditing(.pin)
        require(!w.performKeyEquivalent(with: key(w, 48, "\t", [])), "Tab was swallowed instead of returning to native navigation")
        require(fixture.isEditing && fixture.editor.recordingAction == nil && !hotKeys.isRecordingShortcut && fixture.editor.draft == beforeTab && fixtureStore.shortcuts == saved, "Tab changed or discarded the pending draft")
        require(w.makeFirstResponder(button("保存", c)), "Done is not a native focus target after Tab")
        require(w.firstResponder === button("保存", c), "focus did not reach Done")
        fixture.cancelEditing(); requireCancelled("cancel after Tab")
        w.cancelOperation(nil); require(!w.isVisible, "Esc outside editing did not close Home")
        fixture.showWindow(nil)
        passed("Esc cancels drafts; unchanged close and blur exit without writes; Tab retains the draft and restores native focus navigation")

        let failureWrites = memory.writeCount, failurePolish = counts(fixture)
        func requireBlockedSave() {
            let save = button("保存", c)
            require(!save.isEnabled && hotKeys.isRecordingShortcut, "invalid draft can save or stopped listening")
            let writes = memory.writeCount, saves = saveCount
            save.performClick(nil)
            require(memory.writeCount == writes && saveCount == saves && fixture.isEditing,
                    "disabled Save submitted a draft")
        }
        enter(fixture, .screenshot, 0, "a", [])
        requireBlockedSave()
        fixture.cancelEditing()
        enter(fixture, .screenshot, 12, "q", [.command])
        require(fixture.editor.hasIssue(.screenshot), "reserved Command-Q has no feedback")
        requireBlockedSave()
        require(fixture.isEditing && fixtureStore.shortcuts == saved && hotKeys.registeredShortcuts == saved, "reserved shortcut was committed")
        fixture.cancelEditing()
        enter(fixture, .screenshot, 19, "2", [.option])
        let launchesBeforeRetry = launches
        require(fixture.tiles[.screenshot]?.shortcutButton.title == "⌥2" && hotKeys.isRecordingShortcut,
                "rejected chord is hidden or no longer listening")
        backend.fire(ShortcutAction.text.defaultShortcut)
        require(fixture.editor.draft[.screenshot] == ShortcutAction.text.defaultShortcut && fixture.editor.hasIssue(.screenshot)
                && fixture.editor.recordingAction == .screenshot && launches == launchesBeforeRetry,
                "registered shortcut retry launched a feature instead of replacing rejected input")
        require(w.performKeyEquivalent(with: key(w, 25, "9")), "new chord requires another click after conflict")
        require(!fixture.editor.hasIssues && fixture.editor.recordingAction == .screenshot && hotKeys.isRecordingShortcut
                && fixtureStore.shortcuts == saved, "corrected chord did not become a valid unsaved draft")
        require(button("保存", c).isEnabled, "corrected chord did not immediately enable Save")
        fixture.cancelEditing()
        enter(fixture, .screenshot, 19, "2", [.option])
        require(fixture.editor.hasIssue(.screenshot) && fixture.editor.hasIssue(.scroll) && fixture.editor.message(.screenshot).contains("相同快捷键"), "duplicate did not identify both endpoints")
        require(status(fixture) == "快捷键冲突", "Home shows verbose duplicate instructions")
        requireBlockedSave()
        preview(fixture, "home-save-disabled", directory)
        require(!fixture.finishEditing(), "outside-save bypassed conflict validation")
        require(fixtureStore.shortcuts == saved && hotKeys.registeredShortcuts == saved, "duplicate changed active registrations")
        require(fixture.editor.recordingAction == .screenshot && hotKeys.isRecordingShortcut,
                "failed save stopped conflict correction")
        fixture.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: w))
        require(fixture.editor.recordingAction == nil && !hotKeys.isRecordingShortcut,
                "conflicted editor captures input after losing focus")
        fixture.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: w))
        require(fixture.editor.recordingAction == .screenshot && hotKeys.isRecordingShortcut,
                "returning to conflicted editor does not resume correction")
        enter(fixture, .scroll, 8, "c", [.control])
        require(!fixture.editor.hasIssues && button("保存", c).isEnabled, "repairing the other endpoint left stale feedback or disabled Save")
        require(fixtureStore.shortcuts == saved, "a complete swap draft committed before Done")
        fixture.cancelEditing()
        backend.reserved = [KeyboardShortcut(keyCode: 25, modifiers: [.control, .option])]
        enter(fixture, .screenshot, 25, "9"); requireBlockedSave()
        require(fixture.editor.message(.screenshot).contains("系统") && fixtureStore.shortcuts == saved && hotKeys.registeredShortcuts == saved, "system-reserved shortcut bypassed feedback or rollback")
        backend.reserved = []; fixture.cancelEditing()
        require(memory.writeCount == failureWrites, "a rejected input wrote preferences")
        polished(fixture, since: failurePolish, only: [])
        passed("application, duplicate and system conflicts retain active shortcuts; both duplicate endpoints can be repaired in one draft")

        let replacement = KeyboardShortcut(keyCode: 25, modifiers: [.control, .option])
        backend.blocked = [replacement]
        enter(fixture, .screenshot, 25, "9"); click("保存", c)
        require(fixture.isEditing && fixture.editor.message(.screenshot).contains("不可用") && fixtureStore.shortcuts == saved && hotKeys.registeredShortcuts == saved, "registration rejection lost feedback or original bindings")
        fixedLayout(fixture); preview(fixture, "home-shortcut-error", directory)
        backend.blocked = []; click("保存", c)
        var corrected = saved; corrected[.screenshot] = replacement
        require(!fixture.isEditing && fixtureStore.shortcuts == corrected && hotKeys.registeredShortcuts == corrected, "registration retry did not save the retained draft")
        fixture.beginEditing(.pin); backend.checkFailure = -77; fixture.refreshShortcuts()
        // A new recording recalculates model feedback rather than only redrawing it.
        fixture.editor.startRecording(.pin); fixture.editor.stopRecording()
        require(ShortcutAction.allCases.allSatisfy { fixture.editor.hasIssue($0) }, "system-query failure lacks all affected rows")
        click("保存", c); fixedLayout(fixture)
        require(status(fixture) == "暂时无法检查" && !status(fixture).contains("\n"),
                "Home repeats detailed shortcut errors instead of a concise status")
        preview(fixture, "home-shortcut-multiple-errors", directory)
        backend.checkFailure = nil; fixture.cancelEditing()
        passed("registration and system-query errors preserve configuration, show concise feedback and support retry")

        let beforeRestore = counts(fixture), restoreWrites = memory.writeCount
        backend.blocked = [ShortcutAction.screenshot.defaultShortcut]
        enter(fixture, .text, 26, "7"); click("恢复默认", c)
        require(fixtureStore.shortcuts == corrected && hotKeys.registeredShortcuts == corrected && fixture.editor.draft == corrected && memory.writeCount == restoreWrites, "failed default restore changed saved, active or visible values")
        require(fixture.editor.hasIssue(.screenshot) && (fixture.editor.message(.screenshot).contains("保留") || fixture.editor.message(.screenshot).contains("仍使用")), "batch editor lost immediate-default failure feedback")
        require(ShortcutAction.displayOrder.allSatisfy { fixture.tiles[$0]?.shortcutButton.title == corrected[$0]?.displayString }, "failed default restore left a changed keycap")
        polished(fixture, since: beforeRestore, only: []); fixedLayout(fixture)
        backend.blocked = []
        enter(fixture, .text, 26, "7"); click("恢复默认", c)
        require(fixtureStore.shortcuts == ShortcutAction.defaultShortcuts && hotKeys.registeredShortcuts == fixtureStore.shortcuts && fixture.editor.draft == fixtureStore.shortcuts && !fixture.isEditing, "restore defaults did not commit immediately")
        polished(fixture, since: beforeRestore, only: [.screenshot])
        let beforeDefaultNoop = counts(fixture)
        require(!fixture.isEditing, "idle restore fixture is unexpectedly editing")
        click("恢复默认", c)
        polished(fixture, since: beforeDefaultNoop, only: [])
        let beforeCancel = fixtureStore.shortcuts, beforeCancelWrites = memory.writeCount, beforeCancelPolish = counts(fixture)
        enter(fixture, .subject, 26, "7")
        let cancelControl = button("取消", c)
        let cancelLocation = cancelControl.convert(NSPoint(x: cancelControl.bounds.midX, y: cancelControl.bounds.midY), to: nil)
        let cancelEvent = NSEvent.mouseEvent(with: .leftMouseDown, location: cancelLocation, modifierFlags: [], timestamp: 0,
                                            windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        require((w as! ShortcutSettingsWindow).onPointerDown?(cancelEvent) == false && fixture.isEditing,
                "Cancel click auto-saved before discarding the draft")
        cancelControl.performClick(nil)
        require(!fixture.isEditing && fixtureStore.shortcuts == beforeCancel && memory.writeCount == beforeCancelWrites
                && fixture.editor.draft == beforeCancel, "Cancel did not discard only the unsaved draft")
        polished(fixture, since: beforeCancelPolish, only: [])
        controls(fixture, editing: false)
        let beforeDraftReset = counts(fixture), savedDefaultWrites = memory.writeCount
        enter(fixture, .subject, 26, "7"); click("恢复默认", c)
        require(memory.writeCount == savedDefaultWrites && fixtureStore.shortcuts == ShortcutAction.defaultShortcuts, "discarding a draft rewrote unchanged defaults")
        polished(fixture, since: beforeDraftReset, only: [])
        // Saved defaults do not prove restoration succeeded: a launch registration
        // may be unavailable while the user has an unrelated unconfirmed draft.
        let unavailableStore = PreferencesStore(storage: MemoryPreferencesStorage())
        let unavailableBackend = ReopenHotKeyBackend()
        unavailableBackend.blocked = [ShortcutAction.screenshot.defaultShortcut]
        let unavailableKeys = HotKeys(backend: unavailableBackend)
        _ = unavailableKeys.installShortcuts(unavailableStore.shortcuts, actions: actions)
        let unavailable = HomeWindowController(hotKeys: unavailableKeys, store: unavailableStore, onSave: {}, onLaunch: { _ in })
        unavailable.showWindow(nil)
        let unavailableActive = unavailableKeys.registeredShortcuts, beforeUnavailable = counts(unavailable)
        enter(unavailable, .pin, 26, "7")
        click("恢复默认", unavailable.window!.contentView!)
        require(!unavailable.editor.defaultsWereCommitted && unavailableStore.shortcuts == ShortcutAction.defaultShortcuts && unavailableKeys.registeredShortcuts == unavailableActive && unavailable.editor.draft == unavailableStore.shortcuts && unavailable.editor.hasIssue(.screenshot),
                "saved defaults incorrectly marked a rejected restoration as committed")
        polished(unavailable, since: beforeUnavailable, only: [])
        fixedLayout(unavailable); unavailable.window!.close(); w.makeKeyAndOrderFront(nil)
        passed("immediate defaults roll back on failure and polish only actual saved changes; unchanged defaults stay still")

        let defaultToken = backend.bindings.first { $0.value == ShortcutAction.screenshot.defaultShortcut }!.key
        backend.releaseBlocked = [defaultToken]
        let beforeWarning = counts(fixture)
        enter(fixture, .screenshot, 25, "9"); click("保存", c)
        require(fixtureStore.shortcuts[.screenshot] == replacement && hotKeys.registeredShortcuts == fixtureStore.shortcuts && fixture.isEditing && fixture.editor.message(.screenshot).contains("释放未完成"), "cleanup warning hid a successful commit or closed its feedback")
        polished(fixture, since: beforeWarning, only: [.screenshot])
        backend.releaseBlocked = []; click("保存", c)
        require(!fixture.isEditing && hotKeys.cleanupWarnings.isEmpty && backend.bindings.count == ShortcutAction.allCases.count, "Done did not retry deferred cleanup")
        polished(fixture, since: beforeWarning, only: [.screenshot])
        let replacementToken = backend.bindings.first { $0.value == replacement }!.key
        backend.releaseBlocked = [replacementToken]
        let beforeDefaultWarning = counts(fixture)
        enter(fixture, .pin, 26, "7"); click("恢复默认", c)
        require(fixture.editor.defaultsWereCommitted && fixtureStore.shortcuts == ShortcutAction.defaultShortcuts && hotKeys.registeredShortcuts == fixtureStore.shortcuts && fixture.editor.message(.screenshot).contains("释放未完成"), "default restore cleanup warning lost committed defaults or feedback")
        polished(fixture, since: beforeDefaultWarning, only: [.screenshot])
        backend.releaseBlocked = []; click("保存", c)
        require(hotKeys.cleanupWarnings.isEmpty && !fixture.isEditing && backend.bindings.count == ShortcutAction.allCases.count, "default restore cleanup could not be retried")
        polished(fixture, since: beforeDefaultWarning, only: [.screenshot])
        passed("successful saves and default restores retain cleanup warnings, polish their committed changes and retry without extra polish")

        let beforeSubject = fixtureStore.shortcuts, beforeSubjectPolish = counts(fixture)
        enter(fixture, .subject, 26, "7")
        require(fixtureStore.shortcuts == beforeSubject, "subject shortcut committed early")
        fixedLayout(fixture); preview(fixture, "home-editing", directory)
        click("保存", c)
        require(fixtureStore.shortcuts[.subject]?.keyCode == 26 && hotKeys.registeredShortcuts == fixtureStore.shortcuts && beforeSubject.filter { $0.key != .subject }.allSatisfy { fixtureStore.shortcuts[$0.key] == $0.value }, "subject commit changed another feature")
        polished(fixture, since: beforeSubjectPolish, only: [.subject])
        let finalSaved = fixtureStore.shortcuts
        w.close(); fixture.showWindow(nil)
        require(!fixture.isEditing && fixture.editor.draft == finalSaved && fixture.tiles[.subject]?.shortcutButton.title == "⌃⌥7", "reopening lost the committed subject shortcut")
        controls(fixture, editing: false); fixedLayout(fixture); preview(fixture, "home-saved", directory)
        w.close()
        passed("subject edits survive reopening and all idle, recording, draft, error and warning states retain the fixed window size")
        let autoStore = PreferencesStore(storage: MemoryPreferencesStorage())
        let autoBackend = ReopenHotKeyBackend()
        let autoKeys = HotKeys(backend: autoBackend)
        _ = autoKeys.installShortcuts(autoStore.shortcuts, actions: actions)
        let auto = HomeWindowController(hotKeys: autoKeys, store: autoStore, onSave: {}, onLaunch: { _ in })
        auto.showWindow(nil)
        let autoWindow = auto.window as! ShortcutSettingsWindow
        func outsideClick() {
            let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: autoWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            _ = autoWindow.onPointerDown?(e)
        }
        enter(auto, .screenshot, 25, "9")
        let autoTile = auto.tiles[.screenshot]!
        let hoverLocation = autoTile.shortcutButton.convert(NSPoint(x: autoTile.shortcutButton.bounds.midX, y: autoTile.shortcutButton.bounds.midY), to: nil)
        let hoverEvent = NSEvent.mouseEvent(with: .mouseMoved, location: hoverLocation, modifierFlags: [], timestamp: 0,
                                           windowNumber: autoWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        autoTile.mouseMoved(with: hoverEvent)
        require(autoTile.isShortcutHovered, "cannot prepare hovered shortcut for auto-save")
        outsideClick()
        require(!auto.isEditing && autoStore.shortcuts[.screenshot]?.keyCode == 25, "Outside click did not save the draft")
        require(autoWindow.firstResponder !== autoTile.shortcutButton && !autoTile.isEditingShortcut
                && !autoTile.isShortcutHovered && !autoTile.shortcutButton.isHighlighted,
                "auto-save leaves the shortcut focus or hover color active")
        enter(auto, .pin, 28, "8")
        auto.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: autoWindow))
        require(!auto.isEditing && autoStore.shortcuts[.pin]?.keyCode == 28, "Focus loss discarded a valid draft")
        auto.beginEditing(.togglePins); fixedLayout(auto); preview(auto, "home-visibility-edit", directory)
        outsideClick(); require(!auto.isEditing, "Unchanged seventh shortcut did not exit editing")
        let previous = autoStore.shortcuts
        autoBackend.blocked.insert(KeyboardShortcut(keyCode: 29, modifiers: [.control, .option]))
        enter(auto, .togglePins, 29, "0"); outsideClick()
        require(auto.isEditing && autoStore.shortcuts == previous && auto.editor.hasIssue(.togglePins),
                "Failed auto-save lost its draft or overwrote saved keys")
        auto.cancelEditing(); auto.close()
        passed("outside clicks and focus loss save valid changes; seventh shortcut fits and failed saves retain drafts")
        require(completedGroups == 13, "Home probe skipped a verification group")
        print("Native previews: \(directory.path)")
        print("PASS: 13 Home/reopen groups; 0 failures"); fflush(stdout)
    }
}
