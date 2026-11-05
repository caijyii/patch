import Darwin

private struct StickerFailure: Error { let message: String }

extension ImageToolsCanvas {
    fileprivate func stickerVerificationFrame(_ annotation: ImageToolsAnnotation) -> CGRect { annotationFrame(annotation) }
    fileprivate func stickerVerificationSelect(_ index: Int) { selectAnnotation(index) }
    fileprivate func stickerVerificationAddMosaic(_ rect: CGRect) throws {
        let annotation = ImageToolsAnnotation(tool: .mosaic,
            points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)], color: .red,
            width: 3, mosaicBlockSize: 12)
        try commitAnnotations(annotations + [annotation], selecting: 0)
    }
}

@main private struct StickerProbe {
    @MainActor static func main() {
        do {
            _ = NSApplication.shared
            if Bundle.main.bundleIdentifier == "dev.patch.sticker-drag-probe" {
                try nativeDragProbe()
                return
            }
            let items = StickerCatalog.items
            try require(items.count == 32 && Set(items.map(\.id)).count == 32,
                        "Original sticker library must contain exactly 32 unique identifiers")
            let legacySuffixes = [
                "blossom", "tulip", "seedling", "leaf-fluttering-in-wind", "sunflower",
                "front-facing-baby-chick", "cat", "butterfly", "sun", "rainbow", "cherry-blossom",
                "four-leaf-clover", "maple-leaf", "mushroom", "cactus", "herb", "dog", "rabbit",
                "panda", "fox", "honeybee", "smiling-face-with-smiling-eyes", "face-blowing-a-kiss",
                "smiling-face-with-heart-eyes", "partying-face", "thinking-face", "red-heart", "star",
                "sparkles", "balloon", "party-popper", "wrapped-gift"
            ]
            try require(Set(items.map(\.id)) == Set(legacySuffixes.filter { $0 != "face-blowing-a-kiss" }.map { "patch-\($0)" } + ["patch-blue-cat"]),
                        "Stable sticker identifiers changed")
            try require(items.map(\.groupRank) == items.map(\.groupRank).sorted(), "Default sticker groups must be animals, expressions, weather, trees, greenery, flowers, other")
            let defaultSuffixes = Array(legacySuffixes.prefix(7)) + ["blue-cat"] + Array(legacySuffixes.dropFirst(7))
            for rank in 0...6 {
                let ordered = items.filter { $0.groupRank == rank }.map(\.id)
                try require(ordered == defaultSuffixes.map { "patch-\($0)" }.filter { ordered.contains($0) }, "Within-group default ordering is unstable")
            }
            for suffix in legacySuffixes {
                let legacyID = "fluent-\(suffix)"
                let identifier = "patch-\(suffix)"
                try require(StickerCatalog.item(for: legacyID)?.id == identifier &&
                            StickerCatalog.canonicalIdentifier(legacyID) == identifier &&
                            StickerCatalog.hasVector(legacyID),
                            "Legacy sticker identifier no longer resolves: \(legacyID)")
            }
            try require(items.allSatisfy { StickerCatalog.canonicalIdentifier($0.emoji) == $0.id },
                        "Legacy emoji values no longer resolve to their original sticker")
            try require(items.allSatisfy { StickerCatalog.hasVector($0.id) }, "A sticker vector cannot be loaded")
            try require(!items.contains { $0.id == "patch-face-blowing-a-kiss" } && StickerCatalog.hasVector("😘")
                        && StickerCatalog.canonicalIdentifier("😘") == "patch-face-blowing-a-kiss",
                        "Retired kiss must be hidden but remain renderable in existing annotations")
            let catIndex = items.firstIndex { $0.id == "patch-cat" }!
            try require(items[catIndex + 1].id == "patch-blue-cat" && items[catIndex + 1].groupRank == 0,
                        "Blue cat must sit immediately after the existing cat")
            print("PASS: 32 original vectors preserve stable ordering, legacy identifiers and emoji mappings")
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
                bytesPerRow: 2400, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            let source = context.makeImage()!
            let canvas = ImageToolsCanvas(image: source)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            canvas.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
            canvas.tool = .sticker; canvas.annotationSticker = "🐥"; canvas.annotationFontSize = 96
            canvas.mouseDown(with: event(.leftMouseDown, canvas: canvas, point: CGPoint(x: 170, y: 170)))
            canvas.mouseUp(with: event(.leftMouseUp, canvas: canvas, point: CGPoint(x: 170, y: 170)))
            try require(canvas.annotations.count == 1 && canvas.selectedAnnotation?.tool == .sticker
                && canvas.selectedAnnotation?.text == "🐥" && canvas.selectedAnnotation?.fontSize == 96,
                "One click must place exactly the chosen emoji at the current size")
            let original = try canvas.renderedImage()
            let originalPNG = try ImageToolsUI.png(original)
            try require(originalPNG != ImageToolsUI.png(source), "Emoji must be visible in export")
            try originalPNG.write(to: directory.appendingPathComponent("sticker-duck.png"))
            for _ in 0..<3 { try require(try ImageToolsUI.png(canvas.renderedImage()) == originalPNG, "Redraw must retain a fixed sticker") }
            canvas.deselectAnnotation()
            try require(try ImageToolsUI.png(canvas.renderedImage()) == originalPNG, "Selection decorations must not export")
            try require(canvas.annotationContains(CGPoint(x: 170, y: 170)), "Sticker must be hit-testable at Retina scale")
            canvas.mouseDown(with: event(.leftMouseDown, canvas: canvas, point: CGPoint(x: 170, y: 170)))
            canvas.mouseDragged(with: event(.leftMouseDragged, canvas: canvas, point: CGPoint(x: 250, y: 220)))
            canvas.mouseUp(with: event(.leftMouseUp, canvas: canvas, point: CGPoint(x: 250, y: 220)))
            try require(canvas.selectedAnnotation?.points.first == CGPoint(x: 250, y: 220), "Sticker drag must use image coordinates")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(canvas.renderedImage()) == originalPNG, "Undo move must restore exact sticker pixels")
            print("PASS: fixed emoji placement, Retina hit/move, stable export, selection exclusion and move undo")

            canvas.updateSelectedAnnotation(sticker: "🌼")
            try require(canvas.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("🌼") && (try ImageToolsUI.png(canvas.renderedImage())) != originalPNG,
                        "Picking another sticker must change the selected object")
            canvas.undoAnnotation()
            try require(canvas.selectedAnnotation?.text == "🐥" && (try ImageToolsUI.png(canvas.renderedImage())) == originalPNG,
                        "Undo must restore original emoji and pixels")
            let oldFrame = canvas.stickerVerificationFrame(canvas.selectedAnnotation!)
            canvas.updateSelectedAnnotation(fontSize: 140)
            try require(canvas.selectedAnnotation?.fontSize == 140 && canvas.stickerVerificationFrame(canvas.selectedAnnotation!).width > oldFrame.width,
                        "Size controls must grow the glyph and hit frame together")
            canvas.undoAnnotation()
            canvas.deleteSelectedAnnotation()
            try require(canvas.annotations.isEmpty, "Delete must remove selected sticker")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(canvas.renderedImage()) == originalPNG, "Undo delete must restore fixed emoji")
            print("PASS: emoji replacement, size and hit-frame update, Delete and exact undo")

