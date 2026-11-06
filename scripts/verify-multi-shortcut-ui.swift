// Memory preferences and a fake hotkey backend only; no system shortcut registration.
import AppKit
import Darwin

private struct MultiShortcutUIFailure: Error, CustomStringConvertible { let description: String }

@MainActor private final class MultiShortcutUIBackend: HotKeyBackend {
    private var next: UInt64 = 0
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 { 0 }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> {
        next += 1
        return .success(HotKeyToken(rawValue: next))
    }
    func unregister(_ token: HotKeyToken) -> Int32 { 0 }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> { .success([]) }
}

@main private struct MultiShortcutUIVerification {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            fputs("FAIL: multi-shortcut UI verification timed out\n", stderr)
            exit(1)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            try verifyTileLayouts()
            try verifyNativeDisplayAlignment()
            try verifyHomeEditing(output: output)
            print("PASS: multi-shortcut UI verification completed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw MultiShortcutUIFailure(description: message) }
    }

    @MainActor private static func visibleControls(_ tile: HomeFeatureTile) -> [NSView] {
        tile.shortcutControls.filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    @MainActor private static func verifyRow(_ tile: HomeFeatureTile, description: String) throws {
        tile.needsLayout = true
        tile.layoutSubtreeIfNeeded()
        let visible = visibleControls(tile)
        try require(!visible.isEmpty, "No shortcut target in \(description)")
        for control in visible {
            try require(control.frame.width > 0 && control.frame.height >= 20
                        && tile.bounds.contains(control.frame),
                        "Shortcut control overflows its tile in \(description): \(control.frame), tile=\(tile.bounds)")
            let point = CGPoint(x: control.frame.midX, y: control.frame.midY)
            let hit = tile.hitTest(tile.convert(point, to: tile.superview))
            try require(hit === control || hit?.isDescendant(of: control) == true,
                        "Shortcut or add/remove target is covered by launch action in \(description)")
        }
        for index in visible.indices {
            for other in visible.indices where other > index {
                try require(!visible[index].frame.intersects(visible[other].frame),
                            "Shortcut controls overlap in \(description)")
                try require(abs(visible[index].frame.midY - visible[other].frame.midY) < 0.01,
                            "Shortcut or edit control wrapped to another line in \(description)")
            }
        }
        for key in tile.shortcutButtons where !key.isHidden {
            try require(key.cell?.wraps == false && key.cell?.usesSingleLineMode == true,
                        "Shortcut text may wrap in \(description)")
            try require((key.font?.pointSize ?? 0) >= 11,
                        "Shortcut label was made illegibly small in \(description)")
            try require(key.toolTip?.isEmpty == false && (key.accessibilityValue() as? String)?.isEmpty == false,
                        "Compacted shortcut lost its complete tooltip/accessibility value in \(description)")
        }
    }

    @MainActor private static func verifyTileLayouts() throws {
        let original = AppLocalization.language
        defer { AppLocalization.language = original }
        let tile = HomeFeatureTile(action: .screenshot, reducedTransparency: { true })
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 240))
        host.addSubview(tile)
        let allModifiers: ShortcutModifiers = [.control, .option, .shift, .command]
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            let extreme = [KeyboardShortcut(keyCode: 90, modifiers: allModifiers).displayString,
                           KeyboardShortcut(keyCode: 71, modifiers: allModifiers).displayString]
            let navigation = [KeyboardShortcut(keyCode: 121, modifiers: allModifiers).displayString,
                              KeyboardShortcut(keyCode: 49, modifiers: allModifiers).displayString]
            let keypad = [KeyboardShortcut(keyCode: 65, modifiers: allModifiers).displayString,
                          KeyboardShortcut(keyCode: 78, modifiers: allModifiers).displayString]
            for width: CGFloat in [120, 123.2, 124.4, 140] {
                for top in [CGFloat(0), 55] {
                    tile.frame = CGRect(x: 0, y: 0, width: width, height: top == 0 ? 156 : 205)
                    tile.topInset = top
                    for shortcuts in [[], ["⌥1"], ["⌥1", "⌃⇧1"], extreme, navigation, keypad] {
                        for editing in [false, true] {
                            tile.configure(shortcuts: shortcuts, editing: editing, recordingIndex: nil,
                                           launchesEnabled: !editing, issues: [])
                            let name = "\(language.rawValue), \(width)pt, \(shortcuts.count) keys, editing=\(editing)"
                            try verifyRow(tile, description: name)
                            if !editing {
                                try require(tile.addShortcutButton.isHidden && tile.removeShortcutButtons.allSatisfy(\.isHidden),
                                            "Normal home reveals editing affordances in \(name)")
                            } else if shortcuts.count == 2 {
                                try require(tile.addShortcutButton.isHidden,
                                            "Two-slot tile still offers a third shortcut in \(name)")
                            }
                            for (index, shortcut) in shortcuts.enumerated() {
                                try require(tile.shortcutButtons[index].toolTip?.contains(shortcut) == true
                                            && (tile.shortcutButtons[index].accessibilityValue() as? String)?.contains(shortcut) == true,
                                            "Long shortcut cannot be read in full in \(name)")
                            }
                            if shortcuts.count == 1 && !editing {
                                try require(abs(tile.shortcutButton.frame.midX - tile.bounds.midX) <= 0.5,
                                            "Single shortcut no longer retains centered placement")
                            }
                        }
                    }
                    for index in [0, 1] {
                        tile.configure(shortcuts: index == 0 ? [] : ["⌥1"], editing: true, recordingIndex: index,
                                       launchesEnabled: false, issues: [])
                        try verifyRow(tile, description: "recording slot \(index) at \(width)pt")
                    }
                }
            }
        }
        AppLocalization.language = .simplifiedChinese
        tile.frame = CGRect(x: 0, y: 0, width: 124, height: 205); tile.topInset = 55
        tile.configure(shortcuts: ["⌥1", "⌃⇧1"], editing: true, recordingIndex: nil,
                       launchesEnabled: false, issues: [nil, "暂时不可用，另一组仍可使用"])
        try verifyRow(tile, description: "one unavailable binding")
        try require(tile.shortcutButtons[0].contentTintColor != .systemOrange
                    && tile.shortcutButtons[1].contentTintColor == .systemOrange,
                    "Unavailable feedback colors the working shortcut too")
        var edited: [Int] = [], removed: [Int] = [], adds = 0, launches = 0
        tile.onEditShortcut = { edited.append($0) }; tile.onRemoveShortcut = { removed.append($0) }
        tile.onAddShortcut = { adds += 1 }; tile.onLaunch = { launches += 1 }
        tile.shortcutButtons[1].performClick(nil)
        tile.removeShortcutButtons[0].performClick(nil)
        try require(edited == [1] && removed == [0] && launches == 0,
                    "Shortcut or remove action triggered its parent launch action")
        tile.configure(shortcuts: ["⌥1"], editing: true, recordingIndex: nil, launchesEnabled: false, issues: [])
        tile.addShortcutButton.performClick(nil)
        try require(adds == 1 && launches == 0, "Add shortcut action triggered a launch")
        let quit = HomeFeatureTile()
        host.addSubview(quit); quit.frame = tile.frame
        quit.configure(shortcut: "⌘Q", editing: true, launchesEnabled: true, hasError: false)
        try require(!quit.shortcutButton.isEnabled && quit.addShortcutButton.isHidden
                    && quit.removeShortcutButtons.allSatisfy(\.isHidden), "Fixed Quit binding became editable")
        quit.removeFromSuperview()
        print("PASS: 0/1/2 shortcut slots, long chords, both languages and edit/record states stay single-line, bounded and independently clickable")
    }

    @MainActor private static func verifyNativeDisplayAlignment() throws {
        let screens = NSScreen.screens
        try require(!screens.isEmpty, "Native alignment verification requires a WindowServer connection")
        for screen in screens {
            let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 220),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
            defer { window.close() }
            let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
            let targetDisplay = screen.deviceDescription[displayKey] as? NSNumber
            let actualDisplay = window.screen?.deviceDescription[displayKey] as? NSNumber
            try require(targetDisplay != nil && actualDisplay == targetDisplay
                        && window.backingScaleFactor == screen.backingScaleFactor,
                        "Hidden shortcut fixture did not acquire the requested display and backing scale")
            let tile = HomeFeatureTile(action: .screenshot, reducedTransparency: { true })
            guard let content = window.contentView else { throw MultiShortcutUIFailure(description: "Missing hidden display fixture") }
            content.addSubview(tile)
            tile.frame = CGRect(x: 15.5, y: 10, width: 123.2, height: 205); tile.topInset = 55
            tile.configure(shortcuts: ["⌃⌥⇧⌘F20", "⌃⌥⇧⌘Page Down"], editing: true, recordingIndex: nil,
                           launchesEnabled: false, issues: [])
            try verifyRow(tile, description: "native \(window.backingScaleFactor)x display")
            for control in visibleControls(tile) {
                let backing = window.convertToBacking(control.convert(control.bounds, to: nil))
                for edge in [backing.minX, backing.minY, backing.maxX, backing.maxY] {
                    try require(abs(edge - edge.rounded()) < 0.01,
                                "Shortcut control misses native pixel grid at \(window.backingScaleFactor)x: \(backing)")
                }
            }
        }
        print("PASS: shortcut and edit affordance frames remain pixel-aligned on available 1x/2x displays")
    }

    @MainActor private static func capture(_ view: NSView, to url: URL) throws {
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw MultiShortcutUIFailure(description: "Cannot allocate multi-shortcut preview")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw MultiShortcutUIFailure(description: "Cannot encode multi-shortcut preview")
        }
        try data.write(to: url, options: .atomic)
    }

    @MainActor private static func pointerEvent(on control: NSView, window: NSWindow) throws -> NSEvent {
        let point = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            throw MultiShortcutUIFailure(description: "Cannot construct isolated pointer fixture")
        }
        return event
    }

    @MainActor private static func verifyHomeEditing(output: URL) throws {
        AppLocalization.language = .simplifiedChinese
        let store = PreferencesStore(storage: MemoryPreferencesStorage())
        let hotKeys = HotKeys(backend: MultiShortcutUIBackend())
        try require(hotKeys.installBindings(store.shortcutBindings, actions: [:]).isEmpty,
                    "Fake backend could not install the Home fixture's saved shortcuts")
        var launches: [ShortcutAction] = []
        let home = HomeWindowController(hotKeys: hotKeys, store: store, onSave: {}, onLaunch: { launches.append($0) })
        defer { home.cancelEditing(); home.close() }
        guard let window = home.window as? ShortcutSettingsWindow, let content = window.contentView,
              let tile = home.tiles[.screenshot] else { throw MultiShortcutUIFailure(description: "Missing Home fixture") }
        let originalFrame = window.frame
        content.layoutSubtreeIfNeeded()
        try require(home.allTiles.count == 10, "Multi-shortcut UI replaced the original ten-pane Home")
        for item in home.allTiles { try verifyRow(item, description: "actual Home initial pane") }
        home.beginEditing(.screenshot)
        content.layoutSubtreeIfNeeded()
        try require(!tile.addShortcutButton.isHidden, "Existing single binding has no Add affordance during editing")
        let addEvent = try pointerEvent(on: tile.addShortcutButton, window: window)
        _ = window.onPointerDown?(addEvent)
        try require(home.isEditing, "Pointer-down on Add prematurely commits shortcut editing")
        tile.addShortcutButton.performClick(nil)
        try require(home.editor.recordingAction == .screenshot && home.editor.recordingIndex == 1,
                    "Add did not record the second slot")
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18) else {
            throw MultiShortcutUIFailure(description: "Cannot construct isolated key fixture")
        }
        try require(home.editor.capture(key), "Recorder ignored a valid second shortcut")
        try require(home.editor.bindingDraft[.screenshot]?.count == 2 && store.shortcutBindings[.screenshot]?.count == 1,
                    "Adding a binding overwrote the first or persisted before saving")
        try require(home.finishEditing(), "Two valid shortcuts cannot be saved")
        let saved = store.shortcutBindings[.screenshot] ?? []
        try require(saved.count == 2 && saved[0] == ShortcutAction.screenshot.defaultShortcut
                    && saved[1] == KeyboardShortcut(keyCode: 18, modifiers: [.control, .shift]),
                    "Saved Home bindings differ from the two visible shortcuts")
        try require(window.frame == originalFrame && !home.isShowingOptions,
                    "Adding a shortcut replaced or resized the original Home")
        try verifyRow(tile, description: "saved Home two-shortcut pane")
        try require(home.tiles.values.flatMap(\.shortcutButtons).filter { !$0.isHidden }
            .allSatisfy { $0.contentTintColor != .systemOrange },
                    "Available saved shortcuts show an unavailable warning")
        try capture(content, to: output.appendingPathComponent("home-two-shortcuts.png"))

        home.beginEditing(.screenshot)
        content.layoutSubtreeIfNeeded()
        try capture(content, to: output.appendingPathComponent("home-two-shortcuts-editing.png"))
        let selectedKey = tile.shortcutButtons[0]
        let beforeHover = selectedKey.frame
        let hoverPoint = selectedKey.convert(CGPoint(x: selectedKey.bounds.midX, y: selectedKey.bounds.midY), to: nil)
        let hover = NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        tile.mouseMoved(with: hover)
        try require(selectedKey.focusRingType == .none && selectedKey.layer?.borderWidth == 1
                    && selectedKey.layer?.cornerRadius == 6 && selectedKey.frame == beforeHover,
                    "Focused shortcut and hover do not share one stable rounded surface")
        try require((selectedKey.cell as? NSButtonCell)?.highlightsBy.isEmpty == true,
                    "Native highlight adds a second shortcut background")
        try capture(content, to: output.appendingPathComponent("home-shortcut-focus-hover.png"))
        tile.resetInteraction()

        _ = window.onPointerDown?(try pointerEvent(on: tile.removeShortcutButtons[0], window: window))
        try require(home.isEditing, "Pointer-down on Remove prematurely commits shortcut editing")
        tile.removeShortcutButtons[0].performClick(nil)
        try require(home.editor.bindingDraft[.screenshot] == [saved[1]], "Removing the first slot also removes or changes its alternate")
        try require(home.finishEditing() && store.shortcutBindings[.screenshot] == [saved[1]], "Single remaining alternate did not persist")
        home.beginEditing(.screenshot)
        tile.removeShortcutButtons[0].performClick(nil)
        try require(home.finishEditing() && store.shortcutBindings[.screenshot]?.isEmpty == true,
                    "Removing the last binding restores a default instead of leaving it unassigned")
        try require(tile.launchButton.isEnabled, "Unassigned shortcut disables the clickable feature")
        tile.launchButton.performClick(nil)
        try require(launches == [.screenshot], "Feature cannot be clicked with no hotkey")
        home.beginEditing(.screenshot)
        try require(home.editor.capture(key), "Empty binding cannot be recorded again")
        home.cancelEditing()
        try require(store.shortcutBindings[.screenshot]?.isEmpty == true, "Cancelling restores an uncommitted key")
        print("PASS: original Home adds, edits, removes and saves independent slots; cancelling preserves settings and unassigned features remain clickable")
    }
}
