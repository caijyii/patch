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
            try require(items.map(\.id) == legacySuffixes.map { "patch-\($0)" },
                        "Sticker order or stable identifiers changed")
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
            controls.stickerButtons[6].performClick(nil)
            controlled.mouseDown(with: event(.leftMouseDown, canvas: controlled, point: CGPoint(x: 160, y: 160)))
            try require(controlled.annotations.first?.text == StickerCatalog.canonicalIdentifier("🐈") && controlled.annotations.first?.fontSize == 32,
                        "Palette choice and point-size scaling must reach the actual placed object")
            controls.sizeControl.slider.doubleValue = 64
            controls.sizeControl.slider.sendAction(controls.sizeControl.slider.action, to: controls.sizeControl.slider.target)
            try require(controlled.selectedAnnotation?.fontSize == 128, "Palette size must edit the selected sticker in pixels")
            controls.stickerButtons[0].performClick(nil)
            try require(controlled.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("🌼"), "Palette must replace the selected emoji")
            controlled.undoAnnotation()
            try require(controlled.selectedAnnotation?.text == StickerCatalog.canonicalIdentifier("🐈"), "Undo palette replacement must restore the old emoji")
            controlled.deselectAnnotation()
            controlled.mouseDown(with: event(.leftMouseDown, canvas: controlled, point: CGPoint(x: 410, y: 160)))
            try require(controlled.annotations.map(\.text) == ["🐈", "🌼"].map(StickerCatalog.canonicalIdentifier),
                        "Picking an old sticker must not overwrite the palette's next-placement choice")
            try ImageToolsUI.png(controlled.renderedImage()).write(to: directory.appendingPathComponent("sticker-palette.png"))
            print("PASS: real palette places, replaces and sizes stickers; object selection and undo preserve next-placement defaults")
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

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw StickerFailure(message: message) }
    }
    @MainActor private static func event(_ type: NSEvent.EventType, canvas: ImageToolsCanvas, point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }
}