            let frame = canvas.stickerVerificationFrame(canvas.annotations[0]).insetBy(dx: -8, dy: -8)
            try canvas.stickerVerificationAddMosaic(frame)
            let covered = try ImageToolsUI.png(canvas.renderedImage())
            canvas.stickerVerificationSelect(0)
            canvas.updateSelectedAnnotation(sticker: "🌼")
            try require(try ImageToolsUI.png(canvas.renderedImage()) != covered, "Mosaic must rebuild when its underlying sticker changes")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(canvas.renderedImage()) == covered, "Undo must rebuild original sticker mosaic")
            print("PASS: emoji changes under mosaic rebuild and undo transactionally")

            let controlled = ImageToolsCanvas(image: source)
            window.contentView = controlled
            controlled.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
            let controls = AnnotationControls(canvas: controlled,
                preferences: PreferencesStore(storage: MemoryPreferencesStorage()), scale: { 2 })
            controls.choose(tool: .sticker)
            controls.stickerButtons.first { $0.identifier?.rawValue == "patch-cat" }!.performClick(nil)
            controlled.mouseDown(with: event(.leftMouseDown, canvas: controlled, point: CGPoint(x: 160, y: 160)))
            try require(controlled.annotations.first?.text == StickerCatalog.canonicalIdentifier("🐈") && controlled.annotations.first?.fontSize == 32,
                        "Palette choice and point-size scaling must reach the actual placed object")
            controls.sizeControl.slider.doubleValue = 64
            controls.sizeControl.slider.sendAction(controls.sizeControl.slider.action, to: controls.sizeControl.slider.target)
            try require(controlled.selectedAnnotation?.fontSize == 128, "Palette size must edit the selected sticker in pixels")
            controls.stickerButtons.first { $0.identifier?.rawValue == "patch-blossom" }!.performClick(nil)
            try require(controlled.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("🌼"), "Palette must replace the selected emoji")
            controlled.undoAnnotation()
            try require(controlled.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("🐈"), "Undo palette replacement must restore the old emoji")
            controlled.deselectAnnotation()
            controlled.mouseDown(with: event(.leftMouseDown, canvas: controlled, point: CGPoint(x: 410, y: 160)))
            try require(controlled.annotations.map(\.text) == ["🐈", "🌼"].map(StickerCatalog.canonicalIdentifier),
                        "Picking an old sticker must not overwrite the palette's next-placement choice")
            try ImageToolsUI.png(controlled.renderedImage()).write(to: directory.appendingPathComponent("sticker-palette.png"))
            print("PASS: real palette places, replaces and sizes stickers; object selection and undo preserve next-placement defaults")
            try reorderAndGlyph(source: source, directory: directory)
            try verifyResizingHosts(source: source)
            for scale: CGFloat in [1, 2] {
                let sizingCanvas = ImageToolsCanvas(image: source)
                let memory = MemoryPreferencesStorage()
                let store = PreferencesStore(storage: memory)
                var visibleScale = scale
                let sizing = AnnotationControls(canvas: sizingCanvas, preferences: store, scale: { visibleScale })
                sizing.choose(tool: .sticker)
                try require(sizingCanvas.annotationFontSize == 16 * scale, "Default is not 16 visible points at this image scale")
                for points in [16, 24] {
                    sizing.sizeControl.slider.doubleValue = Double(points)
                    sizing.sizeControl.slider.sendAction(sizing.sizeControl.slider.action, to: sizing.sizeControl.slider.target)
                    try require(sizingCanvas.annotationFontSize == CGFloat(points) * scale, "Small size does not convert to image pixels")
                }
                visibleScale = scale * 2
                sizing.displayScaleDidChange()
                try require(sizingCanvas.annotationFontSize == 24 * visibleScale && store.annotation(for: "贴纸").fontSize == 24,
                            "Viewport scale changes rewrite a stored point size or leave new placements oversized")
                for points in [16, 24, 48] {
                    var oldSetting = store.annotation(for: "贴纸"); oldSetting.fontSize = Double(points)
                    store.setAnnotation(oldSetting, for: "贴纸")
                    let restoredStore = PreferencesStore(storage: memory)
                    let restoredCanvas = ImageToolsCanvas(image: source)
                    let restoredControls = AnnotationControls(canvas: restoredCanvas,
                        preferences: restoredStore, scale: { scale })
                    restoredControls.choose(tool: .sticker)
                    try require(restoredStore.annotation(for: "贴纸").fontSize == Double(points) &&
                                restoredCanvas.annotationFontSize == CGFloat(points) * scale,
                                "An existing explicit \(points)-point preference was overwritten")
                }
            }
            print("PASS: 16/24-point sizes, 1x/2x conversion, viewport changes and existing preferences")

            let zoomed = ImageToolsCanvas(image: source)
            window.contentView = zoomed
            zoomed.bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
            var mosaicError: Error?
            zoomed.onError = { mosaicError = $0 }
            let zoomedStore = PreferencesStore(storage: MemoryPreferencesStorage())
            let zoomedControls = AnnotationControls(canvas: zoomed, preferences: zoomedStore, scale: { 1 / 8 })
            zoomedControls.choose(tool: .mosaic)
            try require(zoomed.mosaicBlockSize == 2 && zoomedStore.annotation(for: "马赛克").mosaicBlockSize == 12,
                        "8x editor zoom makes the default mosaic invalid or rewrites its screen-point preference")
            zoomedControls.sizeControl.slider.doubleValue = 4
            zoomedControls.sizeControl.slider.sendAction(zoomedControls.sizeControl.slider.action, to: zoomedControls.sizeControl.slider.target)
            try require(zoomed.mosaicBlockSize == 2 && zoomedStore.annotation(for: "马赛克").mosaicBlockSize == 4,
                        "Small mosaic choice is not clamped in image pixels independently of its saved point size")
            zoomed.mouseDown(with: event(.leftMouseDown, canvas: zoomed, point: CGPoint(x: 30, y: 30)))
            zoomed.mouseDragged(with: event(.leftMouseDragged, canvas: zoomed, point: CGPoint(x: 90, y: 90)))
            zoomed.mouseUp(with: event(.leftMouseUp, canvas: zoomed, point: CGPoint(x: 90, y: 90)))
            try require(zoomed.annotations.count == 1 && zoomed.annotations[0].mosaic != nil,
                        "Minimum mosaic blocks cannot be drawn at 8x editor zoom")
            zoomedControls.sizeControl.slider.doubleValue = 8
            zoomedControls.sizeControl.slider.sendAction(zoomedControls.sizeControl.slider.action, to: zoomedControls.sizeControl.slider.target)
            try require(mosaicError == nil && zoomed.selectedAnnotation?.mosaicBlockSize == 2 &&
                        zoomedStore.annotation(for: "马赛克").mosaicBlockSize == 8,
                        "Editing a selected mosaic at 8x zoom bypasses the pixel minimum or damages the saved size")
            print("PASS: 8x editor zoom keeps mosaic blocks drawable and editable without changing saved point sizes")

            let previousCount = canvas.annotations.count
            let previousSelection = canvas.selectedAnnotation?.text
            let previousMosaic = try ImageToolsUI.png(canvas.annotations.last!.mosaic!)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            let replacement = context.makeImage()!
            try canvas.replaceSourcePreservingAnnotations(replacement)
            try require(canvas.annotations.count == previousCount && canvas.selectedAnnotation?.text == previousSelection,
                        "Changing the subject image discards annotations or selection")
            try require(try ImageToolsUI.png(canvas.annotations.last!.mosaic!) != previousMosaic,
                        "Changing the subject image leaves a stale mosaic")
            canvas.undoAnnotation()
            try require(canvas.annotations.count == previousCount - 1 && canvas.source === replacement,
                        "Changing the subject image loses annotation undo history")
            var rejected = false
            do { try canvas.replaceSourcePreservingAnnotations(source.cropping(to: CGRect(x: 0, y: 0, width: 100, height: 100))!) }
            catch { rejected = true }
            try require(rejected && canvas.source === replacement, "Invalid source dimensions were accepted or damaged the previous source")
            print("PASS: source replacement preserves annotations, selection and undo; mosaics rebuild and invalid sizes roll back")

            let sheetContext = CGContext(data: nil, width: 1000, height: 400, bitsPerComponent: 8,
                bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            sheetContext.setFillColor(CGColor(gray: 1, alpha: 1)); sheetContext.fill(CGRect(x: 0, y: 0, width: 1000, height: 400))
            let sheet = ImageToolsCanvas(image: sheetContext.makeImage()!)
            window.contentView = sheet; sheet.bounds = CGRect(x: 0, y: 0, width: 1000, height: 400)
            sheet.tool = .sticker; sheet.annotationSticker = StickerCatalog.canonicalIdentifier("🐥")
            for (x, size): (CGFloat, CGFloat) in [(60, 24), (140, 48), (250, 96), (425, 192), (730, 320)] {
                sheet.annotationFontSize = size
                sheet.mouseDown(with: event(.leftMouseDown, canvas: sheet, point: CGPoint(x: x, y: 200)))
                sheet.mouseUp(with: event(.leftMouseUp, canvas: sheet, point: CGPoint(x: x, y: 200)))
                try require(sheet.stickerVerificationFrame(sheet.annotations.last!).size == CGSize(width: size, height: size),
                            "Vector sticker size and hit frame disagree")
            }
            let sizeSheet = try sheet.renderedImage()
            let bitmap = NSBitmapImageRep(cgImage: sizeSheet)
            for (center, size): (Int, Int) in [(60, 24), (140, 48), (250, 96), (425, 192), (730, 320)] {
                var paintedColumns = 0
                for x in (center - size / 2)..<(center + size / 2) {
                    for y in (200 - size / 2)..<(200 + size / 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        if min(color.redComponent, min(color.greenComponent, color.blueComponent)) < 0.9 {
                            paintedColumns += 1; break
                        }
                    }
                }
                try require(paintedColumns >= Int(Double(size) * 0.65),
                            "Vector drawing does not grow with its hit frame: size \(size), painted width \(paintedColumns)")
            }
            try ImageToolsUI.png(sizeSheet).write(to: directory.appendingPathComponent("sticker-vector-sizes.png"))
            print("PASS: actual exported vector pixels grow with 24/48/96/192/320-pixel frames")
            window.close()
            print("COMPLETE: sticker verification")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    /// A disposable app exercises AppKit's real popover/event/dragging path through CUA.
    /// Its preferences and event log remain inside the verification directory.
    @MainActor private static func nativeDragProbe() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Sticker Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); app.mainMenu = menu
        AppLocalization.language = .simplifiedChinese
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        let saved = directory.appendingPathComponent("native-preferences.json")
        let storage = MemoryPreferencesStorage(data: try? Data(contentsOf: saved))
        let preferences = PreferencesStore(storage: storage)
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let canvas = ImageToolsCanvas(image: context.makeImage()!)
        let controls = AnnotationControls(canvas: canvas, preferences: preferences)
        controls.choose(tool: .sticker)
        let second = AnnotationControls(canvas: ImageToolsCanvas(image: context.makeImage()!), preferences: preferences)
        second.choose(tool: .sticker)
        let toolbar = SelectionToolbar()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 660, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Patch Sticker Drag Probe"
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 660, height: 360))
        window.contentView = root; root.addSubview(canvas); canvas.frame = CGRect(x: 10, y: 10, width: 640, height: 240)
        root.addSubview(toolbar)
        let picker = StickerPickerController(items: controls.orderedStickerIdentifiers.compactMap { StickerCatalog.item(for: $0) },
            selected: canvas.annotationSticker, onReorder: { order in
                preferences.setStickerOrder(order, defaults: StickerCatalog.items.map(\.id), canonicalize: StickerCatalog.canonicalIdentifier)
            }, onPick: { identifier in canvas.annotationSticker = identifier })
        let pickerWindow = NSWindow(contentRect: picker.view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        pickerWindow.title = "Patch Native Sticker Picker"; pickerWindow.isReleasedWhenClosed = false
        pickerWindow.contentView = picker.view
        let overlayAction = SelectionButton("Test screenshot-level popover") {
            pickerWindow.orderOut(nil)
            window.level = .screenSaver
            NSCursor.frameResize(position: .topLeft, directions: .all).set()
            controls.moreStickerButton.performClick(nil)
        }
        overlayAction.frame = CGRect(x: 18, y: 14, width: 280, height: 30)
        root.addSubview(overlayAction)
        func record() {
            toolbar.rows = controls.rows(maxWidth: 640)
            toolbar.frame = CGRect(origin: CGPoint(x: 10, y: 260), size: toolbar.arrange(maxWidth: 640))
            let state: [String: Any] = ["order": controls.orderedStickerIdentifiers,
                "secondOrder": second.orderedStickerIdentifiers, "selected": canvas.annotationSticker,
                "writes": storage.writeCount]
            try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("native-drag-state.json"))
            if let data = storage.data { try? data.write(to: saved) }
        }
        controls.onUpdate = { record() }
        record()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            let line = "event \(event.type.rawValue), window \(event.window?.title ?? "nil"), level \(event.window?.level.rawValue ?? -1), point \(event.locationInWindow)\n"
            let url = directory.appendingPathComponent("native-window-events.txt")
            if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
            else { try? Data(line.utf8).write(to: url) }
            return event
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        pickerWindow.setFrameOrigin(CGPoint(x: window.frame.maxX + 15, y: window.frame.minY))
        pickerWindow.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        withExtendedLifetime([window, pickerWindow, picker, controls, second, preferences] as [AnyObject]) { app.run() }
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    @MainActor private static func reorderAndGlyph(source: CGImage, directory: URL) throws {
        let memory = MemoryPreferencesStorage()
        let store = PreferencesStore(storage: memory)
        let firstCanvas = ImageToolsCanvas(image: source), secondCanvas = ImageToolsCanvas(image: source)
        let first = AnnotationControls(canvas: firstCanvas, preferences: store)
        let second = AnnotationControls(canvas: secondCanvas, preferences: store)
        first.choose(tool: .sticker); second.choose(tool: .sticker)
        first.stickerButtons.first { $0.identifier?.rawValue == "patch-cat" }!.performClick(nil)
        let selected = firstCanvas.annotationSticker
        let ids = StickerCatalog.items.map(\.id)
        var picked: String?
        let picker = StickerPickerController(items: StickerCatalog.items, selected: selected, onReorder: { order in
            store.setStickerOrder(order, defaults: ids, canonicalize: StickerCatalog.canonicalIdentifier)
        }) { picked = $0 }
        let pickerWindow = NSWindow(contentRect: picker.view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        pickerWindow.isReleasedWhenClosed = false; pickerWindow.contentView = picker.view
        if !CommandLine.arguments.contains("--no-front") { pickerWindow.orderFrontRegardless() }
        defer { pickerWindow.close() }
        func button(_ id: String) -> NSButton {
            picker.view.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id }!
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: picker.view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pickerWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func gesture(_ source: NSButton, to point: CGPoint, cancel: Bool = false, small: Bool = false) {
            let origin = CGPoint(x: source.frame.midX, y: source.frame.midY)
            if cancel {
                NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pickerWindow.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!, atStart: true)
            } else { NSApp.postEvent(event(.leftMouseUp, at: point), atStart: true) }
            NSApp.postEvent(event(.leftMouseDragged, at: small ? CGPoint(x: origin.x + 2, y: origin.y) : point), atStart: true)
            source.mouseDown(with: event(.leftMouseDown, at: origin))
        }
        let movedID = ids.last!
        let sourceButton = button(movedID), target = button(ids.first!)
        NSCursor.resizeLeftRight.set()
        sourceButton.cursorUpdate(with: event(.mouseMoved, at: CGPoint(x: sourceButton.frame.midX, y: sourceButton.frame.midY)))
        try require(NSCursor.current == .openHand, "Sticker hover inherited the canvas resize cursor")
        try require(picker.view.registeredDraggedTypes.isEmpty, "Local-only reordering should not register system pasteboard drops")
        gesture(sourceButton, to: CGPoint(x: target.frame.midX, y: target.frame.midY))
        let expected = [movedID] + ids.dropLast()
        try require(picked == nil, "Dragging selected a sticker instead of only reordering")
        try require(first.orderedStickerIdentifiers == expected && second.orderedStickerIdentifiers == expected, "Open toolbars did not receive shared order changes")
        let inline = first.rows(maxWidth: 840).flatMap { $0 }.compactMap { $0 as? NSButton }.filter { $0.identifier != nil }
        try require(inline.map { $0.identifier!.rawValue } == Array(expected.prefix(inline.count)), "Adaptive inline choices do not match reordered library")
        try require(firstCanvas.annotationSticker == selected && first.stickerButtons.first { $0.state == .on }?.identifier?.rawValue == selected,
                    "Reordering discarded the selected sticker")
        let restored = PreferencesStore(storage: memory)
        let reopened = AnnotationControls(canvas: ImageToolsCanvas(image: source), preferences: restored)
        try require(reopened.orderedStickerIdentifiers == expected, "Reopened toolbar did not retain order")
        try require(!picker.moveSticker(movedID, toInsertionIndex: 0) && !picker.moveSticker("missing", toInsertionIndex: 2), "Invalid/no-op moves changed order")
        let next = button(ids.first!)
        gesture(button(movedID), to: CGPoint(x: next.frame.midX, y: next.frame.midY))
        try require(picker.items[0].id == ids.first! && picker.items[1].id == movedID,
                    "Dragging onto the adjacent item's centre did not swap the two")
        let front = button(ids.first!)
        gesture(button(movedID), to: CGPoint(x: front.frame.midX, y: front.frame.midY))
        try require(picker.items.map(\.id) == expected, "Moving backward onto an item centre did not restore order")
        let writes = memory.writeCount
        gesture(button(movedID), to: CGPoint(x: -30, y: -20))
        gesture(button(movedID), to: CGPoint(x: 100, y: 70), cancel: true)
        try require(memory.writeCount == writes && picker.items.map(\.id) == expected && picked == nil,
                    "Outside release or Escape saved a reorder or selected a sticker")
        let click = button(ids.first!)
        gesture(click, to: CGPoint(x: click.frame.midX + 2, y: click.frame.midY), small: true)
        try require(picked == ids.first! && memory.writeCount == writes,
                    "A click with small pointer movement did not select without reordering")

        if let bitmap = picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds) {
            picker.view.cacheDisplay(in: picker.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("reordered-picker.png"))
        }
        let oldLanguage = AppLocalization.language
        defer { AppLocalization.language = oldLanguage }
        var localizedSymbols: [Data] = []
        for locale in ["zh-Hans", "en"] {
            let symbol = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)!.withLocale(Locale(identifier: locale))
            let preview = NSImage(size: CGSize(width: 80, height: 80), flipped: false) { bounds in
                symbol.draw(in: bounds.insetBy(dx: 8, dy: 8)); return true
            }
            let data = try ImageToolsUI.png(preview.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            localizedSymbols.append(data)
            try data.write(to: directory.appendingPathComponent("previous-textformat-\(locale).png"))
        }
        print("INFO: system textformat differs between Chinese/English representations: \(localizedSymbols[0] != localizedSymbols[1])")
        var glyphs: [Data] = []
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            let controls = AnnotationControls(canvas: ImageToolsCanvas(image: source), preferences: store)
            let text = controls.toolButtons[.text]!
            try require(text.imagePosition == .imageOnly && text.image?.isTemplate == true && text.image?.size == CGSize(width: 16, height: 16),
                        "Text tool should use a stable template T, not a locale-sensitive system symbol")
            let image = text.image!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            glyphs.append(try ImageToolsUI.png(image))
            try glyphs.last!.write(to: directory.appendingPathComponent("text-tool-\(language.rawValue).png"))
            try require(Array(controls.rows[0].prefix(8)) == AnnotationControls.displayOrder.map { controls.toolButtons[$0]! }, "Shared tool order differs across editors")
        }
        try require(glyphs[0] == glyphs[1], "Text glyph changed with interface language")
        print("PASS: reordered library persists, open toolbars share the adaptive prefix, selection survives and text T is language invariant")
    }

    @MainActor private static func verifyResizingHosts(source: CGImage) throws {
        let oldLanguage = AppLocalization.language
        defer { AppLocalization.language = oldLanguage }
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            let storage = MemoryPreferencesStorage()
            let editor = InlineAnnotationView(image: source, preferences: PreferencesStore(storage: storage), completionHint: "Done")
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = editor
            defer { window.close() }
            editor.controls.choose(tool: .sticker)
            guard let toolbar = editor.subviews.compactMap({ $0 as? SelectionToolbar }).first else { throw StickerFailure(message: "Missing inline toolbar") }
            var counts: [Int] = []
            for width: CGFloat in [560, 740, 1000, 560] {
                window.setContentSize(CGSize(width: width, height: 420))
                editor.needsLayout = true; editor.layoutSubtreeIfNeeded()
                let row = toolbar.rows[1].filter { !$0.isHidden }
                counts.append(row.filter { view in editor.controls.stickerButtons.contains { $0 === view } }.count)
                try require(row.allSatisfy { abs($0.frame.midY - editor.controls.sizeControl.frame.midY) < 0.5 },
                            "Resizing the real inline editor wraps More or size")
            }
            try require(counts[0] < counts[1] && counts[1] < counts[2] && counts[0] == counts[3] && storage.writeCount == 0,
                        "Actual host resizing failed to adapt capacity reversibly without changing preferences")
        }
        let picker = StickerPickerController(items: StickerCatalog.items, selected: StickerCatalog.defaultIdentifier) { _ in }
        let buttons = picker.view.subviews.compactMap { $0 as? NSButton }
        try require(picker.view.bounds.size == CGSize(width: 328, height: 222)
                    && Set(buttons.map { $0.frame.minY }).count == 4 && Set(buttons.map { $0.frame.minX }).count == 8,
                    "More must keep all 32 patterns in eight columns and four complete rows")
        let narrow = StickerPickerController(items: StickerCatalog.items, selected: StickerCatalog.defaultIdentifier, availableWidth: 240) { _ in }
        try require(narrow.view.bounds.width <= 240 && narrow.view.subviews.compactMap { $0 as? NSButton }.count == 32,
                    "Screen-constrained picker clipped or removed patterns")
        print("PASS: Chinese/English inline windows resize capacity live; all 32 patterns occupy a complete 8-by-4 picker")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw StickerFailure(message: message) }
    }
    @MainActor private static func event(_ type: NSEvent.EventType, canvas: ImageToolsCanvas, point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }
}
