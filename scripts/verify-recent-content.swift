// Synthetic content and an isolated pasteboard only; no clipboard history is persisted.
import AppKit
import Darwin

private struct Failure: Error { let message: String }
@MainActor private final class HistoryTestHotKeys: HotKeyBackend {
    func installHandler(_ callback: @escaping (UInt32) -> Void) -> Int32 { 0 }
    func register(_ shortcut: KeyboardShortcut, eventID: UInt32) -> Result<HotKeyToken, HotKeyBackendError> { .success(HotKeyToken(rawValue: UInt64(eventID))) }
    func unregister(_ token: HotKeyToken) -> Int32 { 0 }
    func symbolicShortcuts() -> Result<Set<KeyboardShortcut>, HotKeyBackendError> { .success([]) }
}

@main private struct VerifyRecentContent {
    @MainActor static func main() {
        // macOS's crash dialog can relaunch this command-line probe without its output
        // argument. Exit before creating any windows instead of crashing a second time.
        guard CommandLine.arguments.count == 2 else {
            fputs("This is a command-line test. Run scripts/verify-recent-content.sh from Terminal.\n", stderr)
            return
        }
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        _ = NSApplication.shared
        AppLocalization.language = .simplifiedChinese
        try preferences()
        try retention()
        try dates()
        try clipboard()
        try themesAndWindows()
        try englishHistory()
        try filteringAndScrollers()
        print("PASS: recent content, clipboard lifecycle, preference migration and appearance verification completed")
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    @MainActor private static func verifyCardFooter(_ card: NSView) throws {
        guard let metadata = card.subviews.compactMap({ $0 as? NSTextField }).first(where: {
            $0.identifier?.rawValue.hasPrefix("history.metadata.") == true
        }), let copy = card.subviews.compactMap({ $0 as? NSButton }).first(where: {
            $0.action == NSSelectorFromString("copyItem:")
        }), let remove = card.subviews.compactMap({ $0 as? NSButton }).first(where: {
            $0.action == NSSelectorFromString("removeItem:")
        }) else { throw Failure(message: "Card footer is missing metadata or actions") }
        try require(abs(metadata.frame.midY - copy.frame.midY) < 0.5
                    && abs(copy.frame.midY - remove.frame.midY) < 0.5,
                    "Type/time, copy and delete must share the same footer row")
        try require(metadata.intrinsicContentSize.width <= metadata.bounds.width
                    && metadata.frame.maxX + 8 <= copy.frame.minX
                    && !copy.frame.intersects(remove.frame),
                    "Complete timestamp is clipped or overlaps footer actions")
    }
    @MainActor private static func verifyAmbientLayout(_ window: NSWindow) throws {
        try require(window.titlebarAppearsTransparent && window.styleMask.contains(.fullSizeContentView),
                    "History glow must extend beneath its transparent title bar")
        guard let content = window.contentView else { throw Failure(message: "History content is missing") }
        content.superview?.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let safe = window.contentLayoutRect
        try require(!safe.isEmpty && safe.height < content.bounds.height,
                    "History must reserve the native title bar's content-layout inset")
        for view in content.subviews where !view.isHidden && !view.frame.isEmpty {
            let frame = view.convert(view.bounds, to: nil)
            try require(safe.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                        "History content overlaps the title bar or escapes native layout bounds: \(view)")
        }
    }
    @MainActor private static func verifyInfoBubble(_ button: NSButton, explanation: String, snapshot: String) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func visibleBubble() -> NSView? {
            NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
                .first { $0.identifier?.rawValue == "history.info-popover" }
        }
        button.window!.makeKeyAndOrderFront(nil)
        button.updateTrackingAreas()
        try require(button.toolTip == nil && button.accessibilityLabel() == explanation && button.accessibilityHelp() == explanation,
                    "Info must use one custom bubble and retain its accessible explanation")
        try require(button.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.inVisibleRect) },
                    "Info button has no real hover tracking area")
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: button.window!.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let leave = NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: button.window!.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        // Exercise the same event handlers used by AppKit tracking, without clicking the info button.
        button.mouseEntered(with: enter)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let bubble = visibleBubble(), let label = descendants(bubble).compactMap({ $0 as? NSTextField }).first else {
            throw Failure(message: "Hover did not immediately display the explanation")
        }
        try require(label.stringValue == explanation, "Hover explanation is not localized")
        try require(bubble.bounds.width == label.bounds.width + 20 && bubble.bounds.height == label.bounds.height + 14
                    && bubble.bounds.width <= 384,
                    "Info bubble has oversized fixed padding or dimensions")
        let textSize = (explanation as NSString).boundingRect(with: CGSize(width: label.bounds.width - 4, height: 1000),
            options: [.usesLineFragmentOrigin], attributes: [.font: label.font!])
        try require(textSize.height <= label.bounds.height && label.bounds.height - textSize.height <= 5,
                    "Info explanation is clipped or retains oversized fixed height")
        let rendered = bubble.window!.contentView!
        let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds)!
        rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(snapshot + ".png"))
        print("INFO: \(snapshot) content size \(Int(bubble.bounds.width))×\(Int(bubble.bounds.height))")
        button.mouseExited(with: leave)
        try require(visibleBubble() == nil, "Moving off info did not close the bubble")
        button.performClick(nil)
        try require(visibleBubble() != nil, "Clicking info no longer opens the bubble")
        button.mouseExited(with: leave)
        try require(button.window!.makeFirstResponder(button) && button.window!.firstResponder === button,
                    "Info cannot receive keyboard focus")
        _ = button.accessibilityPerformPress()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try require(visibleBubble() != nil, "Accessible info press no longer opens the bubble")
        button.mouseExited(with: leave)
    }
    @MainActor private static func preferences() throws {
        let old = Data("{\"version\":1,\"annotations\":{},\"shortcuts\":{},\"automaticClipboard\":false,\"recentLimit\":50}".utf8)
        let storage = MemoryPreferencesStorage(data: old)
        let store = PreferencesStore(storage: storage)
        try require(store.appearancePreference == .system, "Existing settings must keep system appearance")
        store.setAppearancePreference(.dark)
        let restored = PreferencesStore(storage: storage)
        try require(restored.appearancePreference == .dark, "User appearance did not persist")
        let session = RecentContentStore()
        try require(session.items.isEmpty && session.textLimit == 100 && session.imageLimit == 20 && session.videoLimit == 5,
                    "A new session inherited content or incorrect category limits")
        let keys = Set((try JSONSerialization.jsonObject(with: storage.data!) as! [String: Any]).keys)
        try require(keys == ["version", "annotations", "shortcuts", "appearance"], "Removed controls or content were persisted")
        print("PASS: existing settings migrate; only settings persist; new sessions have no history")
    }
    @MainActor private static func retention() throws {
        let store = RecentContentStore(limit: 3)
        for value in ["A", "B", "C", "D"] { store.addText(value) }
        try require(store.items.map(\.title) == ["D", "C", "B"], "Count eviction did not remove the oldest content")
        let ids = store.items.map(\.id)
        store.addText("B")
        try require(store.items.map(\.id) == ids, "Recopying changed history or duplicated content")
        store.remove(ids[1]); try require(store.items.map(\.title) == ["D", "B"], "Delete removed wrong record")
        store.setLimit(1); try require(store.items.map(\.title) == ["D"], "Changing count did not evict old content")
        store.clear(); try require(store.items.isEmpty && store.memoryUsage == 0, "Clear retained content")
        let small = RecentContentStore(memoryLimit: 12)
        small.addText("12345678"); small.addText("abcdefgh")
        try require(small.items.map(\.title) == ["abcdefgh"] && small.memoryUsage <= 12, "Memory budget was exceeded")
        small.addText("this is too large")
        try require(small.items.map(\.title) == ["abcdefgh"] && small.notice != nil, "Oversized content erased useful history")
        let mixed = RecentContentStore()
        mixed.addText("keep first"); mixed.addImage(fixture(), pixelScale: 2); mixed.addText("keep second")
        let textIDs = mixed.items.filter(RecentContentStore.Filter.text.includes).map(\.id)
        var changes = 0
        mixed.onChange = { changes += 1 }
        mixed.clear(.images)
        try require(mixed.items.map(\.id) == textIDs && changes == 1
                    && mixed.memoryUsage == mixed.items.reduce(0, { $0 + $1.memoryCost }),
                    "Image clear changed other records, memory accounting, or emitted repeated updates")
        mixed.addImage(fixture(), pixelScale: 2)
        let imageID = mixed.items[0].id
        mixed.clear(.text)
        try require(mixed.items.map(\.id) == [imageID], "Text clear removed the remaining image")
        mixed.clear()
        try require(mixed.items.isEmpty && mixed.memoryUsage == 0, "All clear did not release filtered content")
        print("PASS: count/memory eviction, deduplication, deletion, clear and oversized-content handling")
    }
    private static func dates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        for (seconds, expected) in [(0.0, "刚刚"), (59, "刚刚"), (60, "1 分钟前"), (3599, "59 分钟前"), (3600, "1 小时前"), (86399, "23 小时前")] {
            try require(RecentContentPresentation.timeLabel(now.addingTimeInterval(-seconds), now: now, calendar: calendar) == expected,
                        "Relative time boundary failed at \(seconds)")
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 40))!
        try require(RecentContentPresentation.timeLabel(yesterday, now: now, calendar: calendar) == "11月3日 12:00", "Same-year date should omit year")
        try require(RecentContentPresentation.timeLabel(lastYear, now: now, calendar: calendar) == "2025/12/31 23:40", "Cross-year date should show year")
        let midnight = calendar.startOfDay(for: now)
        try require(RecentContentPresentation.groupTitle(midnight, now: now, calendar: calendar) == "今天", "Today boundary is wrong")
        try require(RecentContentPresentation.groupTitle(midnight.addingTimeInterval(-1), now: now, calendar: calendar) == "昨天", "Yesterday boundary is wrong")
        try require(RecentContentPresentation.groupTitle(calendar.date(byAdding: .day, value: -2, to: now)!, now: now, calendar: calendar) == "11月2日", "Older groups must use a concrete same-year date")
        try require(RecentContentPresentation.groupTitle(lastYear, now: now, calendar: calendar) == "2025年12月31日", "Older groups lost their cross-year date")
        var daylightCalendar = calendar; daylightCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let afterFallback = daylightCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 0, minute: 30))!
        let longYesterday = daylightCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 10))!
        try require(afterFallback.timeIntervalSince(longYesterday) > 86400
                    && RecentContentPresentation.groupTitle(longYesterday, now: afterFallback, calendar: daylightCalendar) == "昨天",
                    "Yesterday grouping used elapsed hours instead of a local calendar day")
        try require(RecentContentPresentation.timeLabel(now.addingTimeInterval(10), now: now, calendar: calendar) == "刚刚", "Clock rollback produced a negative age")
        print("PASS: relative-time thresholds, local midnight grouping and cross-year labels")
    }
    private static func fixture() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 360, height: 200))
        return context.makeImage()!
    }
    @MainActor private static func clipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let store = RecentContentStore()
        let monitor = RecentClipboardMonitor(store: store, pasteboard: board)
        defer { monitor.setEnabled(false) }
        func copy(_ value: String) {
            board.clearContents(); board.setString(value, forType: .string)
        }
        copy("current clipboard\nwith line breaks")
        monitor.poll(); try require(store.items.isEmpty, "Disabled monitor read clipboard")
        monitor.setEnabled(true)
        try require(store.items.first?.title == "current clipboard\nwith line breaks", "Enabling did not import the current clipboard")
        monitor.poll(); try require(store.items.count == 1, "Unchanged clipboard was duplicated")
        store.clear(); monitor.poll(); try require(store.items.isEmpty, "Clear re-imported an unchanged clipboard")
        copy("copy immediately before clear"); store.clear(); monitor.poll()
        try require(store.items.isEmpty, "Clear raced with the polling timer and restored pending clipboard content")
        copy("later copy"); monitor.poll(); try require(store.items.count == 1, "New content was not imported")
        monitor.setEnabled(false); copy("copied while off"); monitor.poll()
        try require(store.items.count == 1, "Monitor kept collecting while off")
        monitor.setEnabled(true); try require(store.items.first?.title == "copied while off", "Re-enabling missed current content")
        copy("concealed fixture")
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        monitor.poll(); try require(store.items.count == 2, "Concealed clipboard was retained")
        let image = fixture()
        store.clear(); store.addImage(image, pixelScale: 2)
        try ImageToolsUI.copyPNG(image, pixelScale: 2, to: board); monitor.poll()
        try require(store.items.count == 1, "Automatic polling duplicated Patch's own capture")
        guard case .image(let data, let size, let scale) = store.items[0].content,
              let restored = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(message: "Image record cannot be decoded")
        }
        try require(size == CGSize(width: 400, height: 240) && scale == 2 && restored.width == 400 && restored.height == 240,
                    "Stored image lost export pixels or screen scale")
        let tools = ImageToolsCoordinator()
        tools.pinImage(restored, pixelScale: scale, recordsHistory: false)
        defer { tools.closeAll() }
        let pin = NSApp.windows.first { $0.title == "Patch · 图片贴图" }!
        guard let content = pin.contentView,
              let unusedScroll = content.subviews.compactMap({ $0 as? NSScrollView }).first else {
            throw Failure(message: "History pin has no native image presentation")
        }
        // Transparent fixture margins have no border; opaque images reserve one point per edge.
        let frameWidth: CGFloat = ImageToolsUI.hasTransparentPixels(restored) ? 0 : 2
        let expected = CGSize(width: 200 + frameWidth, height: 120 + frameWidth)
        try require(content.bounds.width >= expected.width && content.bounds.width <= expected.width + 1
                    && content.bounds.height >= expected.height && content.bounds.height <= expected.height + 1
                    && pin.frame == pin.frame.integral && unusedScroll.isHidden && unusedScroll.documentView == nil,
                    "History pin changed Retina size or retained a scrolling image viewport: \(content.bounds)")
        store.clear(); try require(pin.isVisible, "Clearing history closed a desktop pin")
        monitor.poll(); try require(store.items.isEmpty, "Clearing history restored the current clipboard unexpectedly")
        store.addImage(image, pixelScale: 2)
        copy("pending text survives image clear")
        store.clear(.images); monitor.poll()
        try require(store.items.map(\.title) == ["pending text survives image clear"],
                    "Image clear discarded pending clipboard text or restored removed images")
        try ImageToolsUI.copyPNG(image, pixelScale: 2, to: board)
        store.clear(.text); monitor.poll()
        try require(store.items.count == 1 && RecentContentStore.Filter.images.includes(store.items[0]),
                    "Text clear discarded a pending clipboard image")
        store.clear(.images); monitor.poll()
        try require(store.items.isEmpty, "Filtered clear re-imported the unchanged clipboard")
        copy("new copy after filtered clear"); monitor.poll()
        try require(store.items.map(\.title) == ["new copy after filtered clear"],
                    "Filtered clear stopped subsequent clipboard collection")
        store.clear()
        store.addText("oldest text must survive")
        for scale in 1...19 { store.addImage(image, pixelScale: CGFloat(scale)) }
        try ImageToolsUI.copyPNG(image, pixelScale: 20, to: board)
        store.clear(.images); monitor.poll()
        try require(store.items.map(\.title) == ["oldest text must survive"],
                    "Clearing a full history evicted another category before removing pending images")
        store.clear()
        store.addText("oldest retained text")
        for scale in 1...19 { store.addImage(image, pixelScale: CGFloat(scale)) }
        copy("new pending text")
        store.clear(.images); monitor.poll()
        try require(store.items.map(\.title) == ["new pending text", "oldest retained text"],
                    "Pending text was imported before filtered clear released history capacity")
        store.clear()
        store.addImage(image, pixelScale: 2)
        let oldestImageID = store.items[0].id
        for index in 1...19 { store.addText("text \(index)") }
        copy("new pending text to discard")
        store.clear(.text); monitor.poll()
        try require(store.items.map(\.id) == [oldestImageID],
                    "Clearing a full text tab evicted the oldest image")
        print("PASS: startup/current clipboard, running/off transitions, concealed filtering, own-copy dedup, full pixels and original-size pinning")
        print("PASS: scoped clear preserves other types and pending copies, including full 20-item histories")
    }
    @MainActor private static func themesAndWindows() throws {
        var fixtureDate = Date().addingTimeInterval(-172800)
        let store = RecentContentStore(now: { fixtureDate })
        store.addText("前天的笔记\n记录一下新的设计想法。")
        fixtureDate = Date()
        store.addText("会议记录\n明天下午讨论界面设计。\n这是一条可重新贴出的文字记录。")
        store.addImage(fixture(), pixelScale: 2)
        var pinnedID: UUID?
        var displayDate = Date()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = RecentClipboardMonitor(store: store, pasteboard: board)
        monitor.setEnabled(true)
        defer { monitor.setEnabled(false) }
        let history = RecentContentWindowController(store: store, now: { displayDate }, pasteboard: board,
            onCopy: { monitor.acknowledgeCopy() }) { pinnedID = $0.id }
        store.onChange = { [weak history] in history?.reload() }
        let preferences = PreferencesStore(storage: MemoryPreferencesStorage())
        let home = HomeWindowController(hotKeys: HotKeys(backend: HistoryTestHotKeys()), store: preferences,
                                        onSave: {}, onLaunch: { _ in })
        defer { history.close(); home.close(); NSApp.appearance = nil }
        for choice in [AppAppearancePreference.light, .dark] {
            NSApp.appearance = choice.appearance
            for controller in [history as NSWindowController, home] { controller.showWindow(nil) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            for controller in [history as NSWindowController, home] {
                controller.window?.contentView?.needsLayout = true
                controller.window?.contentView?.layoutSubtreeIfNeeded()
            }
            try verifyAmbientLayout(history.window!)
            let toolbar = SelectionToolbar()
            let ordinary = SelectionButton("复制", symbol: "doc.on.doc") {}
            let selected = SelectionButton("完成", symbol: "checkmark") {}; selected.isPrimaryAction = true
            toolbar.rows = [[ordinary, selected]]
            toolbar.frame.size = toolbar.arrange(maxWidth: 400)
            let toolbarWindow = NSWindow(contentRect: toolbar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            toolbarWindow.isReleasedWhenClosed = false; toolbarWindow.contentView = toolbar
            toolbarWindow.orderFrontRegardless()
            defer { toolbarWindow.close() }
            toolbar.layoutSubtreeIfNeeded()
            try require(toolbar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (choice == .dark ? .darkAqua : .aqua),
                        "Toolbar forces a different appearance from the app")
            let appearance = choice.appearance!
            var foreground: NSColor!, background: NSColor!
            appearance.performAsCurrentDrawingAppearance {
                foreground = ToolbarPalette.ink.usingColorSpace(.sRGB)
                background = ToolbarPalette.surface.usingColorSpace(.sRGB)
            }
            func luminance(_ color: NSColor) -> CGFloat {
                let values = [color.redComponent, color.greenComponent, color.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
            }
            let first = luminance(foreground), second = luminance(background)
            try require((max(first, second) + 0.05) / (min(first, second) + 0.05) >= 4.5, "Toolbar text contrast is too low")
            if let bitmap = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) {
                toolbar.cacheDisplay(in: toolbar.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("toolbar-\(choice.rawValue).png"))
            }
            for (name, controller) in [("history", history as NSWindowController), ("home", home)] {
                let content = controller.window!.contentView!
                try require(content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (choice == .dark ? .darkAqua : .aqua), "Window ignores app appearance")
                let rendered = content.superview ?? content
                guard let bitmap = rendered.bitmapImageRepForCachingDisplay(in: rendered.bounds) else { throw Failure(message: "Cannot render window") }
                appearance.performAsCurrentDrawingAppearance {
                    rendered.cacheDisplay(in: rendered.bounds, to: bitmap)
                }
                let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name)-\(choice.rawValue).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let targetID = store.items[0].id
        let rowButtons = descendants(history.window!.contentView!).compactMap { $0 as? NSButton }
            .filter { $0.identifier?.rawValue == targetID.uuidString }
        try require(rowButtons.count == 3, "History row must expose separate pin, copy and delete targets")
        let beforeCopy = store.items.map(\.id)
        let copyButton = rowButtons.first { $0.toolTip == "复制这条记录" }!
        copyButton.performClick(nil)
        let copiedImage = ImageToolsUI.clipboardImage(from: board)
        try require(copiedImage?.image.width == 400 && copiedImage?.image.height == 240 && copiedImage?.pixelScale == 2,
                    "Direct image copy lost full resolution or Retina scale")
        monitor.poll()
        try require(store.items.map(\.id) == beforeCopy && pinnedID == nil && copyButton.toolTip == "已复制",
                    "Copy pinned, reordered, duplicated history, or omitted success feedback")
        let textItem = store.items.first { if case .text = $0.content { return true }; return false }!
        let textCopy = descendants(history.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == textItem.id.uuidString && $0.toolTip == "复制这条记录" }!
        textCopy.performClick(nil)
        guard case .text(let originalText) = textItem.content else { throw Failure(message: "Missing text fixture") }
        try require(board.string(forType: .string) == originalText && board.data(forType: .png) == nil,
                    "Direct text copy lost original text or retained stale image data")
        monitor.poll()
        try require(store.items.map(\.id) == beforeCopy && pinnedID == nil, "Text copy modified history or pinned content")
        store.addImage(fixture(), pixelScale: nil)
        let unknownScaleIDs = store.items.map(\.id)
        let unknownScaleCopy = descendants(history.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == unknownScaleIDs[0].uuidString && $0.toolTip == "复制这条记录" }!
        unknownScaleCopy.performClick(nil); monitor.poll()
        try require(store.items.map(\.id) == unknownScaleIDs, "Copying an image with unknown scale duplicated history")
        store.remove(unknownScaleIDs[0])
        rowButtons.first { $0.toolTip == "贴出这条记录" }?.performClick(nil)
        try require(pinnedID == targetID, "History row did not pin its selected item")
        rowButtons.first { $0.toolTip == "删除这条记录" }?.performClick(nil)
        try require(!store.items.contains { $0.id == targetID }, "Delete button did not remove its selected item")
        let labels = descendants(history.window!.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try require(labels.contains("今天") && labels.contains(RecentContentPresentation.groupTitle(store.items.last!.date, now: displayDate)), "History must group local days without a separate empty section")
        try require(labels.contains("共 2 条") && !labels.contains { $0.contains("退出后") }, "Chinese header should show only its count")
        let info = descendants(history.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "history.info" }!
        try verifyInfoBubble(info, explanation: "最多保留 100 条文字、20 张图片和 5 个视频。\n\n内容较大时，实际保留的数量可能会少一些。\n\n退出 Patch 后，记录会清空，视频原文件不会被删除。", snapshot: "info-hover-chinese")

        displayDate = Calendar.current.date(byAdding: .day, value: 1, to: displayDate)!
        _ = history.perform(NSSelectorFromString("timeContextChanged"))
        let tomorrowLabels = descendants(history.window!.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try require(!tomorrowLabels.contains("今天") && tomorrowLabels.contains("昨天"), "Open history did not regroup when local midnight passed")
        displayDate = Date(); history.reload()
        func cards() -> [NSView] {
            descendants(history.window!.contentView!).filter { $0.identifier?.rawValue.hasPrefix("history.card.") == true }
        }
        // Add records to verify a dense two-column default and three columns after widening.
        store.addText("another item"); store.addText("last item"); history.reload()
        history.window!.contentView!.layoutSubtreeIfNeeded()
        let defaultCards = cards()
        try require(defaultCards.count == 4 && abs(defaultCards[0].frame.minY - defaultCards[1].frame.minY) < 1,
                    "Default history cards do not share a two-column row")
        try require(defaultCards[0].frame.width > 230, "History preview is too small at default width")
        for card in defaultCards { try verifyCardFooter(card) }
        history.window!.setContentSize(CGSize(width: 880, height: 560))
        history.window!.contentView!.layoutSubtreeIfNeeded()
        let wideCards = cards()
        try require(abs(wideCards[0].frame.minY - wideCards[2].frame.minY) < 1, "Wide history must use three columns")
        history.window!.setContentSize(CGSize(width: 460, height: 340))
        history.window!.contentView!.layoutSubtreeIfNeeded()
        try require(Set(cards().map { $0.frame.minX }).count == 1,
                    "Narrow history must use one column for complete footer metadata")
        for card in cards() { try verifyCardFooter(card) }
        let clear = descendants(history.window!.contentView!).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "history.clear" }!
        clear.performClick(nil)
        try require(store.items.isEmpty, "Clear-all button left records behind")
        try require(!descendants(history.window!.contentView!).contains { $0.identifier?.rawValue.hasPrefix("history.group.") == true },
                    "Empty history displays empty date groups")
        store.clear(); store.clear(); store.addText("after clearing"); history.reload()
        NSApp.appearance = nil
        try require(NSApp.appearance == nil, "System appearance mode was not restored")
        print("PASS: card pin/delete/clear, responsive columns, midnight regrouping, light/dark/system rendering and toolbar contrast")
    }
    @MainActor private static func englishHistory() throws {
        AppLocalization.language = .english
        defer { AppLocalization.language = .simplifiedChinese; NSApp.appearance = nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        for (seconds, expected) in [(0.0, "Just now"), (60, "1 minute ago"), (120, "2 minutes ago"), (3600, "1 hour ago"), (7200, "2 hours ago")] {
            try require(RecentContentPresentation.timeLabel(now.addingTimeInterval(-seconds), now: now, calendar: calendar) == expected,
                        "English relative time or plural failed at \(seconds)")
        }
        let old = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 40))!
        try require(RecentContentPresentation.timeLabel(old, now: now, calendar: calendar) == "2025-12-31 23:40", "English cross-year time lost its year")
        var captureDate = old
        let store = RecentContentStore(now: { captureDate })
        store.addImage(fixture(), pixelScale: 2)
        captureDate = now.addingTimeInterval(-120)
        let rawText = "会议记录 / Meeting notes\nOriginal copied text stays unchanged."
        store.addText(rawText)
        let history = RecentContentWindowController(store: store, now: { now }) { _ in }
        store.onChange = { [weak history] in history?.reload() }
        defer { history.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        history.window!.setContentSize(CGSize(width: 460, height: 540))
        for choice in [AppAppearancePreference.light, .dark] {
            NSApp.appearance = choice.appearance; history.showWindow(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let content = history.window!.contentView!
            content.layoutSubtreeIfNeeded()
            let labels = descendants(content).compactMap { $0 as? NSTextField }
            try require(history.window!.title == "Patch · Clipboard History", "English history title was not localized")
            try require(labels.contains { $0.stringValue == "Today" } && labels.contains { $0.stringValue == "Dec 31, 2025" }, "English labels broke concrete-date grouping")
            let count = labels.first { $0.identifier?.rawValue == "history.count" }!
            try require(count.stringValue == "2 items" && count.fittingSize.width <= count.bounds.width,
                        "English count overflows the narrow toolbar")
            let buttons = descendants(content).compactMap { $0 as? NSButton }
            let clear = buttons.first { $0.identifier?.rawValue == "history.clear" }!
            try require(clear.title == "Clear" && clear.fittingSize.width <= clear.bounds.width, "English clear button is clipped")
            let info = buttons.first { $0.identifier?.rawValue == "history.info" }!
            try verifyInfoBubble(info, explanation: "Keeps up to 100 text clips, 20 images and 5 videos.\n\nLarger items may reduce the number of clips kept.\n\nQuitting Patch clears these records. Your original video files stay where they are.", snapshot: "info-hover-english-\(choice.rawValue)")
            try require(info.frame.maxX < clear.frame.minX && count.frame.maxX < info.frame.minX,
                        "Count, info and clear controls overlap in the narrow window")
            try require(!labels.contains { $0.stringValue.contains("quit") }, "The exit explanation should not remain visible as a header line")

            let cards = descendants(content).filter { $0.identifier?.rawValue.hasPrefix("history.card.") == true }
            for item in store.items {
                let caption = "\(item.kindTitle) · \(RecentContentPresentation.timeLabel(item.date, now: now))"
                guard let card = cards.first(where: { $0.identifier?.rawValue == "history.card.\(item.id.uuidString)" }),
                      let metadata = card.subviews.compactMap({ $0 as? NSTextField }).first(where: {
                          $0.identifier?.rawValue == "history.metadata.\(item.id.uuidString)"
                      }) else { throw Failure(message: "English card is missing its metadata label") }
                try require(metadata.stringValue == caption, "English card shortened its complete type/time caption")
                try verifyCardFooter(card)
            }
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw Failure(message: "Cannot render English history") }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("history-english-\(choice.rawValue).png"))
        }
        guard case .text(let retained) = store.items[0].content else { throw Failure(message: "English history lost text") }
        try require(retained == rawText, "Language switching translated user clipboard content")
        store.remove(store.items[1].id)
        let one = descendants(history.window!.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "history.count" }!
        try require(one.stringValue == "1 item", "English item count has incorrect singular")
        print("PASS: English history, singular/plural time and counts, unchanged user text and narrow-window layout")
    }

    @MainActor private static func filteringAndScrollers() throws {
        let calendar = Calendar.current
        var current = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        var captured = current
        let store = RecentContentStore(now: { captured })
        for day in [0, 2, 1] {
            captured = calendar.date(byAdding: .day, value: -day, to: current)!
            for index in 0..<3 { store.addText("\(day)-\(index): copied text") }
            store.addImage(fixture(), pixelScale: CGFloat(day + 1))
        }
        let initialIDs = store.items.map(\.id), initialMemory = store.memoryUsage
        var pinned: UUID?
        let history = RecentContentWindowController(store: store, now: { current }) { pinned = $0.id }
        store.onChange = { [weak history] in history?.reload() }
        defer { history.close(); AppLocalization.language = .simplifiedChinese; NSApp.appearance = nil }
        history.showWindow(nil)
        let content = history.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let filter = descendants(content).compactMap { $0 as? NSSegmentedControl }.first!
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
        func cards() -> [NSView] { descendants(content).filter { $0.identifier?.rawValue.hasPrefix("history.card.") == true } }
        func groupLabels() -> [String] {
            descendants(content).compactMap { $0 as? NSTextField }
                .filter { $0.identifier?.rawValue.hasPrefix("history.group.") == true }.map(\.stringValue)
        }
        func choose(_ segment: Int) {
            filter.selectedSegment = segment; filter.sendAction(filter.action, to: filter.target)
            content.layoutSubtreeIfNeeded()
        }
        try require(filter.selectedSegment == 0 && cards().count == 12, "History must initially show all content")
        try require(groupLabels() == ["今天", "昨天", "11月2日"], "Calendar groups are not sorted newest first")
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language; history.reload()
            let expected = language == .english ? ["All", "Image", "Text", "Video"] : ["全部", "图片", "文本", "视频"]
            try require((0..<4).map { filter.label(forSegment: $0)! } == expected, "Type filters are not localized")
            for width: CGFloat in [460, 461, 600, 880, 881] {
                history.window!.setContentSize(CGSize(width: width, height: 420))
                for style in [NSScroller.Style.overlay, .legacy, .overlay] {
                    scroll.scrollerStyle = style
                    // Invoke our notification handler without letting AppKit reset
                    // the test's explicit style to this machine's preference.
                    _ = history.perform(NSSelectorFromString("scrollerStyleChanged"))
                    content.layoutSubtreeIfNeeded(); scroll.flashScrollers()
                    let count = descendants(content).first { $0.identifier?.rawValue == "history.count" }!
                    let clear = descendants(content).first { $0.identifier?.rawValue == "history.clear" }!
                    try require(abs(filter.frame.midY - clear.frame.midY) < 2 && count.frame.maxY < scroll.frame.minY,
                                "History header is misaligned or overlaps the records")
                    try require(filter.frame.maxX + 8 <= count.frame.minX || count.frame.minY >= filter.frame.maxY + 4,
                                "Narrow history header overlaps filter and count")
                    let allCards = cards(), clip = scroll.contentView
                    let cardFrames = allCards.map { $0.convert($0.bounds, to: content) }
                    let leftMargin = cardFrames.map(\.minX).min()!
                    let rightMargin = content.bounds.width - cardFrames.map(\.maxX).max()!
                    try require(abs(leftMargin - rightMargin) < 0.01 && (24...32).contains(leftMargin),
                                "\(language)/\(style)/\(width): unequal card margins \(leftMargin)/\(rightMargin)")
                    try require(width > 461 || allCards.allSatisfy { $0.frame.width >= 400 },
                                "Symmetric margins made narrow cards unreadably small")
                    let rightmost = allCards.map { $0.convert($0.bounds, to: scroll).maxX }.max()!
                    let scroller = scroll.verticalScroller!
                    try require(scroll.scrollerStyle == style && scroller.scrollerStyle == style,
                                "The requested native scroller style was not applied")
                    let trackStart = scroller.convert(scroller.bounds, to: scroll).minX
                    try require(rightmost <= trackStart - 6 && !scroll.hasHorizontalScroller,
                                "\(language)/\(style)/\(width): cards overlap the scrollbar track")
                    let uniqueColumns = Set(allCards.prefix(3).map { $0.frame.minX }).count
                    try require(uniqueColumns == (width >= 880 ? 3 : width >= 600 ? 2 : 1), "Dedicated scroller space broke responsive columns")
                    try require(filter.frame.maxX <= content.bounds.width - 18 && filter.frame.maxY < scroll.frame.minY,
                                "Narrow filter header is clipped or overlaps records")
                    for card in allCards {
                        try verifyCardFooter(card)
                        let remove = card.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == L("删除这条记录") }!
                        try require(remove.convert(remove.bounds, to: scroll).maxX < trackStart,
                                    "A delete target sits under the scroller")
                    }
                    if language == .simplifiedChinese {
                        print("INFO: history width=\(Int(width)), style=\(style == .overlay ? "overlay" : "legacy"), margins=\(leftMargin)/\(rightMargin), card=\(allCards[0].frame.width), scroller clearance=\(trackStart - rightmost)")
                    }
                    if (language == .simplifiedChinese && width == 600 || language == .english && width == 460),
                       style == .legacy {
                        scroll.autohidesScrollers = false
                        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                        content.displayIfNeeded()
                        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])!.write(to:
                            URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("history-balanced-\(language.rawValue)-legacy.png"))
                        scroll.autohidesScrollers = true
                    }
                    clip.scroll(to: CGPoint(x: 0, y: max(0, scroll.documentView!.bounds.height - clip.bounds.height)))
                    scroll.reflectScrolledClipView(clip)
                    choose(1)
                    try require(cards().count == 3 && clip.bounds.minY == 0, "Image filtering did not reset scroll position")
                    let countLabel = descendants(content).compactMap { $0 as? NSTextField }
                        .first { $0.identifier?.rawValue == "history.count" }!
                    try require(countLabel.stringValue == LF("共 %d 条", 3), "Image count does not follow the active tab")
                    choose(2)
                    try require(cards().count == 9 && groupLabels().count == 3, "Text filtering removed or duplicated date groups")
                    try require(countLabel.stringValue == LF("共 %d 条", 9), "Text count does not follow the active tab")
                    choose(0)
                }
            }
        }
        try require(store.items.map(\.id) == initialIDs && store.memoryUsage == initialMemory && store.limit == 125,
                    "Filtering changed the original order, memory budget or retention")
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try require(content.needsLayout, "System scroller-style notification did not invalidate the layout")
        content.layoutSubtreeIfNeeded()
        AppLocalization.language = .simplifiedChinese; history.reload(); choose(1)
        let imageID = store.items.first { if case .image = $0.content { return true }; return false }!.id
        let buttons = cards().flatMap(\.subviews).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == imageID.uuidString }
        buttons.first { $0.toolTip == L("贴出这条记录") }!.performClick(nil)
        try require(pinned == imageID, "A filtered card pinned a different item")
        buttons.first { $0.toolTip == L("删除这条记录") }!.performClick(nil)
        try require(cards().count == 2 && store.items.count == 11 && filter.selectedSegment == 1,
                    "Deleting a filtered item changed filter or removed another type")
        current = calendar.date(byAdding: .day, value: 1, to: current)!
        _ = history.perform(NSSelectorFromString("timeContextChanged"))
        try require(!groupLabels().contains("今天") && filter.selectedSegment == 1,
                    "Midnight failed to regroup the active filter")
        let clear = descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "history.clear" }!
        let textIDs = store.items.filter(RecentContentStore.Filter.text.includes).map(\.id)
        try require(clear.title == "清空" && clear.isEnabled && clear.toolTip == "清空图片记录",
                    "Clear button does not describe its current tab scope")
        clear.performClick(nil)
        try require(store.items.map(\.id) == textIDs && filter.selectedSegment == 1,
                    "Clearing images changed text records or switched the tab")
        try require(cards().isEmpty && groupLabels().isEmpty && !store.items.isEmpty
                    && descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "没有这类剪贴记录" },
                    "An empty filter shows stale cards or empty date groups")
        try require(!clear.isEnabled, "An empty filter still permits clearing other categories")
        clear.performClick(nil)
        try require(store.items.map(\.id) == textIDs, "An empty tab's Clear button removed another category")
        store.addImage(fixture(), pixelScale: 2)
        let remainingImage = store.items.first { RecentContentStore.Filter.images.includes($0) }!.id
        choose(2)
        try require(clear.isEnabled && clear.toolTip == "清空文本记录", "Text tab has the wrong clear scope")
        clear.performClick(nil)
        try require(store.items.map(\.id) == [remainingImage] && !clear.isEnabled,
                    "Clearing text removed its image or left the empty tab enabled")
        choose(0)
        try require(clear.isEnabled && clear.toolTip == "清空全部记录", "All tab did not restore full clear scope")
        clear.performClick(nil)
        try require(store.items.isEmpty && store.memoryUsage == 0, "All tab failed to clear every category")
        print("PASS: local dated groups and type filters preserve history; symmetric margins and clear overlay/legacy tracks at 460/461/600/880/881 widths in both languages")
    }

}
