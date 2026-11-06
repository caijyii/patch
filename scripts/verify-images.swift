// This probe is concatenated after ImageTools.swift by verify-images.sh so it can
// exercise the actual private rendering and text-layout code without production hooks.
import Darwin

private struct ImageToolsVerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private struct ImageToolsTextLayoutSnapshot: Equatable {
    let containerWidth: CGFloat
    let lineEnds: [Int]
    let text: String
}

extension ImageToolsCanvas {
    fileprivate var verificationExportBounds: CGRect { exportBounds(for: annotations) }
    fileprivate var verificationHistoryRetainsRaster: Bool {
        history.contains { $0.annotations.contains { $0.mosaic != nil } }
    }
    fileprivate func verificationAdd(_ annotation: ImageToolsAnnotation) throws {
        try commitAnnotations(annotations + [annotation], selecting: nil)
    }
    fileprivate func verificationMosaic(_ rect: CGRect) throws {
        let annotation = ImageToolsAnnotation(tool: .mosaic,
            points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)],
            color: .red, width: 3, mosaicBlockSize: 12)
        try commitAnnotations(annotations + [annotation], selecting: nil)
    }
    fileprivate func verificationWriteText(_ text: String, at point: CGPoint) {
        beginTextEditing(at: point)
        textEditor?.stringValue = text
        textEditor?.currentEditor()?.string = text
        finishTextEditing()
    }
}

extension ImageToolsEditorController {
    fileprivate var verificationCopyButtons: [SelectionButton] { actions.compactMap { $0 as? SelectionButton }.filter { $0.title == "复制" } }
    fileprivate var verificationCanvas: ImageToolsCanvas { canvas }
    fileprivate var verificationMagnification: CGFloat { scroll.magnification }
    fileprivate var verificationToolTitle: String? { controls.activeTool?.rawValue }
    fileprivate var verificationColor: NSColor {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
        let index = controls.colorButtons.firstIndex { $0.state == .on } ?? 0
        return colors[index]
    }
    private var verificationSizes: [Double] {
        switch controls.activeTool {
        case .text: return [14, 18, 24, 32, 48]
        case .number: return [18, 24, 32, 40]
        case .mosaic: return [4, 8, 12, 20, 32]
        default: return [1.5, 3, 5, 8]
        }
    }
    fileprivate var verificationWidthIndex: Int {
        verificationSizes.firstIndex(of: controls.sizeControl.slider.doubleValue) ?? -1
    }
    fileprivate var verificationUndoEnabled: Bool { controls.undoButton.isEnabled }
    fileprivate func verificationChangeColor(_ color: NSColor) {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
        if let index = colors.firstIndex(where: { $0.isEqual(color) }) { controls.colorButtons[index].performClick(nil) }
    }
    fileprivate func verificationChangeWidth(_ index: Int) {
        controls.sizeControl.slider.doubleValue = verificationSizes[index]
        controls.sizeControl.slider.sendAction(controls.sizeControl.slider.action, to: controls.sizeControl.slider.target)
    }
    fileprivate func verificationChangeTool(_ tool: ImageToolsTool) { controls.toolButtons[tool]?.performClick(nil) }
    fileprivate func verificationUndo() { controls.undoButton.performClick(nil) }
    fileprivate func verificationApply() {
        (actions.compactMap { $0 as? NSButton }.first { $0.title == "应用到贴图" })?.performClick(nil)
    }
}

extension ImageToolsPinController {
    fileprivate var verificationHUDButtons: [SelectionButton] { toolbar.rows.flatMap { $0 }.compactMap { $0 as? SelectionButton } }
    fileprivate var verificationCopyButtons: [SelectionButton] { toolbar.rows.flatMap { $0 }.compactMap { $0 as? SelectionButton }.filter { $0.title.hasPrefix("复制") } }
    fileprivate var verificationImage: CGImage? { imageView?.image }
    fileprivate var verificationTextView: ImageToolsPinTextView? { textView }
    fileprivate func verificationEditing(_ value: Bool) { setTextEditing(value) }
    fileprivate func verificationTextColor(_ color: NSColor) { colorSelectedText(color) }

    fileprivate var verificationZoom: CGFloat { scale }
    fileprivate var verificationMenuTitles: [String] { contextMenu().items.filter { !$0.isSeparatorItem }.map(\.title) }
    fileprivate var verificationHasEditor: Bool { inlineEditor != nil }
    fileprivate var verificationSelected: Bool { selected && surface.selected }
    fileprivate var verificationHUD: NSWindow? { hud }
    fileprivate var verificationHUDTitles: [String] { toolbar.rows.flatMap { $0.compactMap { ($0 as? NSButton)?.title } } }
    fileprivate var verificationImageViewport: CGSize { verificationPinViewportFrame.size }
    fileprivate var verificationWholeImageFrame: CGRect? { imageFrame }
    fileprivate var verificationImageUsesScrollView: Bool { imageView != nil && (imageView?.enclosingScrollView != nil || !scroll.isHidden) }
    fileprivate var verificationImageSelectionRect: CGRect? {
        selectionOutline.selectionRect.map { surface.convert($0, from: selectionOutline) }
    }
    fileprivate var verificationTextCornerRadius: CGFloat { selectionOutline.cornerRadius }
    fileprivate var verificationImageContentFrame: CGRect? {
        imageView.map { surface.convert($0.imageRect, from: $0) }
    }
    fileprivate var verificationOutlineFrame: CGRect { selectionOutline.frame }
    fileprivate var verificationPinViewportFrame: CGRect {
        if let imageView { return surface.convert(imageView.imageRect, from: imageView).intersection(surface.bounds) }
        return surface.convert(scroll.contentView.bounds, from: scroll.contentView)
    }
    fileprivate var verificationTextDocumentSize: CGSize { textView?.frame.size ?? .zero }
    fileprivate var verificationTextSelection: NSRange? { textView?.selectedRange() }
    fileprivate var verificationTextRemainsEditable: Bool {
        textView?.isEditable == true && textView?.isSelectable == true
            && textView?.textContainerInset == CGSize(width: 16, height: 16)
            && textView?.textContainer?.widthTracksTextView == false
    }
    fileprivate func verificationSelectText(_ range: NSRange) { setTextEditing(true); textView?.setSelectedRange(range) }
    fileprivate func verificationTextReceivesHit() -> Bool {
        guard let textView, !textView.visibleRect.isEmpty else { return false }
        let point = surface.convert(CGPoint(x: textView.visibleRect.midX, y: textView.visibleRect.midY), from: textView)
        return surface.hitTest(point) === textView
    }
    fileprivate func verificationEditPinText(_ text: String) throws {
        guard let textView else { throw ImageToolsVerificationFailure(description: "Text edit fixture has no text view") }
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }
    fileprivate func verificationContentReceivesHit(at point: CGPoint) -> Bool {
        if let imageView { return surface.hitTest(point) === imageView }
        let expected = scroll.hitTest(point)
        return expected != nil && surface.hitTest(point) === expected
    }
    fileprivate func verificationScrollImage() {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    fileprivate func verificationSelect() { setSelected(true) }
    fileprivate func verificationDeselect() { setSelected(false) }
    fileprivate func verificationDeactivate() { applicationDeactivated(Notification(name: NSApplication.didResignActiveNotification)) }
    fileprivate func verificationHUDOCR() {
        (toolbar.rows.flatMap { $0 }.compactMap { $0 as? NSButton }.first { $0.title == "提取文字" })?.performClick(nil)
    }
    fileprivate func verificationDrag(dx: CGFloat, dy: CGFloat, useHUD: Bool = false,
                                      afterMouseDown: (() -> Void)? = nil, option: Bool = true) throws {
        guard let window, let source = useHUD ? hud : window else {
            throw ImageToolsVerificationFailure(description: "Pin drag has no event window")
        }
        let view: NSView?
        if useHUD { view = toolbar.rows.first?.first }
        else { view = imageView ?? textView }
        guard let view else { throw ImageToolsVerificationFailure(description: "Pin drag has no view") }
        let hitView: NSView = useHUD || imageView != nil ? view : scroll.contentView
        let start = source.convertPoint(toScreen: hitView.convert(CGPoint(x: hitView.bounds.midX, y: hitView.bounds.midY), to: nil))
        let flags: NSEvent.ModifierFlags = textView != nil && !useHUD && option ? [.option] : []
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            guard let result = NSEvent.mouseEvent(with: type, location: source.convertPoint(fromScreen: point),
                modifierFlags: flags, timestamp: 0, windowNumber: source.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw ImageToolsVerificationFailure(description: "Cannot create local pin mouse event")
            }
            return result
        }
        view.mouseDown(with: try event(.leftMouseDown, at: start))
        afterMouseDown?()
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        view.mouseDragged(with: try event(.leftMouseDragged, at: end))
        view.mouseUp(with: try event(.leftMouseUp, at: end))
    }
    fileprivate func verificationPrepareEditor() -> InlineAnnotationView? { annotateImage(); return inlineEditor }
    fileprivate func verificationWheel(_ amount: Int32, precise: Bool) throws {
        guard let view: NSView = imageView ?? textView else { return }
        let event = PinScrollEvent()
        event.delta = CGFloat(amount); event.precise = precise
        event.point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.scrollWheel(with: event)
    }
    fileprivate func verificationPinch(_ factor: CGFloat) {
        guard let view: NSView = imageView ?? textView else { return }
        let event = PinAnnotationMagnifyEvent()
        event.amount = factor - 1
        event.point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.magnify(with: event)
    }
    fileprivate func verificationTextLayout() throws -> ImageToolsTextLayoutSnapshot {
        guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else {
            throw ImageToolsVerificationFailure(description: "Text pin has no text layout manager")
        }
        layout.ensureLayout(for: container)
        var glyph = 0
        var ends: [Int] = []
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            guard NSMaxRange(range) > glyph else {
                throw ImageToolsVerificationFailure(description: "Text layout has a non-advancing glyph range")
            }
            ends.append(NSMaxRange(range))
            glyph = NSMaxRange(range)
        }
        return ImageToolsTextLayoutSnapshot(containerWidth: container.containerSize.width,
                                            lineEnds: ends, text: textView.string)
    }
    fileprivate func verificationScale(_ newScale: CGFloat) {
        scale = newScale
        if imageView != nil {
            let visible = visibleArea()
            let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
            imageFrame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                width: size.width, height: size.height)
        }
        updateScale()
    }
}

extension ImageToolsCoordinator {
    fileprivate var verificationPins: [ImageToolsPinController] { Array(pins.values) }
}

extension ImageToolsOCRController {
    fileprivate var verificationCopyButton: NSButton { copyButton }
    fileprivate var verificationCopyEnabled: Bool { copyButton.isEnabled }
    fileprivate var verificationStatusHidden: Bool { status.isHidden }
    fileprivate var verificationText: String { textView.string }
    fileprivate var verificationFontSize: CGFloat? { textView.font?.pointSize }
    fileprivate func verificationCopy() { copyText() }
    fileprivate func verificationEdit(_ text: String) {
        textView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }
}

private final class PinScrollEvent: NSEvent {
    var delta: CGFloat = 0
    var precise = false
    var point = CGPoint.zero
    override var scrollingDeltaY: CGFloat { delta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var locationInWindow: NSPoint { point }
    override var type: NSEvent.EventType { .scrollWheel }
}

private final class PinAnnotationMagnifyEvent: NSEvent {
    var amount: CGFloat = 0.25
    var point = CGPoint.zero
    override var magnification: CGFloat { amount }
    override var locationInWindow: NSPoint { point }
    override var type: NSEvent.EventType { .magnify }
}

@main
private struct ImageToolsVerification {
    @MainActor static func main() {
        guard (2...3).contains(CommandLine.arguments.count), CommandLine.arguments[1].hasPrefix("/"),
              CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--ocr" else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            fputs("FAIL: image verification timed out\n", stderr); exit(1)
        }
        do {
            _ = NSApplication.shared
            try verifyCapturePinSize()
            try verifyWholeImagePinGeometry()
            try verifyExternalPinWindowMovement()
            try verifyClipboardPinSize()
            try verifyCursorPinPlacement()
            let outputDirectory = CommandLine.arguments.dropFirst().first ?? "/private/tmp"
            try verifyPinOutsideAnnotations()
            try verifyPinAnnotationViewport(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyAnnotationToolbarConsistency()
            try verifyCopyButtonStates()
            try verifyArrowTips(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyIndependentToolSizes()
            try verifyObjectEditing()
            try verifyMosaicEditing()
            try verifyLegacyEditorBinding()
            try verifyImagePinContentBounds(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyImagePinSelection(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyTextPinContentBounds(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyPinsAndOCRPresentation(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyInlineWorkflows(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyRendering(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyRegionRendering()
            try verifyOutsideRendering(outputDirectory: URL(fileURLWithPath: outputDirectory))
            try verifyTextLayout()
            try verifyOCRLanguages()
            if CommandLine.arguments.contains("--ocr") {
                print("Checking optional local end-to-end OCR…")
                fflush(stdout)
                try verifyOCR(outputDirectory: URL(fileURLWithPath: outputDirectory))
                try verifyOCRAngles(outputDirectory: URL(fileURLWithPath: outputDirectory))
            } else {
                print("SKIP: end-to-end OCR (run scripts/verify-images.sh --ocr to include it)")
            }
            print("PASS: all requested image verification checks completed")
        } catch {
            fflush(stdout)
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ImageToolsVerificationFailure(description: message) }
    }

    private static func rgba(_ image: CGImage, x: Int, y: Int) throws -> [CGFloat] {
        guard let color = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            throw ImageToolsVerificationFailure(description: "Cannot read raster pixel (\(x), \(y))")
        }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }

    private static func same(_ lhs: [CGFloat], _ rhs: [CGFloat]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.015 }
    }

    private static func solidImage(width: Int = 260, height: Int = 260) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate solid image")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ImageToolsVerificationFailure(description: "Cannot make solid image")
        }
        return image
    }

    @MainActor private static func verifyImageHost(_ pin: ImageToolsPinController, inset: CGFloat) throws {
        guard let window = pin.window, let content = window.contentView,
              let whole = pin.verificationWholeImageFrame, let local = pin.verificationImageContentFrame else {
            throw ImageToolsVerificationFailure(description: "Missing whole-image presentation")
        }
        let desktop = NSScreen.screens.map(\.visibleFrame).reduce(CGRect.null) { $0.union($1) }
        let expectedHost = whole.insetBy(dx: -inset, dy: -inset).intersection(desktop).integral
        let mapped = local.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        try require(window.frame == expectedHost && desktop.integral.contains(window.frame)
                    && mapped.size == whole.size && abs(mapped.minX - whole.minX) < 0.000001
                    && abs(mapped.minY - whole.minY) < 0.000001
                    && pin.verificationPinViewportFrame == local.intersection(content.bounds),
                    "Image host changed logical placement or allocated outside the desktop: whole=\(whole), local=\(local), host=\(window.frame), expected=\(expectedHost)")
    }

    @MainActor private static func verifyCursorPinPlacement() throws {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = CGRect(x: -1920, y: -160, width: 1920, height: 1080)
        let visible = secondary.insetBy(dx: 0, dy: 24)
        let anchor = CGPoint(x: -1100, y: 650)
        try require(ImageToolsPinPlacement.screenIndex(for: anchor, frames: [main, secondary]) == 1,
                    "Negative-origin pointer chose the primary display")
        let size = CGSize(width: 200, height: 120)
        let initial = ImageToolsPinPlacement.frame(size: size, anchor: anchor, visible: visible)
        try require(initial == CGRect(x: anchor.x + 16, y: anchor.y - 16 - size.height, width: 200, height: 120),
                    "Pin did not open 16 points below/right of its trigger position")
        let corners = [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.minY),
                       CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)]
        for corner in corners {
            var origins: Set<String> = []
            for index in 0..<5 {
                let frame = ImageToolsPinPlacement.frame(size: size, anchor: corner, visible: visible, batchIndex: index)
                try require(visible.contains(frame) && frame.size == size,
                            "Edge placement resized the content or escaped its original display")
                origins.insert("\(frame.minX),\(frame.minY)")
            }
            try require(origins.count == 5, "Batch pins collapsed to the same edge position")
        }
        let clipped = ImageToolsPinPlacement.frame(size: CGSize(width: 3000, height: 2000), anchor: anchor, visible: visible)
        try require(clipped == visible, "Oversized viewport was not clamped to its target display")
        for corner in corners + [anchor] {
            let preferred = ImageToolsPinPlacement.frame(size: size, anchor: corner, visible: visible)
            var occupied: [CGRect] = []
            for _ in 0..<8 {
                let next = ImageToolsPinPlacement.avoidingStack(preferred, visible: visible, occupied: occupied)
                try require(visible.contains(next) && next.size == size && !occupied.contains(next),
                            "Repeated cursor pins overlap exactly, resize, or leave the screen")
                occupied.append(next)
            }
            try require(abs(occupied[1].minX - preferred.minX) <= 18 && abs(occupied[1].minY - preferred.minY) <= 18,
                        "Second pin moved too far from the cursor")
        }
        try require(ImageToolsPinPlacement.avoidingStack(visible, visible: visible, occupied: [visible]) == visible,
                    "Full-screen pin collision search did not terminate in bounds")

        guard let screen = NSScreen.screens.first else { throw ImageToolsVerificationFailure(description: "No native test display") }
        let nativeVisible = screen.visibleFrame
        let trigger = CGPoint(x: nativeVisible.midX, y: nativeVisible.midY)
        let source = try solidImage(width: 400, height: 240)
        let coordinator = ImageToolsCoordinator()
        defer { coordinator.closeAll() }
        coordinator.pinImage(source, pixelScale: 2, recordsHistory: false, anchor: trigger)
        let pin = coordinator.verificationPins.first!
        let framedSize = CGSize(width: size.width + 2, height: size.height + 2)
        let expected = ImageToolsPinPlacement.frame(size: framedSize, anchor: trigger, visible: nativeVisible)
        let expectedImage = expected.insetBy(dx: 1, dy: 1)
        func sameNativeFrame(_ actual: CGRect, _ expected: CGRect) -> Bool {
            actual.size == expected.size && abs(actual.minX - expected.minX) <= 0.5 && abs(actual.minY - expected.minY) <= 0.5
        }
        try verifyImageHost(pin, inset: 1)
        try require(pin.verificationWholeImageFrame == expectedImage && nativeVisible.contains(pin.window!.frame)
                    && pin.verificationImageContentFrame?.size == size && pin.verificationImage === source,
                    "Actual cursor pin differs: frame=\(String(describing: pin.window?.frame)), expected=\(expected), content=\(String(describing: pin.verificationImageContentFrame)), same source=\(pin.verificationImage === source)")
        coordinator.pinImage(source, pixelScale: 2, recordsHistory: false, anchor: trigger)
        let second = coordinator.verificationPins.first { $0 !== pin }!
        try verifyImageHost(second, inset: 1)
        try require(second.window!.frame != pin.window!.frame && pin.verificationWholeImageFrame == expectedImage,
                    "New repeated pin covered the first or moved the existing pin")
        coordinator.togglePins()
        coordinator.pinImage(source, pixelScale: 2, recordsHistory: false, anchor: trigger)
        let third = coordinator.verificationPins.first { $0 !== pin && $0 !== second }!
        try verifyImageHost(third, inset: 1)
        try require(third.verificationWholeImageFrame == expectedImage && !pin.window!.isVisible && !second.window!.isVisible,
                    "Hidden pins reserve placement or become visible when pinning")
        coordinator.pinText("Synthetic cursor placement", recordsHistory: false, anchor: trigger, batchIndex: 1)
        let textPin = coordinator.verificationPins.first { $0.verificationTextView != nil }!
        let textExpected = ImageToolsPinPlacement.frame(size: textPin.window!.frame.size, anchor: trigger, visible: nativeVisible, batchIndex: 1)
        try require(sameNativeFrame(textPin.window!.frame, textExpected), "Text pin was placed before its final wrapping/layout size")
        let edge = CGPoint(x: nativeVisible.maxX - 1, y: nativeVisible.minY + 1)
        let edgePin = ImageToolsPinController(image: source, pixelScale: 2, anchor: edge)
        defer { edgePin.close() }
        try verifyImageHost(edgePin, inset: 1)
        try require(nativeVisible.contains(edgePin.window!.frame) && edgePin.verificationImageContentFrame?.size == size,
                    "Actual edge pin fell off-screen or changed screenshot dimensions")
        print("PASS: cursor-adjacent image/text pins, negative-origin display selection, edge clamping and five-item cascade preserve source size")
    }

    @MainActor private static func verifyCapturePinSize() throws {
        let source = try solidImage(width: 400, height: 240)
        let pin = ImageToolsPinController(image: source, pixelScale: 2)
        defer { pin.close() }
        try require(pin.verificationImageContentFrame?.size == CGSize(width: 200, height: 120),
                    "Retina capture pin must match its 200 × 120 point screen selection, not its 400 × 240 pixels")
        try require(pin.verificationImage === source, "Pin sizing must retain original export pixels")
        pin.verificationScale(1.5)
        try require(pin.verificationImageContentFrame?.size == CGSize(width: 300, height: 180), "Capture pin zoom changed its base scale")
        pin.verificationScale(1)
        try require(pin.verificationImageContentFrame?.size == CGSize(width: 200, height: 120), "Reset must restore the original screen size")
        let large = try solidImage(width: 1600, height: 1200)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let largePin = ImageToolsPinController(image: large, pixelScale: 2,
            anchor: CGPoint(x: visible.midX, y: visible.midY))
        let standardPin = ImageToolsPinController(image: source, pixelScale: 1)
        defer { largePin.close(); standardPin.close() }
        let expectedFit = min(1, (visible.width / 2 - 2) / 800, (visible.height / 2 - 2) / 600)
        try require(largePin.verificationImageContentFrame?.size == CGSize(width: 800 * expectedFit, height: 600 * expectedFit),
                    "Large captures must initially fit within half the display width and height")
        try verifyImageHost(largePin, inset: 1)
        try require(standardPin.verificationImageContentFrame?.size == CGSize(width: 400, height: 240),
                    "Standard-density captures must retain their screen size")
        print("PASS: 1x/2x capture pin size, large capture size, original export pixels, zoom and reset")
    }

    @MainActor private static func verifyWholeImagePinGeometry() throws {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let source = try solidImage(width: 800, height: 18000)
        let pin = ImageToolsPinController(image: source, pixelScale: 2,
            anchor: CGPoint(x: visible.midX, y: visible.midY))
        defer { pin.close() }
        guard let window = pin.window, let first = pin.verificationWholeImageFrame else {
            throw ImageToolsVerificationFailure(description: "Missing whole-image pin")
        }
        let initialScale = pin.verificationZoom
        try require(initialScale < 0.2 && initialScale > 0 && visible.contains(window.frame)
                    && window.frame.width <= visible.width / 2 + 1 && window.frame.height <= visible.height / 2 + 1
                    && abs(first.width / first.height - 800.0 / 18000.0) < 0.000001
                    && !pin.verificationImageUsesScrollView,
                    "Retina long capture was not initially fitted as a complete proportional image")
        try pin.verificationWheel(8, precise: true)
        try require(pin.verificationZoom > initialScale && pin.verificationZoom < initialScale * 1.1,
                    "First two-finger zoom jumps to the old 20 percent floor")
        let beforePinch = pin.verificationZoom
        pin.verificationPinch(1.2)
        try require(abs(pin.verificationZoom / beforePinch - 1.2) < 0.000001,
                    "Native pinch magnification was not applied to the whole image")
        pin.verificationScale(1)
        guard let full = pin.verificationWholeImageFrame else { throw ImageToolsVerificationFailure(description: "Lost logical image") }
        let frames = NSScreen.screens.map(\.visibleFrame)
        let desktop = frames.reduce(CGRect.null) { $0.union($1) }.integral
        try require(full.size == CGSize(width: 400, height: 9000) && desktop.contains(window.frame)
                    && window.frame.height < full.height && !window.hasShadow,
                    "Readable-size pin allocated an unbounded window or changed its original aspect ratio")
        let beforeSelection = full
        pin.verificationSelect()
        try require(pin.verificationWholeImageFrame == beforeSelection,
                    "Showing the detached toolbar resizes the complete image")
        try pin.verificationDrag(dx: 0, dy: visible.minY + 12 - full.minY)
        guard let bottom = pin.verificationWholeImageFrame else { throw ImageToolsVerificationFailure(description: "Drag lost image") }
        try require(abs(bottom.minY - visible.minY - 12) < 0.1 && bottom.size == full.size,
                    "Dragging the complete long image cannot reach its last rows")
        try pin.verificationDrag(dx: 0, dy: visible.maxY - 12 - bottom.maxY)
        guard let top = pin.verificationWholeImageFrame else { throw ImageToolsVerificationFailure(description: "Drag lost image") }
        try require(abs(top.maxY - visible.maxY + 12) < 0.1 && top.size == full.size
                    && pin.verificationImage === source && pin.verificationImage?.height == 18000,
                    "Dragging cannot return to the first rows or changes export pixels")
        print("PASS: Retina long pins fit completely, retain aspect ratio, zoom smoothly below 20 percent, keep bounded hosts and reach both image ends")
    }

    @MainActor private static func verifyExternalPinWindowMovement() throws {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let source = try solidImage(width: 400, height: 240)
        let pin = ImageToolsPinController(image: source, pixelScale: 2,
            anchor: CGPoint(x: visible.midX - 120, y: visible.midY + 100))
        defer { pin.close() }
        guard let window = pin.window, let original = pin.verificationWholeImageFrame else {
            throw ImageToolsVerificationFailure(description: "Missing external-movement fixture")
        }
        let host = window.frame
        window.setFrameOrigin(CGPoint(x: host.minX + 24, y: host.minY - 18))
        // Let native move/backing notifications settle; no pointer events are posted.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        let expected = original.offsetBy(dx: window.frame.minX - host.minX, dy: window.frame.minY - host.minY)
        try require(pin.verificationWholeImageFrame == expected && expected != original,
                    "Native panel movement did not translate the logical whole image")
        let movedHost = window.frame
        pin.verificationSelect()
        try require(pin.verificationWholeImageFrame == expected && window.frame == movedHost,
                    "Selection jumps a natively moved pin back to its old position")
        pin.verificationPinch(1.25)
        pin.verificationPinch(1 / 1.25)
        guard let restored = pin.verificationWholeImageFrame else {
            throw ImageToolsVerificationFailure(description: "Zoom lost a natively moved pin")
        }
        try require(abs(restored.midX - expected.midX) < 0.5 && abs(restored.midY - expected.midY) < 0.5
                    && restored.size == expected.size && pin.verificationImage === source,
                    "Zoom after native panel movement returns to the old origin or changes source pixels")
        print("PASS: native panel movement translates whole-image geometry, and subsequent selection/zoom retain the moved position")
    }

    @MainActor private static func verifyClipboardPinSize() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = try solidImage(width: 400, height: 240)
        for sourceScale: CGFloat in [1, 2] {
            // Both ordinary captures and trimmed subject images share the completion/copy route.
            for image in [source, source.cropping(to: CGRect(x: 20, y: 20, width: 120, height: 80))!] {
                try ImageToolsUI.copyPNG(image, pixelScale: sourceScale, to: board)
                let coordinator = ImageToolsCoordinator()
                coordinator.pinClipboard(from: board)
                defer { coordinator.closeAll() }
                let pin = coordinator.verificationPins.first
                let expected = CGSize(width: CGFloat(image.width) / sourceScale, height: CGFloat(image.height) / sourceScale)
                try require(pin?.verificationImageContentFrame?.size == expected,
                            "Complete screenshot → clipboard → pin lost the original screen size at \(sourceScale)x")
                try require(pin?.verificationImage?.width == image.width && pin?.verificationImage?.height == image.height,
                            "Clipboard pin must retain full-resolution export pixels")
                guard let png = board.data(forType: .png), let decoded = NSImage(data: png) else {
                    throw ImageToolsVerificationFailure(description: "Clipboard PNG is unreadable")
                }
                try require(abs(decoded.size.width - expected.width) < 0.1 && abs(decoded.size.height - expected.height) < 0.1,
                            "PNG must retain logical size for other apps")
            }
        }
        // External screenshot apps provide PNG resolution metadata without our private pasteboard type.
        board.clearContents()
        board.setData(try ImageToolsUI.png(source, pixelScale: 2), forType: .png)
        let external = ImageToolsCoordinator()
        defer { external.closeAll() }
        external.pinClipboard(from: board)
        try require(external.verificationPins.first?.verificationImageContentFrame?.size == CGSize(width: 200, height: 120),
                    "Clipboard pin ignored an external image's logical size")
        print("PASS: complete screenshot/trimmed subject → isolated clipboard → pin at 1x/2x, full export pixels and external PNG metadata")
    }

    @MainActor private static func verifyPinOutsideAnnotations() throws {
        let source = try solidImage(width: 260, height: 180)
        let pin = ImageToolsPinController(image: source, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
        defer { pin.close() }
        guard let editor = pin.verificationPrepareEditor(), let root = pin.window?.contentView else {
            throw ImageToolsVerificationFailure(description: "Missing pin annotation workspace")
        }
        let canvas = editor.canvas
        let blank = CGPoint(x: -40, y: -40)
        try require(root.hitTest(root.convert(blank, from: canvas)) === canvas,
                    "Blank pin annotation space must receive drawing input")
        let original = try canvas.renderedImage()
        try require(original.width == source.width && original.height == source.height, "Blank margins must not enlarge unmarked exports")
        func drawOutside() {
            if editor.controls.activeTool != .rectangle { editor.controls.choose(tool: .rectangle) }
            canvas.tool = .rectangle; canvas.isDrawingEnabled = true
            canvas.annotationColor = .systemRed; canvas.annotationWidth = 4
            gesture(canvas, points: [blank, CGPoint(x: -15, y: -15)])
        }
        drawOutside()
        try require(canvas.annotations.first?.points.first == blank, "Pin annotation was clamped to the image")
        let expanded = try canvas.renderedImage()
        try require(expanded.width > source.width && expanded.height > source.height, "Pin outside marks were cropped on export")
        try require(same(rgba(expanded, x: 0, y: 0), [1, 1, 1, 1]), "Expanded pin margins must be opaque white")
        editor.setZoom(0.6)
        let zoomed = try canvas.renderedImage()
        try require(zoomed.width == expanded.width && zoomed.height == expanded.height, "Pinch must not change export bounds")
        canvas.undoAnnotation()
        let undone = try canvas.renderedImage()
        try require(undone.width == source.width && undone.height == source.height, "Undo must remove empty export margins")
        drawOutside()
        let appliedExport = try canvas.renderedImage()
        editor.complete()
        try require(!pin.verificationHasEditor && pin.verificationImage?.width == appliedExport.width
                    && pin.verificationImage?.height == appliedExport.height, "Completing must apply the entire expanded image to the pin")
        guard let frame = pin.verificationImageContentFrame else {
            throw ImageToolsVerificationFailure(description: "Completed pin has no image view")
        }
        try require(abs(frame.width / frame.height - CGFloat(appliedExport.width) / CGFloat(appliedExport.height)) < 0.01,
                    "Completed expanded pin is stretched into its old aspect ratio")
        let applied = pin.verificationImage!
        let reopened = pin.verificationPrepareEditor()!
        reopened.canvas.tool = .rectangle
        gesture(reopened.canvas, points: [CGPoint(x: -50, y: -50), CGPoint(x: -20, y: -20)])
        reopened.onCancel?()
        try require(pin.verificationImage === applied && !pin.verificationHasEditor, "Cancel must discard new outside marks and preserve the previous pin")
        print("PASS: actual pin blank-space annotation supports white auto-expansion, zoom, undo, apply with correct aspect ratio and cancel")
    }

    @MainActor private static func verifyPinAnnotationViewport(outputDirectory: URL) throws {
        var issues: [String] = []
        for (width, height) in [(260, 180), (1200, 240), (700, 6000)] {
            let source = try solidImage(width: width, height: height)
            let pin = ImageToolsPinController(image: source)
            defer { pin.close() }
            let originalFrame = pin.window!.frame
            guard let editor = pin.verificationPrepareEditor(), let root = pin.window?.contentView else {
                throw ImageToolsVerificationFailure(description: "Missing actual pin annotation workspace")
            }
            let original = CGRect(x: 0, y: 0, width: width, height: height)
            let visibleImage = editor.canvas.convert(original, to: editor.scroll)
            if abs(visibleImage.midX - editor.scroll.bounds.midX) > 1 || abs(visibleImage.midY - editor.scroll.bounds.midY) > 1 {
                issues.append("\(width)x\(height) does not open in the horizontal and vertical center")
            }
            if !editor.scroll.bounds.insetBy(dx: -1, dy: -1).contains(visibleImage) {
                issues.append("\(width)x\(height) initial fitting clips the image")
            }
            let event = PinAnnotationMagnifyEvent()
            let imageCenter = CGPoint(x: original.midX, y: original.midY)
            if root.hitTest(root.convert(imageCenter, from: editor.canvas)) !== editor.canvas {
                issues.append("Pin annotation image center does not route input to the canvas")
            }
            event.point = editor.canvas.convert(imageCenter, to: nil)
            let before = editor.scroll.magnification
            editor.canvas.magnify(with: event)
            if abs(editor.scroll.magnification - before * 1.25) > 0.001 { issues.append("Pin annotation canvas does not accept pinch-out") }
            event.amount = -0.2
            editor.canvas.magnify(with: event)
            if abs(editor.scroll.magnification - before) > 0.001 { issues.append("Pin annotation canvas does not accept pinch-in") }
            let blank = CGPoint(x: editor.scroll.bounds.minX + 10, y: editor.scroll.bounds.minY + 10)
            let rootPoint = root.convert(blank, from: editor.scroll)
            guard let receiver = root.hitTest(rootPoint) else { throw ImageToolsVerificationFailure(description: "Blank viewport has no input receiver") }
            event.amount = 0.25; event.point = editor.scroll.convert(blank, to: nil)
            receiver.magnify(with: event)
            if abs(editor.scroll.magnification - before * 1.25) > 0.001 { issues.append("Pin annotation blank space does not accept pinch-out") }
            let exported = try editor.canvas.renderedImage()
            try require(exported.width == width && exported.height == height, "Pinch changed original export dimensions")
            editor.fitImage()
            if height == 6000 { try cachePreview(editor, output: outputDirectory.appendingPathComponent("pin-annotation-centered-preview.png")) }
            editor.onCancel?()
            try require(pin.window?.frame == originalFrame && pin.verificationImage === source,
                        "Cancel must restore the original pin after pinch")
        }
        try require(issues.isEmpty, issues.joined(separator: "; "))
        print("PASS: actual pin annotation windows center small, wide and tall images; image and blank-space pinch-in/out preserve export size and cancel restoration")
    }

    @MainActor private static func verifyAnnotationToolbarConsistency() throws {
        let imagePin = ImageToolsPinController(image: try solidImage())
        let textPin = ImageToolsPinController(text: "颜色与标注测试")
        defer { imagePin.close(); textPin.close() }
        guard let imageEntry = imagePin.verificationHUDButtons.first(where: { $0.title == "标注" }),
              let textEntry = textPin.verificationHUDButtons.first(where: { $0.title == "编辑文字" }) else {
            throw ImageToolsVerificationFailure(description: "Missing annotation entry")
        }
        try require(imageEntry.image?.tiffRepresentation == textEntry.image?.tiffRepresentation,
                    "Image and text pin annotation entries use different glyphs")
        textPin.verificationEditing(true)
        let textActions = textPin.verificationHUDButtons
        try require(Array(textActions.suffix(2)).map(\.title) == ["关闭贴图", "完成编辑"],
                    "Text pin completion must follow other actions at the right end")
        try require(textActions.last?.isPrimaryAction == true && textActions.last?.imagePosition == .imageOnly,
                    "Text editing completion must share the emphasized icon style")
        guard let editor = imagePin.verificationPrepareEditor(),
              let toolbar = editor.subviews.compactMap({ $0 as? SelectionToolbar }).first else {
            throw ImageToolsVerificationFailure(description: "Missing pin annotation toolbar")
        }
        let actions = toolbar.rows.first?.compactMap { $0 as? SelectionButton } ?? []
        try require(Array(actions.suffix(2)).map(\.title) == ["取消", "完成"] && actions.last?.isPrimaryAction == true,
                    "Image pin annotation completion must follow cancel at the right end")
        try require(actions.allSatisfy { abs($0.frame.midY - (actions.first?.frame.midY ?? 0)) < 0.5 },
                    "Default pin annotation width must fit the main actions without wrapping")
        for width in [CGFloat(320), 740, 1100] {
            editor.frame.size.width = width
            editor.needsLayout = true; editor.layoutSubtreeIfNeeded()
            guard let cancel = actions.dropLast().last, let finish = actions.last else {
                throw ImageToolsVerificationFailure(description: "Missing completion pair")
            }
            try require(abs(cancel.frame.midY - finish.frame.midY) < 0.5
                        && abs(finish.frame.maxX - toolbar.frame.width + 8) < 0.5
                        && abs(finish.frame.maxY - (actions.first?.frame.maxY ?? 0)) < 0.5,
                        "Cancel and completion split or moved away from the right edge at width \(width)")
        }
        print("PASS: image/text pin annotation entries share glyphs and keep emphasized completion together at the right end, including narrow toolbars")
    }

    @MainActor private static func verifyCopyButtonStates() throws {
        let source = try solidImage()
        let imagePin = ImageToolsPinController(image: source)
        let textPin = ImageToolsPinController(text: "合成文字贴图")
        let editor = ImageToolsEditorController(image: source)
        let subject = SubjectSelectionController(image: source)
        let inline = InlineAnnotationView(image: source, completionHint: "完成标注")
        // Arrange a standalone inline workspace so its toolbar exposes the actual actions.
        inline.frame = CGRect(x: 0, y: 0, width: 900, height: 600); inline.layoutSubtreeIfNeeded()
        let inlineButtons = inline.subviews.compactMap { $0 as? SelectionToolbar }.flatMap { $0.rows.flatMap { $0 } }
            .compactMap { $0 as? SelectionButton }.filter { $0.title == "复制" }
        defer { imagePin.close(); textPin.close(); editor.close(); subject.close() }
        var contexts: [(String, [SelectionButton])] = [
            ("image pin", imagePin.verificationCopyButtons), ("text pin moving", textPin.verificationCopyButtons),
            ("standalone image editor", editor.verificationCopyButtons), ("inline annotation", inlineButtons),
            ("subject extraction preview", subject.window?.contentView.map { allButtons($0).compactMap { $0 as? SelectionButton }.filter { $0.title == "复制" } } ?? []),
            ("copy-and-close confirmation", [SelectionButton.confirmation(toolTip: "复制并关闭", action: {})])
        ]
        textPin.verificationEditing(true)
        contexts.append(("text pin editing", textPin.verificationCopyButtons))
        var failures: [String] = []
        for (name, buttons) in contexts {
            try require(buttons.count == 1, "Missing unique copy action in \(name)")
            let button = buttons[0]
            let originalAction = button.actionBlock
            let originallyEnabled = button.isEnabled
            button.isEnabled = true
            var clicks = 0
            // Exercise native button tracking without changing the user's clipboard.
            button.actionBlock = { clicks += 1 }
            for click in 1...3 {
                button.performClick(nil)
                if button.state != .off { failures.append("\(name) click \(click) retained state=\(button.state.rawValue)") }
            }
            button.actionBlock = originalAction
            button.isEnabled = originallyEnabled
            try require(clicks == 3, "Copy action must fire on every click in \(name)")
        }
        var writes = 0
        let ocr = ImageToolsOCRController(writeClipboard: { _ in writes += 1; return writes > 1 })
        defer { ocr.close() }
        ocr.complete("合成识别结果")
        ocr.verificationCopyButton.performClick(nil)
        if ocr.verificationCopyButton.state != .off { failures.append("OCR copy failure retained selected state") }
        ocr.verificationCopyButton.performClick(nil)
        if ocr.verificationCopyButton.state != .off { failures.append("OCR copy success retained selected state") }
        try require(writes == 2, "OCR copy must retry after clipboard failure")
        try require(failures.isEmpty, "Copy actions behave like toggles: " + failures.joined(separator: "; "))
        let toggle = SelectionButton("系统声音", symbol: "speaker.wave.2", action: {})
        toggle.setButtonType(.pushOnPushOff)
        toggle.performClick(nil)
        try require(toggle.state == .on, "Explicit toggle no longer retains selection")
        toggle.performClick(nil)
        try require(toggle.state == .off, "Explicit toggle no longer switches off")
        print("PASS: repeated copy stays momentary for image/text pins, text editing, both annotation editors, subject preview, confirmation and OCR failure/retry; explicit toggles still work")
    }

    @MainActor private static func verifyArrowTips(outputDirectory: URL) throws {
        let source = try solidImage()
        let tip = CGPoint(x: 130, y: 130)
        for width: CGFloat in [3, 6, 10, 18] {
            for direction in 0..<8 {
                let angle = CGFloat(direction) * .pi / 4
                let unit = CGPoint(x: cos(angle), y: sin(angle))
                let start = CGPoint(x: tip.x - unit.x * 80, y: tip.y - unit.y * 80)
                let canvas = ImageToolsCanvas(image: source)
                try canvas.verificationAdd(ImageToolsAnnotation(tool: .arrow,
                    points: [start, tip], color: .red, width: width))
                let image = try canvas.renderedImage()
                let bitmap = NSBitmapImageRep(cgImage: image)
                let radius = Int(width) + 3
                var protrusion: CGFloat = 0
                for y in 130 - radius...130 + radius {
                    for x in 130 - radius...130 + radius {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.redComponent > 0.75, color.greenComponent < 0.9 else { continue }
                        let forward = (CGFloat(x) + 0.5 - tip.x) * unit.x + (CGFloat(y) + 0.5 - tip.y) * unit.y
                        protrusion = max(protrusion, forward)
                    }
                }
                if protrusion > 1 {
                    try ImageToolsUI.png(image).write(to: outputDirectory.appendingPathComponent("arrow-tip-probe.png"), options: .atomic)
                }
                try require(protrusion <= 1,
                    "Arrow projects \(protrusion) pixels beyond its endpoint (direction \(direction), width \(width)); raster saved as arrow-tip-probe.png")
                let shaft = try rgba(image, x: Int(start.x + unit.x * 30), y: Int(start.y + unit.y * 30))
                try require(shaft[0] > 0.8 && shaft[1] < 0.6, "Arrow shaft disappeared before its head")
            }
        }
        for length: CGFloat in [0, 0.1, 2, 4] {
            for direction in 0..<8 {
                let angle = CGFloat(direction) * .pi / 4
                let unit = CGPoint(x: cos(angle), y: sin(angle))
                let canvas = ImageToolsCanvas(image: source)
                try canvas.verificationAdd(ImageToolsAnnotation(tool: .arrow,
                    points: [CGPoint(x: tip.x - unit.x * length, y: tip.y - unit.y * length), tip],
                    color: .red, width: 18))
                let bitmap = NSBitmapImageRep(cgImage: try canvas.renderedImage())
                var colored = 0
                for y in 105...155 {
                    for x in 105...155 {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              color.redComponent > 0.75, color.greenComponent < 0.9 else { continue }
                        colored += 1
                        let forward = (CGFloat(x) + 0.5 - tip.x) * unit.x + (CGFloat(y) + 0.5 - tip.y) * unit.y
                        try require(forward <= 1, "Very short arrow produces an endpoint protrusion")
                    }
                }
                if length < 0.5 { try require(colored == 0, "Zero-length arrow produced a stray mark") }
            }
        }
        print("PASS: arrow tips stop at their endpoint for eight directions, four widths and very short strokes")
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType, on canvas: ImageToolsCanvas,
                                         at point: CGPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    @MainActor private static func canvasWindow(_ canvas: ImageToolsCanvas) -> NSWindow {
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return window
    }

    private static func inkBounds(_ image: CGImage) throws -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        try require(maxX >= minX && maxY >= minY, "Annotation rendered no visible pixels")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor private static func verifyIndependentToolSizes() throws {
        let source = try solidImage()
        var textImages: [CGImage] = []
        for width: CGFloat in [3, 18] {
            let canvas = ImageToolsCanvas(image: source)
            let window = canvasWindow(canvas)
            canvas.annotationWidth = width
            canvas.annotationFontSize = 20
            canvas.verificationWriteText("Patch", at: CGPoint(x: 30, y: 30))
            try require(canvas.annotations.last?.fontSize == 20, "Text did not preserve the selected font size")
            let image = try canvas.renderedImage()
            canvas.annotationFontSize = 64
            let rerendered = try canvas.renderedImage()
            try require(try ImageToolsUI.png(image) == ImageToolsUI.png(rerendered), "Changing current font size resized an existing text annotation")
            textImages.append(image)
            withExtendedLifetime(window) {}
        }
        try require(try ImageToolsUI.png(textImages[0]) == ImageToolsUI.png(textImages[1]), "Text size still changes with annotation line width")
        let largerText = ImageToolsCanvas(image: source)
        largerText.annotationFontSize = 40
        largerText.verificationWriteText("Patch", at: CGPoint(x: 30, y: 30))
        let textSmallBounds = try inkBounds(textImages[0])
        let textLargeBounds = try inkBounds(largerText.renderedImage())
        try require(textLargeBounds.width > textSmallBounds.width * 1.7 && textLargeBounds.height > textSmallBounds.height * 1.7,
                    "Changing font size did not scale actual text pixels")
        print("PASS: text font size is independent of line width and retained per annotation")

        var numberImages: [CGImage] = []
        for width: CGFloat in [3, 18] {
            let canvas = ImageToolsCanvas(image: source)
            let window = canvasWindow(canvas)
            canvas.tool = .number
            canvas.annotationWidth = width
            canvas.annotationNumberSize = 36
            canvas.mouseDown(with: mouse(.leftMouseDown, on: canvas, at: CGPoint(x: 130, y: 130)))
            try require(canvas.annotations.last?.numberSize == 36, "Number did not preserve its selected diameter")
            let image = try canvas.renderedImage()
            canvas.annotationNumberSize = 72
            try require(try ImageToolsUI.png(image) == ImageToolsUI.png(canvas.renderedImage()), "Changing current number size resized an existing annotation")
            numberImages.append(image)
            withExtendedLifetime(window) {}
        }
        try require(try ImageToolsUI.png(numberImages[0]) == ImageToolsUI.png(numberImages[1]), "Number diameter still changes with annotation line width")
        let largerNumber = ImageToolsCanvas(image: source)
        let numberWindow = canvasWindow(largerNumber)
        largerNumber.tool = .number
        largerNumber.annotationNumberSize = 72
        largerNumber.mouseDown(with: mouse(.leftMouseDown, on: largerNumber, at: CGPoint(x: 130, y: 130)))
        let numberSmallBounds = try inkBounds(numberImages[0])
        let numberLargeBounds = try inkBounds(largerNumber.renderedImage())
        try require(abs(numberSmallBounds.width - 36) <= 2 && abs(numberLargeBounds.width - 72) <= 2,
                    "Number size does not control the circle's rendered pixel diameter")
        withExtendedLifetime(numberWindow) {}
        print("PASS: sequence-number diameter is independent of line width and retained per annotation")

        guard let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate mosaic-size fixture")
        }
        for y in 0..<128 {
            for x in 0..<128 {
                context.setFillColor(CGColor(red: CGFloat(x) / 128, green: CGFloat(y) / 128, blue: 0.3, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let gradient = context.makeImage() else { throw ImageToolsVerificationFailure(description: "Cannot make mosaic-size fixture") }
        var mosaicImages: [CGImage] = []
        for (width, block): (CGFloat, CGFloat) in [(3, 8), (18, 8), (3, 24)] {
            let canvas = ImageToolsCanvas(image: gradient)
            let window = canvasWindow(canvas)
            canvas.tool = .mosaic
            canvas.annotationWidth = width
            canvas.mosaicBlockSize = block
            canvas.mouseDown(with: mouse(.leftMouseDown, on: canvas, at: CGPoint(x: 16, y: 16)))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, on: canvas, at: CGPoint(x: 80, y: 80)))
            canvas.mouseUp(with: mouse(.leftMouseUp, on: canvas, at: CGPoint(x: 80, y: 80)))
            mosaicImages.append(try canvas.renderedImage())
            withExtendedLifetime(window) {}
        }
        try require(try ImageToolsUI.png(mosaicImages[0]) == ImageToolsUI.png(mosaicImages[1]), "Mosaic block size still changes with annotation line width")
        let smallLeft = try rgba(mosaicImages[0], x: 23, y: 20)
        let smallRight = try rgba(mosaicImages[0], x: 24, y: 20)
        let largeLeft = try rgba(mosaicImages[2], x: 23, y: 20)
        let largeRight = try rgba(mosaicImages[2], x: 24, y: 20)
        try require(!same(smallLeft, smallRight) && same(largeLeft, largeRight), "Mosaic block setting did not move actual raster block boundaries")
        let largeBoundary = try rgba(mosaicImages[2], x: 40, y: 20)
        try require(!same(largeRight, largeBoundary), "Large mosaic blocks did not end at the selected size")
        print("PASS: mosaic block size is independent of line width and changes raster block boundaries")
    }

    @MainActor private static func gesture(_ canvas: ImageToolsCanvas, points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        canvas.mouseDown(with: mouse(.leftMouseDown, on: canvas, at: first))
        for point in points.dropFirst() { canvas.mouseDragged(with: mouse(.leftMouseDragged, on: canvas, at: point)) }
        canvas.mouseUp(with: mouse(.leftMouseUp, on: canvas, at: last))
    }

    @MainActor private static func select(_ canvas: ImageToolsCanvas, at point: CGPoint) {
        canvas.deselectAnnotation()
        gesture(canvas, points: [point])
    }

    @MainActor private static func replaceInlineText(_ canvas: ImageToolsCanvas, with text: String) throws {
        guard let input = canvas.subviews.compactMap({ $0 as? NSTextField }).first else {
            throw ImageToolsVerificationFailure(description: "Expected an inline text editor")
        }
        input.stringValue = text
        input.currentEditor()?.string = text
        canvas.finishTextEditing()
    }

    @MainActor private static func verifyObjectEditing() throws {
        let source = try solidImage()
        let definitions: [(ImageToolsTool, [CGPoint], CGPoint)] = [
            (.arrow, [CGPoint(x: 35, y: 60), CGPoint(x: 120, y: 100)], CGPoint(x: 77, y: 80)),
            (.rectangle, [CGPoint(x: 35, y: 40), CGPoint(x: 110, y: 100)], CGPoint(x: 72, y: 40)),
            (.ellipse, [CGPoint(x: 35, y: 40), CGPoint(x: 110, y: 100)], CGPoint(x: 72, y: 40)),
            (.pen, [CGPoint(x: 35, y: 70), CGPoint(x: 65, y: 35), CGPoint(x: 105, y: 90)], CGPoint(x: 65, y: 35))
        ]
        for (tool, points, hit) in definitions {
            let canvas = ImageToolsCanvas(image: source)
            let window = canvasWindow(canvas)
            canvas.tool = tool
            gesture(canvas, points: points)
            try require(canvas.annotations.count == 1 && canvas.canUndo, "\(tool.rawValue) creation is not undoable")
            canvas.isDrawingEnabled = false
            canvas.deselectAnnotation()
            let original = canvas.annotations[0]
            let originalImage = try canvas.renderedImage()
            try require(canvas.annotationContains(hit) && !canvas.annotationContains(CGPoint(x: 235, y: 235)),
                        "\(tool.rawValue) hit test did not distinguish ink from empty canvas")
            var selectedStyle: ImageToolsAnnotation?
            canvas.onAnnotationSelectionChange = { selectedStyle = $0 }
            canvas.annotationWidth = 99
            canvas.annotationColor = .green
            select(canvas, at: hit)
            try require(selectedStyle?.tool == tool && selectedStyle?.width == original.width,
                        "Selection callback did not report the object's saved style")
            try require(canvas.annotationWidth == 99 && canvas.annotationColor.isEqual(NSColor.green),
                        "Selection unexpectedly modified drawing defaults")
            let withSelection = try canvas.renderedImage()
            canvas.deselectAnnotation()
            try require(try ImageToolsUI.png(withSelection) == ImageToolsUI.png(canvas.renderedImage()),
                        "Selection decorations leaked into exported pixels")
            select(canvas, at: hit)
            gesture(canvas, points: [hit, CGPoint(x: hit.x + 25, y: hit.y + 20)])
            let moved = canvas.annotations[0]
            try require(zip(original.points, moved.points).allSatisfy { a, b in abs(b.x - a.x - 25) < 0.01 && abs(b.y - a.y - 20) < 0.01 },
                        "\(tool.rawValue) object did not move as a whole")
            try require(try ImageToolsUI.png(originalImage) != ImageToolsUI.png(canvas.renderedImage()), "Moving an object did not change raster pixels")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(originalImage) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore the moved object's pixels")
            let control = tool == .arrow ? original.points.last! : CGPoint(x: original.rect.maxX, y: original.rect.maxY)
            try require(canvas.annotationContains(control), "Selected object's control point cannot receive clicks")
            gesture(canvas, points: [control, CGPoint(x: control.x + 20, y: control.y + 15)])
            if tool == .arrow {
                try require(canvas.annotations[0].points.first == original.points.first
                    && canvas.annotations[0].points.last == CGPoint(x: control.x + 20, y: control.y + 15), "Arrow endpoint control did not adjust only its endpoint")
            } else {
                try require(abs(canvas.annotations[0].rect.width - original.rect.width - 20) < 0.01
                    && abs(canvas.annotations[0].rect.height - original.rect.height - 15) < 0.01, "\(tool.rawValue) corner control did not resize its geometry")
            }
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(originalImage) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore resized geometry")
            canvas.updateSelectedAnnotation(color: .blue, width: 12)
            try require(canvas.selectedAnnotation?.width == 12 && canvas.selectedAnnotation?.color.isEqual(NSColor.blue) == true,
                        "Selected-object style edit was not applied")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(originalImage) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore object styling")
            let deletion = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
            canvas.keyDown(with: deletion)
            try require(canvas.annotations.isEmpty && canvas.canUndo, "Delete did not remove the selected object with undo retained")
            canvas.undoAnnotation()
            try require(try ImageToolsUI.png(originalImage) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore deleted object pixels")
            try require(canvas.cancelAnnotationEditing() && !canvas.cancelAnnotationEditing(), "Esc priority did not consume selection exactly once")
            canvas.clearAnnotations()
            try require(!canvas.canUndo && canvas.selectedAnnotation == nil && !canvas.cancelAnnotationEditing(), "Clearing annotations retained stale history or selection")
            withExtendedLifetime(window) {}
        }
        print("PASS: arrows, rectangles, ellipses and pens support ink hits, move, controls, style edits, Delete and undo")

        let text = ImageToolsCanvas(image: source)
        let textWindow = canvasWindow(text)
        text.tool = .text
        text.mouseDown(with: mouse(.leftMouseDown, on: text, at: CGPoint(x: 30, y: 30)))
        try replaceInlineText(text, with: "Original")
        let before = try text.renderedImage()
        let textOrigin = text.annotations[0].points[0]
        text.isDrawingEnabled = false
        select(text, at: CGPoint(x: 50, y: 42))
        gesture(text, points: [CGPoint(x: 50, y: 42), CGPoint(x: 70, y: 62)])
        try require(text.annotations[0].points[0] == CGPoint(x: textOrigin.x + 20, y: textOrigin.y + 20), "Text did not move")
        text.undoAnnotation()
        text.mouseDown(with: mouse(.leftMouseDown, on: text, at: CGPoint(x: 50, y: 42), clickCount: 2))
        let editing = text.subviews.compactMap({ $0 as? NSTextField }).first
        try require(editing?.stringValue == "Original", "Double-click did not load the existing text")
        try replaceInlineText(text, with: "Edited")
        try require(text.annotations.count == 1 && text.annotations[0].text == "Edited", "Editing duplicated text instead of replacing it")
        text.undoAnnotation()
        try require(try ImageToolsUI.png(before) == ImageToolsUI.png(text.renderedImage()), "Undo did not restore original text")
        text.updateSelectedAnnotation(fontSize: 48)
        try require(text.selectedAnnotation?.fontSize == 48, "Existing text font size was not editable")
        text.undoAnnotation()
        text.mouseDown(with: mouse(.leftMouseDown, on: text, at: CGPoint(x: 50, y: 42), clickCount: 2))
        try require(text.cancelAnnotationEditing() && text.selectedAnnotation != nil, "Esc did not cancel text editing before object selection")
        try require(try ImageToolsUI.png(before) == ImageToolsUI.png(text.renderedImage()), "Cancelled text editing changed exported pixels")
        text.deleteSelectedAnnotation()
        text.undoAnnotation()
        try require(try ImageToolsUI.png(before) == ImageToolsUI.png(text.renderedImage()), "Text deletion was not reversible")
        withExtendedLifetime(textWindow) {}

        let number = ImageToolsCanvas(image: source)
        let numberWindow = canvasWindow(number)
        number.tool = .number
        gesture(number, points: [CGPoint(x: 130, y: 130)])
        let numberBefore = try number.renderedImage()
        number.isDrawingEnabled = false
        select(number, at: CGPoint(x: 130, y: 130))
        gesture(number, points: [CGPoint(x: 130, y: 130), CGPoint(x: 150, y: 145)])
        try require(number.annotations[0].points[0] == CGPoint(x: 150, y: 145), "Sequence number did not move")
        number.undoAnnotation()
        number.updateSelectedAnnotation(numberSize: 72)
        try require(number.selectedAnnotation?.numberSize == 72, "Existing sequence-number size was not editable")
        number.undoAnnotation()
        try require(try ImageToolsUI.png(numberBefore) == ImageToolsUI.png(number.renderedImage()), "Undo did not restore sequence-number pixels")
        withExtendedLifetime(numberWindow) {}
        print("PASS: text supports double-click editing and cancellation; text and numbers support move and size-edit undo")
    }

    @MainActor private static func verifyMosaicEditing() throws {
        let source = try solidImage()
        let canvas = ImageToolsCanvas(image: source)
        let window = canvasWindow(canvas)
        var failures = 0
        canvas.onError = { _ in failures += 1 }
        canvas.tool = .pen
        canvas.annotationWidth = 12
        canvas.annotationColor = .red
        gesture(canvas, points: [CGPoint(x: 15, y: 50), CGPoint(x: 100, y: 50)])
        canvas.deselectAnnotation()
        canvas.tool = .mosaic
        canvas.mosaicBlockSize = 8
        gesture(canvas, points: [CGPoint(x: 30, y: 30), CGPoint(x: 110, y: 80)])
        try require(canvas.annotations.count == 2 && canvas.annotations[1].mosaicBlockSize == 8, "Mosaic creation did not retain its block size")
        let original = try canvas.renderedImage()
        let red = try rgba(original, x: 50, y: 50)
        try require(red[0] > 0.9 && red[1] < 0.2, "Mosaic did not sample the lower red stroke")
        canvas.isDrawingEnabled = false
        select(canvas, at: CGPoint(x: 20, y: 50))
        canvas.updateSelectedAnnotation(color: .blue)
        let blueImage = try canvas.renderedImage()
        let blue = try rgba(blueImage, x: 50, y: 50)
        try require(blue[2] > 0.9 && blue[0] < 0.2, "Editing a lower annotation left a stale mosaic patch")
        gesture(canvas, points: [CGPoint(x: 24, y: 50), CGPoint(x: 34, y: 90)])
        let uncovered = try rgba(canvas.renderedImage(), x: 50, y: 50)
        try require(uncovered[0] > 0.95 && uncovered[1] > 0.95 && uncovered[2] > 0.95, "Moving a lower annotation did not update the upper mosaic")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(blueImage) == ImageToolsUI.png(canvas.renderedImage()), "Undo of lower movement did not rebuild mosaic consistently")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage()), "Undo of lower style did not rebuild mosaic consistently")

        select(canvas, at: CGPoint(x: 60, y: 65))
        gesture(canvas, points: [CGPoint(x: 60, y: 65), CGPoint(x: 75, y: 85)])
        try require(canvas.selectedAnnotation?.rect == CGRect(x: 45, y: 50, width: 80, height: 50), "Mosaic could not move as an object")
        let moved = try canvas.renderedImage()
        canvas.updateSelectedAnnotation(mosaicBlockSize: 32)
        let largerBlocks = try canvas.renderedImage()
        let lower = ImageToolsCanvas(image: source)
        try lower.verificationAdd(canvas.annotations[0])
        let lowerBitmap = NSBitmapImageRep(cgImage: try lower.renderedImage())
        var average = [CGFloat](repeating: 0, count: 4)
        for y in 50..<82 {
            for x in 45..<77 {
                guard let c = lowerBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                for (index, channel) in [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].enumerated() {
                    average[index] += channel / 1024
                }
            }
        }
        let actual = try rgba(largerBlocks, x: 50, y: 60)
        try require(same(average, actual) && actual[3] > 0.99, "Moved mosaic block does not average its current source and lower layers opaquely")
        gesture(canvas, points: [CGPoint(x: 125, y: 100), CGPoint(x: 145, y: 115)])
        try require(canvas.selectedAnnotation?.rect == CGRect(x: 45, y: 50, width: 100, height: 65), "Mosaic bounding control did not resize its area")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(largerBlocks) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore mosaic resize")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(moved) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore mosaic block size")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage()), "Undo did not restore mosaic position")
        canvas.updateSelectedAnnotation(mosaicBlockSize: .nan)
        try require(failures == 1 && canvas.selectedAnnotation?.mosaicBlockSize == 8
            && (try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage())), "Failed mosaic edit lost the previous valid raster")
        select(canvas, at: CGPoint(x: 20, y: 50))
        canvas.deleteSelectedAnnotation()
        let removedLower = try rgba(canvas.renderedImage(), x: 50, y: 50)
        try require(removedLower[0] > 0.95 && removedLower[1] > 0.95, "Deleting a lower object left stale mosaic pixels")
        canvas.undoAnnotation()
        try require(try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage()), "Undo of lower deletion did not restore protected pixels")
        try require(!canvas.verificationHistoryRetainsRaster, "Undo history retained raster patches")
        withExtendedLifetime(window) {}
        print("PASS: mosaic move, resize, block edits, lower-layer edits/deletion and undo rebuild opaque patches transactionally")
    }

    @MainActor private static func verifyLegacyEditorBinding() throws {
        let source = try solidImage()
        let editor = ImageToolsEditorController(image: source, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        let canvas = editor.verificationCanvas
        canvas.annotationColor = .systemRed
        canvas.tool = .rectangle
        gesture(canvas, points: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 120)])
        let originalWidth = canvas.annotations[0].width
        let original = try canvas.renderedImage()
        editor.verificationChangeTool(.ellipse)
        editor.verificationChangeColor(.systemBlue)
        select(canvas, at: CGPoint(x: 90, y: 40))
        try require(editor.verificationToolTitle == "方框" && editor.verificationColor.isEqual(NSColor.systemRed)
            && editor.verificationWidthIndex == 1,
            "Legacy editor did not synchronize controls and drawing defaults to the selected object")
        editor.verificationChangeColor(.systemBlue)
        try require(canvas.selectedAnnotation?.color.isEqual(NSColor.systemBlue) == true && editor.verificationUndoEnabled,
                    "Legacy color action did not edit the selected object with undo enabled")
        editor.verificationUndo()
        try require(try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage()), "Legacy color undo did not restore object pixels")
        try require(editor.verificationColor.isEqual(NSColor.systemRed), "Legacy controls did not follow undo restoration")
        editor.verificationChangeWidth(2)
        try require(canvas.selectedAnnotation?.width == 5 / editor.verificationMagnification && editor.verificationWidthIndex == 2,
                    "Legacy width action did not update the selected vector object")
        editor.verificationUndo()
        try require(canvas.selectedAnnotation?.width == originalWidth && editor.verificationWidthIndex == 1,
                    "Legacy width undo did not synchronize restored controls")
        editor.verificationChangeTool(.pen)
        try require(canvas.selectedAnnotation == nil && canvas.tool == .pen && canvas.isDrawingEnabled,
                    "Changing legacy tools did not deselect the old object and enable new drawing")
        try require(try ImageToolsUI.png(original) == ImageToolsUI.png(canvas.renderedImage()), "Changing tools mutated the existing object")

        for tool in [ImageToolsTool.text, .number, .mosaic] {
            let controller = ImageToolsEditorController(image: source, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let objectCanvas = controller.verificationCanvas
            controller.verificationChangeTool(tool)
            if tool == .text {
                objectCanvas.mouseDown(with: mouse(.leftMouseDown, on: objectCanvas, at: CGPoint(x: 30, y: 30)))
                try replaceInlineText(objectCanvas, with: "Legacy")
            } else if tool == .number {
                gesture(objectCanvas, points: [CGPoint(x: 130, y: 130)])
            } else {
                gesture(objectCanvas, points: [CGPoint(x: 40, y: 40), CGPoint(x: 130, y: 120)])
            }
            let before = objectCanvas.selectedAnnotation!
            let beforeImage = try objectCanvas.renderedImage()
            controller.verificationChangeWidth(3)
            let after = objectCanvas.selectedAnnotation!
            switch tool {
            case .text:
                try require(after.fontSize == 32 / controller.verificationMagnification && after.width == before.width, "Legacy text menu changed line width instead of font size")
            case .number:
                try require(after.numberSize == 40 / controller.verificationMagnification && after.width == before.width, "Legacy sequence menu changed line width instead of circle size")
            case .mosaic:
                try require(after.mosaicBlockSize == 20 / controller.verificationMagnification && after.width == before.width, "Legacy mosaic menu changed line width instead of blocks")
            default: break
            }
            try require(controller.verificationWidthIndex == 3 && controller.verificationToolTitle == tool.rawValue,
                        "Legacy combination menu did not reflect \(tool.rawValue)'s selected size")
            controller.verificationUndo()
            try require(controller.verificationWidthIndex == (tool == .mosaic ? 2 : 1)
                && (try ImageToolsUI.png(beforeImage) == ImageToolsUI.png(objectCanvas.renderedImage())),
                "Legacy \(tool.rawValue) size undo did not restore pixels and controls")
            withExtendedLifetime(controller) {}
        }
        print("PASS: shared editor controls synchronize selection; tool-specific style actions edit objects and undo")
    }

    @MainActor private static func allButtons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(allButtons)
    }

    @MainActor private static func cachePreview(_ view: NSView, output: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate fixture-view preview")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageToolsVerificationFailure(description: "Cannot encode fixture-view preview")
        }
        try data.write(to: output, options: .atomic)
    }

    @MainActor private static func verifyImagePinContentBounds(outputDirectory: URL) throws {
        let preferences = PreferencesStore(storage: MemoryPreferencesStorage())
        for (width, height) in [(260, 180), (16, 12)] {
            let source = try solidImage(width: width, height: height)
            let pin = ImageToolsPinController(image: source, preferences: preferences)
            defer { pin.close() }
            guard let content = pin.window?.contentView else {
                throw ImageToolsVerificationFailure(description: "Missing image-pin content")
            }
            try require(pin.window?.hasShadow == true,
                        "Opaque image pin is missing its native presentation shadow")
            for scale: CGFloat in [1, 0.2, 1.25, 2] {
                pin.verificationScale(scale)
                for selected in [false, true] {
                    if selected { pin.verificationSelect() } else { pin.verificationDeselect() }
                    content.layoutSubtreeIfNeeded()
                    try require(pin.window?.hasShadow == true,
                                "Selection or zoom removed the opaque image-pin shadow")
                    guard let frame = pin.verificationImageContentFrame else {
                        throw ImageToolsVerificationFailure(description: "Missing displayed image frame")
                    }
                    try verifyImageHost(pin, inset: 1)
                    let viewport = pin.verificationImageViewport
                    let margins = [frame.minX - content.bounds.minX, frame.minY - content.bounds.minY,
                                   content.bounds.maxX - frame.maxX, content.bounds.maxY - frame.maxY]
                    try require(margins.allSatisfy { $0 >= 0.99 && $0 < 2.01 }
                                && abs(frame.width / CGFloat(width) - scale) < 0.00001
                                && abs(frame.height / CGFloat(height) - scale) < 0.00001
                                && abs(viewport.width - frame.width) < 0.01
                                && abs(viewport.height - frame.height) < 0.01,
                                "Native backing alignment changed image aspect ratio or viewport: source=\(width)×\(height), scale=\(scale), image=\(frame), host=\(content.bounds)")
                }
            }
            try require(pin.verificationImage === source, "Fitting the image changed its original raster")
            pin.verificationScale(1)
            pin.verificationDeselect()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            try cachePreview(content, output: outputDirectory.appendingPathComponent("image-pin-content-bounds-\(width).png"))
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let edgeX = max(0, (pin.verificationImageContentFrame?.minX ?? 1) - 0.5)
            let edge = bitmap.colorAt(x: Int(edgeX / content.bounds.width * CGFloat(bitmap.pixelsWide)),
                                      y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
            try require(edge.alphaComponent > 0.05 && edge.redComponent < 0.98,
                        "Opaque pin has no visible border outside the source viewport")
            let imageRect = pin.verificationImageContentFrame!
            let corner = CGPoint(x: imageRect.minX + 0.25, y: imageRect.minY + 0.25)
            let bitmapY = content.isFlipped ? corner.y : content.bounds.maxY - corner.y
            let cornerPixel = bitmap.colorAt(x: Int(corner.x / content.bounds.width * CGFloat(bitmap.pixelsWide)),
                                            y: Int(bitmapY / content.bounds.height * CGFloat(bitmap.pixelsHigh)))!
            try require(cornerPixel.alphaComponent < 0.1,
                        "Opaque image pin did not round only its display corners")
        }
        guard let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot create transparent pin fixture")
        }
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 60))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 20, y: 12, width: 40, height: 36))
        let transparent = context.makeImage()!
        let transparentPin = ImageToolsPinController(image: transparent, preferences: preferences)
        defer { transparentPin.close() }
        guard let transparentWindow = transparentPin.window, let content = transparentWindow.contentView else {
            throw ImageToolsVerificationFailure(description: "Missing transparent pin window")
        }
        try verifyImageHost(transparentPin, inset: 0)
        try require(!transparentWindow.hasShadow && transparentPin.verificationImageContentFrame?.size == CGSize(width: 80, height: 60),
                    "Transparent image acquired an external frame, a rectangular shadow or cropped source canvas")
        for selected in [false, true] {
            if selected { transparentPin.verificationSelect() } else { transparentPin.verificationDeselect() }
            let url = outputDirectory.appendingPathComponent("transparent-pin-content-\(selected ? "selected" : "idle").png")
            try cachePreview(content, output: url)
            let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
            let imageRect = transparentPin.verificationImageContentFrame!
            func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor {
                let point = CGPoint(x: imageRect.minX + x, y: imageRect.minY + y)
                let bitmapY = content.isFlipped ? point.y : content.bounds.maxY - point.y
                return bitmap.colorAt(x: Int(point.x / content.bounds.width * CGFloat(bitmap.pixelsWide)),
                                      y: Int(bitmapY / content.bounds.height * CGFloat(bitmap.pixelsHigh)))!
            }
            try require(pixel(8, 8).alphaComponent < 0.01 && pixel(40, 30).alphaComponent > 0.99,
                        "Pin decoration fills a transparent source region or hides opaque content")
            if selected {
                try require(pixel(0.75, 30).alphaComponent > 0.95,
                            "Transparent selected pin has no visible inset outline")
            }
        }
        try require(transparentPin.verificationImage === transparent
                    && ImageToolsUI.png(transparentPin.verificationImage!) == ImageToolsUI.png(transparent),
                    "Removing the pin frame changed the source PNG")
        let transparentFrame = transparentWindow.frame
        let editor = transparentPin.verificationPrepareEditor()!
        let border = editor.subviews.compactMap { $0 as? ImageToolsWindowBorder }.first
        try require(transparentWindow.hasShadow && border?.frame == editor.bounds
                    && border?.hitTest(CGPoint(x: 0.5, y: 0.5)) == nil,
                    "Transparent pin annotation lacks the shared passive editor border or shadow")
        editor.onCancel?()
        try require(!transparentWindow.hasShadow && transparentWindow.frame == transparentFrame
                    && transparentPin.verificationImage === transparent,
                    "Leaving transparent pin annotation retained a rectangular shell or changed its original size")
        transparentPin.verificationPrepareEditor()!.complete()
        try verifyImageHost(transparentPin, inset: 0)
        try require(!transparentWindow.hasShadow && transparentPin.verificationImageContentFrame?.size == CGSize(width: 80, height: 60)
                    && ImageToolsUI.hasTransparentPixels(transparentPin.verificationImage!),
                    "Applying transparent annotation flattened alpha or retained the editor shadow")
        print("PASS: opaque image pins keep source-sized viewports inside a one-point frame and native shadow at normal, small and zoomed sizes")
        print("PASS: transparent pins retain their source canvas and interior alpha with only a temporary inset selection outline")
    }

    @MainActor private static func verifyImagePinSelection(outputDirectory: URL) throws {
        for (name, width, height) in [("normal", 260, 180), ("oversized", 700, 18000)] {
            let source = try solidImage(width: width, height: height)
            let sourcePNG = try ImageToolsUI.png(source)
            let pin = ImageToolsPinController(image: source)
            defer { pin.close() }
            pin.verificationScale(name == "oversized" ? 3 : 1)
            guard let content = pin.window?.contentView,
                  let imageRect = pin.verificationImageContentFrame else {
                throw ImageToolsVerificationFailure(description: "Missing selection fixture view")
            }
            func snapshot(_ state: String) throws -> NSBitmapImageRep {
                let url = outputDirectory.appendingPathComponent("image-pin-selection-\(name)-\(state).png")
                try cachePreview(content, output: url)
                return NSBitmapImageRep(data: try Data(contentsOf: url))!
            }
            func pixel(_ bitmap: NSBitmapImageRep, _ point: CGPoint) -> NSColor {
                bitmap.colorAt(x: min(bitmap.pixelsWide - 1, max(0, Int(point.x / content.bounds.width * CGFloat(bitmap.pixelsWide)))),
                    y: min(bitmap.pixelsHigh - 1, max(0, Int(point.y / content.bounds.height * CGFloat(bitmap.pixelsHigh)))))!
                    .usingColorSpace(.deviceRGB)!
            }
            pin.verificationSelect()
            try require(pin.verificationImageSelectionRect == imageRect,
                        "Selection follows the clipped host boundary instead of the whole image")
            let visible = imageRect.intersection(content.bounds)
            let candidates = [CGPoint(x: imageRect.minX + 0.75, y: visible.midY),
                              CGPoint(x: imageRect.maxX - 0.75, y: visible.midY),
                              CGPoint(x: visible.midX, y: imageRect.minY + 0.75),
                              CGPoint(x: visible.midX, y: imageRect.maxY - 0.75)]
            let realEdges = candidates.filter { content.bounds.contains($0) }
            let selected = try snapshot("selected")
            for point in realEdges {
                let color = pixel(selected, point)
                try require(color.alphaComponent > 0.99 && color.blueComponent - color.redComponent > 0.12,
                            "Selected \(name) pin has no outline on a real visible image edge")
                try require(pin.verificationContentReceivesHit(at: point), "Image selection steals its edge mouse target")
            }
            let hostEdges = [CGPoint(x: content.bounds.minX + 0.75, y: visible.midY),
                             CGPoint(x: content.bounds.maxX - 0.75, y: visible.midY),
                             CGPoint(x: visible.midX, y: content.bounds.minY + 0.75),
                             CGPoint(x: visible.midX, y: content.bounds.maxY - 0.75)]
            for point in hostEdges where imageRect.insetBy(dx: 4, dy: 4).contains(point) {
                let color = pixel(selected, point)
                try require(color.redComponent > 0.99 && color.greenComponent > 0.99,
                            "Clipped desktop boundary acquired a fake image border")
            }
            let center = pixel(selected, CGPoint(x: visible.midX, y: visible.midY))
            try require(center.redComponent > 0.99 && center.greenComponent > 0.99,
                        "Selection tints source content")
            pin.verificationDeselect()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let idle = try snapshot("idle")
            for point in realEdges { try require(pixel(idle, point).redComponent > 0.99, "Deselection retains an inner outline") }
            pin.verificationSelect(); pin.verificationDeselect(); pin.verificationSelect()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let reselected = try snapshot("reselected")
            for point in realEdges { try require(pixel(reselected, point).redComponent < 0.7, "An old fade hides the new selection") }
            try require(pin.verificationImage === source && ImageToolsUI.png(pin.verificationImage!) == sourcePNG,
                        "Selection changes the copied or exported image")
        }
        print("PASS: image selection follows true image edges, leaves cropped desktop boundaries unframed, preserves hit targets and source pixels")
    }

    @MainActor private static func verifyTextPinContentBounds(outputDirectory: URL) throws {
        let text = "固定宽度文字贴图，保留中文和 English mixed text。This line wraps at a fixed width and must keep the same layout while zooming.\n第二段仍可编辑、选中和复制。"
        let pin = ImageToolsPinController(text: text)
        defer { pin.close() }
        guard let window = pin.window, let content = window.contentView else {
            throw ImageToolsVerificationFailure(description: "Missing text-pin content")
        }
        window.appearance = NSAppearance(named: .aqua)
        let original = try pin.verificationTextLayout()
        let originalSize = pin.verificationTextDocumentSize
        let selection = NSRange(location: 0, length: 8)
        pin.verificationSelectText(selection)
        try require(original.containerWidth == 408 && original.lineEnds.count >= 3
                    && pin.verificationTextRemainsEditable,
                    "Text fixture lost its editable fixed-width container or internal text padding")
        for factor: CGFloat in [0.2, 1, 1.25, 2, 4] {
            pin.verificationScale(factor)
            for selected in [false, true] {
                if selected { pin.verificationSelect() }
                else {
                    pin.verificationDeselect()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
                }
                try verifyTextPinViewport(pin, selected: selected)
                try require(try pin.verificationTextLayout() == original
                            && pin.verificationTextSelection == selection,
                            "Text content, wrapping or selected text changed at \(factor)x, selected=\(selected)")
            }
        }
        pin.verificationScale(1)
        pin.verificationDeselect()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try cachePreview(content, output: outputDirectory.appendingPathComponent("text-pin-content-idle.png"))
        pin.verificationSelect()
        try cachePreview(content, output: outputDirectory.appendingPathComponent("text-pin-content-selected.png"))
        print("PASS: text pins keep opaque content, an outer frame/shadow and passive inner selection at 0.2x, 1x, 1.25x, 2x and 4x")

        let edited = text + String(repeating: "\n新增的可编辑段落：原有固定宽度继续换行，内容无需转换为图片。", count: 18)
        try pin.verificationEditPinText(edited)
        let editedLayout = try pin.verificationTextLayout()
        let editedSize = pin.verificationTextDocumentSize
        try require(editedSize.height > originalSize.height + 100 && editedSize.width == originalSize.width
                    && editedLayout.containerWidth == original.containerWidth
                    && editedLayout.text == edited && editedLayout.lineEnds.count > original.lineEnds.count,
                    "Editing text lost content, changed the fixed width or did not grow its document: original=\(originalSize), edited=\(editedSize)")
        try verifyTextPinViewport(pin, selected: true)
        for factor: CGFloat in [0.2, 1, 1.25, 2, 4] {
            pin.verificationScale(factor)
            try require(try pin.verificationTextLayout() == editedLayout,
                        "Edited text rewrapped at \(factor)x")
            try verifyTextPinViewport(pin, selected: true)
        }
        let shorter = "恢复短文字。\nStill editable."
        try pin.verificationEditPinText(shorter)
        pin.verificationScale(1)
        let shortened = try pin.verificationTextLayout()
        try require(shortened.text == shorter && shortened.containerWidth == original.containerWidth
                    && pin.verificationTextDocumentSize.height < editedSize.height
                    && pin.verificationTextDocumentSize.width == originalSize.width,
                    "Shortening text did not shrink its document or changed the fixed text width")
        pin.verificationSelectText(NSRange(location: 0, length: 4))
        try require(pin.verificationTextSelection == NSRange(location: 0, length: 4)
                    && pin.verificationTextRemainsEditable,
                    "Text editing or selection stopped working after resizing")
        try verifyTextPinViewport(pin, selected: true)
        print("PASS: editing and shortening text resize the document while preserving fixed-width wrapping, internal padding and text selection")

        let longText = String(repeating: "长文字贴图仍是可编辑文本。Scrollable text keeps its fixed-width wrapping.\n", count: 250)
        let longPin = ImageToolsPinController(text: longText)
        defer { longPin.close() }
        longPin.window?.appearance = NSAppearance(named: .aqua)
        let longLayout = try longPin.verificationTextLayout()
        longPin.verificationScale(2)
        longPin.verificationSelect()
        guard let longContent = longPin.window?.contentView else {
            throw ImageToolsVerificationFailure(description: "Missing scrollable text-pin content")
        }
        try require(longPin.verificationTextDocumentSize.height * longPin.verificationZoom > longContent.bounds.height + 100,
                    "Long text fixture does not exercise a clipped scrollable document")
        longPin.verificationScrollImage()
        try verifyTextPinViewport(longPin, selected: true)
        try require(try longPin.verificationTextLayout() == longLayout,
                    "Scrolling long text changed its content or wrapping")
        try cachePreview(longContent, output: outputDirectory.appendingPathComponent("text-pin-scrollable-selected.png"))
        longPin.verificationDeselect()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        try verifyTextPinViewport(longPin, selected: false)
        try cachePreview(longContent, output: outputDirectory.appendingPathComponent("text-pin-scrollable-idle.png"))
        print("PASS: long text keeps its outline on the visible scroll viewport, preserves wrapping and passes hit testing through to editable text")
    }

    @MainActor private static func verifyTextPinViewport(_ pin: ImageToolsPinController, selected: Bool) throws {
        guard let window = pin.window, let content = window.contentView else {
            throw ImageToolsVerificationFailure(description: "Missing text-pin viewport")
        }
        content.layoutSubtreeIfNeeded()
        try require(window.hasShadow, "Text pin is missing its presentation shadow")
        let viewport = pin.verificationPinViewportFrame
        try require(abs(viewport.minX - content.bounds.minX - 1) < 0.5
                    && abs(viewport.minY - content.bounds.minY - 1) < 0.5
                    && abs(viewport.width - content.bounds.width + 2) < 0.5
                    && abs(viewport.height - content.bounds.height + 2) < 0.5
                    && abs(pin.verificationOutlineFrame.minX - viewport.minX) < 0.01
                    && abs(pin.verificationOutlineFrame.minY - viewport.minY) < 0.01
                    && abs(pin.verificationOutlineFrame.width - viewport.width) < 0.01
                    && abs(pin.verificationOutlineFrame.height - viewport.height) < 0.01,
                    "Text border changed the viewport or selection bounds: window=\(content.bounds), viewport=\(viewport), outline=\(pin.verificationOutlineFrame)")
        try require(pin.verificationTextReceivesHit(), "Text selection is blocked by the outline or an outer decoration")
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate text-pin pixel fixture")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        func pixel(_ point: CGPoint) throws -> NSColor {
            let x = min(bitmap.pixelsWide - 1, Int(point.x / content.bounds.width * CGFloat(bitmap.pixelsWide)))
            let y = min(bitmap.pixelsHigh - 1, Int(point.y / content.bounds.height * CGFloat(bitmap.pixelsHigh)))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw ImageToolsVerificationFailure(description: "Cannot read text-pin edge pixels")
            }
            return color
        }
        for point in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: content.bounds.maxX - 0.25, y: 0.25),
                      CGPoint(x: 0.25, y: content.bounds.maxY - 0.25),
                      CGPoint(x: content.bounds.maxX - 0.25, y: content.bounds.maxY - 0.25)] {
            try require(try pixel(point).alphaComponent < 0.1,
                        "Minimal text card did not preserve its rounded transparent external corner")
        }
        for point in [CGPoint(x: viewport.minX + 0.75, y: viewport.midY),
                      CGPoint(x: viewport.maxX - 0.75, y: viewport.midY),
                      CGPoint(x: viewport.midX, y: viewport.minY + 0.75),
                      CGPoint(x: viewport.midX, y: viewport.maxY - 0.75)] {
            let color = try pixel(point)
            try require(color.alphaComponent > 0.99 && pin.verificationContentReceivesHit(at: point),
                        "Text edge is translucent or intercepts its original mouse target")
            if selected {
                try require(color.blueComponent - color.redComponent > 0.12 && color.redComponent < 0.7,
                            "Selected text pin has no visible inset blue-gray outline")
            } else {
                try require(abs(color.blueComponent - color.redComponent) < 0.03,
                            "Inactive text pin retains an accent outline")
            }
        }
    }

    @MainActor private static func verifyInlineWorkflows(outputDirectory: URL) throws {
        // This drag checks text interaction, not the user's current pointer or edge clamping.
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let pin = ImageToolsPinController(text: "原色AB选中色CD原色",
            anchor: CGPoint(x: screen.midX, y: screen.midY))
        defer { pin.close() }
        let text = pin.verificationTextView!
        try require(text.isMoving && !text.isEditable && !text.isSelectable, "Text pin does not default to moving")
        let frame = pin.window!.frame
        try pin.verificationDrag(dx: 12, dy: -12, option: false)
        try require(abs(pin.window!.frame.minX - frame.minX - 12) < 0.1,
                    "Plain text drag did not move: before=\(frame), after=\(pin.window!.frame), moving=\(text.isMoving)")
        text.onBeginEditing?()
        try require(!text.isMoving && text.isEditable && text.isSelectable, "Double-click editing callback does not enable selection")
        let range = NSRange(location: 4, length: 3)
        text.setSelectedRange(range)
        let before = NSAttributedString(attributedString: text.attributedString())
        text.undoManager?.beginUndoGrouping()
        pin.verificationTextColor(.systemRed)
        text.undoManager?.endUndoGrouping()
        try require((text.textStorage!.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true,
                    "Selected text did not change color")
        try require(text.attributedString().attributedSubstring(from: NSRange(location: 0, length: 4))
            .isEqual(to: before.attributedSubstring(from: NSRange(location: 0, length: 4))), "Color edit changed unselected text")
        text.undoManager?.undo()
        try require(text.attributedString().isEqual(to: before), "Color change cannot be undone exactly")
        text.undoManager?.redo()
        try require((text.textStorage!.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true,
                    "Color change cannot be redone")
        pin.verificationEditing(false)
        try require(text.isMoving && !text.isEditable && text.selectedRange().length == 0,
                    "Finishing text editing did not restore moving")
        pin.verificationEditing(true)
        try require((text.textStorage!.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true,
                    "Switching modes lost text colors")
        try cachePreview(pin.window!.contentView!, output: outputDirectory.appendingPathComponent("text-colors-preview.png"))
        print("PASS: text pins default to ordinary dragging; editing enables selection and range colors support undo, redo and mode changes")

        let source = try solidImage(width: 700, height: 6000)
        let imagePin = ImageToolsPinController(image: source)
        defer { imagePin.close() }
        let originalWindow = imagePin.window
        let originalFrame = originalWindow!.frame
        let editor = imagePin.verificationPrepareEditor()!
        try require(editor.window === originalWindow && editor.scroll.magnification > 0 && editor.scroll.magnification < 0.5,
                    "Long image must open centered and fitted inside the existing pin window")
        editor.setZoom(1.5)
        editor.scroll.contentView.scroll(to: CGPoint(x: 0, y: 2900))
        editor.canvas.tool = .rectangle
        gesture(editor.canvas, points: [CGPoint(x: 100, y: 3000), CGPoint(x: 300, y: 3200)])
        let rendered = try editor.canvas.renderedImage()
        try require(rendered.width == 700 && rendered.height == 6000, "Zoom changed export resolution")
        let marked = try rgba(rendered, x: 100, y: 3100)
        try require(marked[0] > 0.8 && marked[1] < 0.6, "Scrolled/zoomed annotation has wrong image coordinates")
        editor.canvas.undoAnnotation()
        try require(editor.canvas.annotations.isEmpty, "Inline annotation cannot undo")
        try cachePreview(editor, output: outputDirectory.appendingPathComponent("long-inline-preview.png"))
        editor.onCancel?()
        try require(imagePin.window === originalWindow && imagePin.verificationImage === source
                    && !imagePin.verificationHasEditor && originalWindow!.frame == originalFrame,
                    "Cancelling inline editing changed source pixels, lost the pin, or changed its frame")
        print("PASS: inline long-image editing reuses its pin, initially fits the image, scrolls and zooms in image coordinates, retains export resolution and cancels without loss")
    }

    @MainActor private static func verifyPinsAndOCRPresentation(outputDirectory: URL) throws {
        let source = try solidImage()
        let preferences = PreferencesStore(storage: MemoryPreferencesStorage())
        let testScreen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        // This checks the first drag delta; screen-edge clamping has its own cases.
        // The user's real pointer may be at an edge while the probe is running.
        let imagePin = ImageToolsPinController(image: source, preferences: preferences,
            anchor: CGPoint(x: testScreen.midX, y: testScreen.midY))
        guard let pinWindow = imagePin.window, let imageContent = pinWindow.contentView else {
            throw ImageToolsVerificationFailure(description: "Image pin did not initialize")
        }
        try require(!pinWindow.styleMask.contains(.titled) && pinWindow.styleMask.contains(.nonactivatingPanel) && allButtons(imageContent).isEmpty,
                    "Image pin retains normal window chrome or an always-visible control bar")
        try require(!imagePin.verificationSelected && imagePin.verificationHUD?.isVisible == false && pinWindow.hasShadow,
                    "A new image pin has persistent selection controls or lacks its presentation shadow")
        try require(imagePin.verificationImageViewport.width >= CGFloat(source.width)
                    && imagePin.verificationImageViewport.height >= CGFloat(source.height),
                    "Initial image viewport cropped the source")
        let beforeDrag = pinWindow.frame
        try imagePin.verificationDrag(dx: 45, dy: 30)
        try require(imagePin.verificationSelected && abs(pinWindow.frame.minX - beforeDrag.minX - 45) < 0.1
                    && abs(pinWindow.frame.minY - beforeDrag.minY - 30) < 0.1,
                    "Image first-click drag failed: before=\(beforeDrag), after=\(pinWindow.frame), selected=\(imagePin.verificationSelected)")
        guard let imageHUD = imagePin.verificationHUD else {
            throw ImageToolsVerificationFailure(description: "Image pin has no floating action HUD")
        }
        try require(imageHUD.styleMask.contains(.nonactivatingPanel) && !imageHUD.canBecomeKey && !imageHUD.canBecomeMain
                    && !imageHUD.frame.intersects(pinWindow.frame),
                    "Pin action HUD can steal key focus or overlays the image")
        try require(imagePin.verificationHUDTitles == ["标注", "提取文字", "复制图片", "保存 PNG", "关闭贴图"],
                    "Image selection HUD lacks the requested actions")
        var hudOCRSource: CGImage?
        imagePin.onOCR = { hudOCRSource = $0 }
        imagePin.verificationHUDOCR()
        try require(hudOCRSource === source && imagePin.verificationSelected,
                    "HUD action lost pin selection or passed a decorated image to OCR")
        let beforeHandleDrag = pinWindow.frame
        try imagePin.verificationDrag(dx: 20, dy: -15, useHUD: true)
        try require(abs(pinWindow.frame.minX - beforeHandleDrag.minX - 20) < 0.1
                    && abs(pinWindow.frame.minY - beforeHandleDrag.minY + 15) < 0.1
                    && !imageHUD.frame.intersects(pinWindow.frame),
                    "Floating HUD handle did not move its pin or follow the new position")
        let imageMenu = imagePin.verificationMenuTitles
        for title in ["标注", "提取文字", "复制图片", "保存 PNG", "恢复大小", "关闭贴图"] {
            try require(imageMenu.contains(title), "Image pin is missing context action \(title)")
        }
        try imagePin.verificationWheel(2, precise: false)
        try require(imagePin.verificationZoom > 1, "Mouse wheel did not enlarge image pin")
        let wheelZoom = imagePin.verificationZoom
        try imagePin.verificationWheel(8, precise: true)
        try require(imagePin.verificationZoom > wheelZoom, "Two-finger scrolling did not zoom the whole image")
        let trackpadZoom = imagePin.verificationZoom
        imagePin.verificationPinch(1.2)
        try require(imagePin.verificationZoom > trackpadZoom, "Native pinch event did not enlarge image pin")
        try require(!imageHUD.frame.intersects(pinWindow.frame), "Zoom moved the pin under its floating action HUD")
        try require(try ImageToolsUI.png(imagePin.verificationImage!) == ImageToolsUI.png(source), "Zoom changed the source raster")
        let longSource = try solidImage(width: 700, height: 18000)
        try verifyFirstSelectionDrag(image: longSource, preferences: preferences)
        let longPin = ImageToolsPinController(image: longSource, preferences: preferences)
        try longPin.verificationWheel(2, precise: false)
        longPin.verificationPinch(1000)
        longPin.verificationSelect()
        guard let longWindow = longPin.window else { throw ImageToolsVerificationFailure(description: "Long pin window is missing") }
        let visible = longWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        let desktop = NSScreen.screens.map(\.visibleFrame).reduce(CGRect.null) { $0.union($1) }.integral
        try require((longPin.verificationWholeImageFrame?.width ?? 0) >= 700 && desktop.contains(longWindow.frame),
                    "Long image cannot zoom to a readable width with a bounded native host")
        try require(longPin.verificationImage === longSource, "Long-image zoom copied or replaced the source bitmap")
        try require(!imagePin.verificationSelected && longPin.verificationSelected
                    && longPin.verificationHUD.map { desktop.contains($0.frame) } == true,
                    "Selecting another pin did not hide previous controls or keep the long-image HUD reachable")
        longPin.verificationDeactivate()
        try require(!longPin.verificationSelected, "Application deactivation did not clear pin selection")
        imagePin.verificationSelect()
        guard let edit = imagePin.verificationPrepareEditor() else {
            throw ImageToolsVerificationFailure(description: "Pin edit controller did not initialize")
        }
        let editorContent = edit
        try require(edit.window === pinWindow && allButtons(edit).contains { $0.title == "完成" }, "Pin editing is not hosted by its original window")
        try require(pinWindow.hasShadow && edit.subviews.contains { $0 is ImageToolsWindowBorder },
                    "Pin annotation does not share the framed editor presentation")
        let canvas = edit.canvas
        canvas.tool = .rectangle
        gesture(canvas, points: [CGPoint(x: 40, y: 40), CGPoint(x: 100, y: 100)])
        try cachePreview(editorContent, output: outputDirectory.appendingPathComponent("editor-preview.png"))
        edit.complete()
        try require(imagePin.window === pinWindow && !imagePin.verificationHasEditor,
                    "Applying markup replaced the pin window or left its editor active")
        try require(pinWindow.hasShadow, "Applying markup removed the opaque image-pin shadow")
        let marked = try rgba(imagePin.verificationImage!, x: 40, y: 60)
        try require(marked[0] > 0.8 && marked[1] < 0.6, "Applied markup did not reach the original image pin")
        let pinPreview = outputDirectory.appendingPathComponent("image-pin-preview.png")
        try cachePreview(imageContent, output: pinPreview)
        guard let previewBitmap = NSBitmapImageRep(data: try Data(contentsOf: pinPreview)) else {
            throw ImageToolsVerificationFailure(description: "Cannot decode rendered pin content")
        }
        let backingScaleX = CGFloat(previewBitmap.pixelsWide) / imageContent.bounds.width
        let backingScaleY = CGFloat(previewBitmap.pixelsHigh) / imageContent.bounds.height
        try verifyImageHost(imagePin, inset: 1)
        guard let imageRect = imagePin.verificationImageContentFrame else {
            throw ImageToolsVerificationFailure(description: "Applied pin has no source image rectangle")
        }
        let interior = imageRect.insetBy(dx: 5, dy: 5)
        for point in [CGPoint(x: interior.minX, y: interior.minY), CGPoint(x: interior.maxX, y: interior.minY),
                      CGPoint(x: interior.minX, y: interior.maxY), CGPoint(x: interior.maxX, y: interior.maxY)] {
            let bitmapY = imageContent.isFlipped ? point.y : imageContent.bounds.maxY - point.y
            guard let pixel = previewBitmap.colorAt(x: Int(point.x * backingScaleX), y: Int(bitmapY * backingScaleY)) else {
                throw ImageToolsVerificationFailure(description: "Cannot inspect image-pin edges")
            }
            try require(pixel.alphaComponent > 0.99, "Opaque source image has a transparent inner edge after annotation")
        }
        if let hudContent = imageHUD.contentView {
            try cachePreview(hudContent, output: outputDirectory.appendingPathComponent("image-pin-hud-preview.png"))
        }
        let textPin = ImageToolsPinController(text: "固定宽度换行的文字贴图。\nEditable text pin.", preferences: preferences)
        guard let textWindow = textPin.window, let textContent = textWindow.contentView else {
            throw ImageToolsVerificationFailure(description: "Text pin did not initialize")
        }
        try require(!textWindow.styleMask.contains(.titled) && textWindow.styleMask.contains(.nonactivatingPanel) && allButtons(textContent).isEmpty,
                    "Text pin retains normal window chrome or an always-visible control bar")
        try require(textPin.verificationMenuTitles.contains("编辑文字") && textPin.verificationMenuTitles.contains("复制文字"),
                    "Borderless text pin has no reachable move/copy controls")
        try require(textPin.verificationTextView?.font?.pointSize == 16
                    && textPin.verificationTextView?.textContainerInset == CGSize(width: 16, height: 16)
                    && textPin.verificationTextView?.defaultParagraphStyle?.lineSpacing == 3
                    && textPin.verificationTextCornerRadius == 6,
                    "Minimal text card lost its smaller type, padding, spacing or rounded selection")
        let textBefore = try textPin.verificationTextLayout()
        textWindow.setFrameOrigin(CGPoint(x: visible.midX - textWindow.frame.width / 2,
                                         y: visible.midY - textWindow.frame.height / 2))
        let textFrame = textWindow.frame
        try textPin.verificationDrag(dx: -30, dy: 25)
        try require(textPin.verificationSelected && !imagePin.verificationSelected
                    && abs(textWindow.frame.minX - textFrame.minX + 30) < 0.1
                    && abs(textWindow.frame.minY - textFrame.minY - 25) < 0.1,
                    "Option-drag on a text pin did not move and select its window: before=\(textFrame) after=\(textWindow.frame) textSelected=\(textPin.verificationSelected) imageSelected=\(imagePin.verificationSelected)")
        try require(textPin.verificationHUDTitles == ["编辑文字", "复制文字", "关闭贴图"], "Text selection HUD contains image-only actions")
        try textPin.verificationWheel(2, precise: false)
        textPin.verificationPinch(1.2)
        try require(try textPin.verificationTextLayout() == textBefore, "Text zoom rewrapped the fixed-width document")
        try cachePreview(textContent, output: outputDirectory.appendingPathComponent("text-pin-preview.png"))
        var clipboardAttempts = 0
        var clipboardSucceeds = false
        var copiedText: String?
        var ocrCloseCount = 0
        let ocr = ImageToolsOCRController(writeClipboard: { text in
            clipboardAttempts += 1
            if clipboardSucceeds { copiedText = text }
            return clipboardSucceeds
        })
        ocr.onClose = { ocrCloseCount += 1 }
        guard let ocrContent = ocr.window?.contentView else { throw ImageToolsVerificationFailure(description: "OCR view is missing") }
        try require(ocr.window?.styleMask.contains([.titled, .resizable, .miniaturizable]) == true
                    && ocr.window?.collectionBehavior.contains(.fullScreenPrimary) == true
                    && ocr.window?.standardWindowButton(.zoomButton) != nil,
                    "OCR window is missing native fullscreen eligibility or its standard green button")
        try require(allButtons(ocrContent).map(\.title) == ["复制并关闭"] && !ocr.verificationCopyEnabled,
                    "OCR loading view has extra actions or enabled copying")
        ocr.verificationCopy()
        try require(clipboardAttempts == 0 && ocrCloseCount == 0, "OCR loading state copied or closed its window")
        ocr.complete("屏幕文字\nScreen text")
        try require(ocr.verificationFontSize == 14 && ocr.verificationStatusHidden && ocr.verificationCopyEnabled && ocr.verificationText == "屏幕文字\nScreen text",
                    "OCR completion did not show copyable text without persistent status copy")
        try cachePreview(ocrContent, output: outputDirectory.appendingPathComponent("ocr-result-preview.png"))
        ocr.verificationCopy()
        try require(clipboardAttempts == 1 && ocrCloseCount == 0 && !ocr.verificationStatusHidden
                    && ocr.verificationCopyEnabled && ocr.verificationText == "屏幕文字\nScreen text",
                    "Failed clipboard write closed the OCR result or discarded copyable text")
        ocr.verificationEdit(" \n")
        ocr.verificationCopy()
        try require(!ocr.verificationCopyEnabled && clipboardAttempts == 1 && ocrCloseCount == 0,
                    "Blank edited OCR text copied or closed its result")
        ocr.fail(PatchError(message: "请尝试更清晰的文字。"))
        try require(!ocr.verificationCopyEnabled && ocr.verificationStatusHidden && ocr.verificationText == "请尝试更清晰的文字。",
                    "OCR failure repeated its heading or allowed copying an error")
        ocr.verificationCopy()
        try require(clipboardAttempts == 1 && ocrCloseCount == 0, "OCR failure copied its error message or closed")
        ocr.complete("屏幕文字\nScreen text")
        clipboardSucceeds = true
        ocr.verificationCopy()
        try require(clipboardAttempts == 2 && copiedText == "屏幕文字\nScreen text" && ocrCloseCount == 1,
                    "Successful OCR copying did not close exactly once with the result text")
        print("PASS: first-click image/Option-text/HUD movement, detached selection HUD, image content edges, zoom and source-raster preservation")
        print("PASS: native fullscreen OCR window, copy-and-close success, clipboard failure and blank/loading/error guards")
    }

    @MainActor private static func verifyFirstSelectionDrag(image: CGImage, preferences: PreferencesStore) throws {
        let imagePin = ImageToolsPinController(image: image, preferences: preferences)
        let textPin = ImageToolsPinController(text: String(repeating: "Long text pin fixture.\n", count: 700), preferences: preferences)
        defer { imagePin.close(); textPin.close() }
        imagePin.verificationScale(4)
        guard let whole = imagePin.verificationWholeImageFrame else { throw ImageToolsVerificationFailure(description: "Missing long-image geometry") }
        var selectedImage: CGRect?
        try imagePin.verificationDrag(dx: 0, dy: 10, afterMouseDown: { selectedImage = imagePin.verificationWholeImageFrame })
        try require(imagePin.verificationSelected && selectedImage == whole
                    && abs((imagePin.verificationWholeImageFrame?.minY ?? 0) - whole.minY - 10) < 0.1
                    && imagePin.verificationWholeImageFrame?.size == whole.size,
                    "Selecting or first-dragging a long image changed its scale, aspect ratio or pointer delta")
        guard let window = textPin.window else { throw ImageToolsVerificationFailure(description: "Missing long-text window") }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
        try require(!textPin.verificationSelected && window.frame.height <= visible.height / 2 + 1
                    && window.frame.width <= visible.width / 2 + 1,
                    "Long-text fixture exceeds the initial half-display bounds")
        window.setFrameOrigin(CGPoint(x: visible.midX - window.frame.width / 2, y: visible.minY + 20))
        let original = window.frame
        var selectedFrame: CGRect?
        try textPin.verificationDrag(dx: 0, dy: 10, afterMouseDown: { selectedFrame = window.frame })
        guard let selectedFrame else { throw ImageToolsVerificationFailure(description: "Missing text mouse-down frame") }
        try require(textPin.verificationSelected && selectedFrame == original
                    && abs(window.frame.minY - selectedFrame.minY - 10) < 0.1,
                    "Selecting the smaller text card resizes it or loses the first drag delta")
        print("PASS: first selection preserves whole-image geometry and both image/Option-text dragging retain the first pointer delta")
    }

    @MainActor private static func verifyOutsideRendering(outputDirectory: URL) throws {
        let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        context.setFillColor(NSColor.systemYellow.cgColor); context.fill(CGRect(x: 4, y: 6, width: 8, height: 10))
        let source = context.makeImage()!
        for tool in ImageToolsTool.allCases {
            let canvas = ImageToolsCanvas(image: source)
            canvas.allowsOutsideAnnotations = true
            canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            canvas.bounds = CGRect(x: -160, y: -120, width: 400, height: 300)
            let annotation = ImageToolsAnnotation(tool: tool,
                points: tool == .text || tool == .number || tool == .sticker ? [CGPoint(x: -65, y: -65)]
                    : [CGPoint(x: -65, y: -65), CGPoint(x: -25, y: -25)],
                color: .red, width: 4, text: tool == .sticker ? StickerCatalog.defaultIdentifier : "外部标注", fontSize: 18)
            if tool == .text { canvas.verificationWriteText("外部标注", at: CGPoint(x: -65, y: -65)) }
            else { try canvas.verificationAdd(annotation) }
            let exported = try canvas.renderedImage()
            let region = canvas.verificationExportBounds
            try require(exported.width == Int(region.width) && exported.height == Int(region.height)
                        && region.minX < 0 && region.minY < 0, "\(tool) outside bounds are cropped")
            for (x, y) in [(5, 5), (8, 48), (50, 30)] {
                try require(same(rgba(source, x: x, y: y), rgba(exported, x: x - Int(region.minX), y: y - Int(region.minY))),
                            "\(tool) expansion moved or changed original pixels")
            }
            try require(same(rgba(exported, x: 0, y: 0), [1, 1, 1, 1]), "\(tool) expansion is not opaque white")
            if tool != .mosaic {
                let bitmap = NSBitmapImageRep(cgImage: exported)
                var marked = false
                for y in 1..<Int(-region.minY) {
                    for x in 1..<Int(-region.minX) {
                        if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           min(c.redComponent, c.greenComponent, c.blueComponent) < 0.8 { marked = true; break }
                    }
                    if marked { break }
                }
                try require(marked, "\(tool) outside mark disappeared from raster export")
            }
            let cropped = try canvas.renderedImage(croppingTo: CGRect(x: -80, y: -80, width: 120, height: 120))
            try require(cropped.width == 120 && cropped.height == 120, "\(tool) crop with negative coordinates failed")
            if tool == .text { try ImageToolsUI.png(exported).write(to: outputDirectory.appendingPathComponent("outside-text-export.png")) }
            canvas.undoAnnotation()
            let restored = try canvas.renderedImage()
            try require(restored.width == source.width && restored.height == source.height,
                        "\(tool) undo retained empty export margins")
        }
        print("PASS: all eight tools annotate outside the image; white expansion, original pixel positions, negative crops and undo preserve document coordinates")
    }

    @MainActor private static func verifyRendering(outputDirectory: URL) throws {
        let width = 120, height = 100
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate rendering fixture")
        }
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(red: CGFloat(x) / 120, green: CGFloat(y) / 100,
                                            blue: 0.3, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let source = context.makeImage() else {
            throw ImageToolsVerificationFailure(description: "Cannot create rendering fixture")
        }
        let canvas = ImageToolsCanvas(image: source)
        let initial = try canvas.renderedImage()
        for (x, y) in [(10, 10), (110, 90), (60, 50)] {
            let sourcePixel = try rgba(source, x: x, y: y)
            let renderedPixel = try rgba(initial, x: x, y: y)
            try require(same(sourcePixel, renderedPixel), "Source orientation or color changed at (\(x), \(y))")
        }
        print("PASS: source orientation and raster colors")
        try canvas.verificationAdd(ImageToolsAnnotation(tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 30)], color: .red, width: 4))
        let annotated = try canvas.renderedImage()
        let mark = try rgba(annotated, x: 10, y: 15)
        try require(mark[0] > 0.95 && mark[1] < 0.05, "Annotation pixel coordinates are incorrect")
        print("PASS: annotation document coordinates match exported pixels")
        try canvas.verificationMosaic(CGRect(x: 40, y: 10, width: 48, height: 48))
        let mosaic = try canvas.renderedImage()
        let outsideBefore = try rgba(annotated, x: 20, y: 80)
        let outsideAfter = try rgba(mosaic, x: 20, y: 80)
        try require(same(outsideBefore, outsideAfter), "Mosaic modified pixels outside its region")
        let blockA = try rgba(mosaic, x: 50, y: 20)
        let blockB = try rgba(mosaic, x: 51, y: 21)
        let original = try rgba(annotated, x: 50, y: 20)
        try require(same(blockA, blockB), "Mosaic did not replace its region with pixel blocks")
        try require(!same(original, blockA), "Mosaic retained original selected pixels")
        try require(blockA[3] > 0.99, "Mosaic replacement is transparent")
        var expectedAverage = [CGFloat](repeating: 0, count: 4)
        for y in 10..<22 {
            for x in 40..<52 {
                let pixel = try rgba(annotated, x: x, y: y)
                for channel in 0..<4 { expectedAverage[channel] += pixel[channel] / 144 }
            }
        }
        try require(same(expectedAverage, blockA), "Mosaic sampled an incorrect source region")
        print("PASS: opaque mosaic replaces actual selected pixels and preserves outside pixels")
        let data = try ImageToolsUI.png(mosaic)
        guard let decoded = NSBitmapImageRep(data: data) else {
            throw ImageToolsVerificationFailure(description: "PNG export cannot be decoded")
        }
        try require(decoded.pixelsWide == width && decoded.pixelsHigh == height, "PNG export dimensions changed")
        try data.write(to: outputDirectory.appendingPathComponent("image-render-probe.png"), options: .atomic)
        print("PASS: PNG export round-trip and exact image dimensions")
        canvas.undoAnnotation()
        let undone = try rgba(canvas.renderedImage(), x: 50, y: 20)
        try require(same(undone, original), "Undo did not restore pre-mosaic pixels")
        print("PASS: undo restores the source pixels")
        let editor = ImageToolsEditorController(image: source, preferences: PreferencesStore(storage: MemoryPreferencesStorage()))
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        try require(editor.window != nil, "Editor window failed to initialize")
        print("PASS: editor initializes without capture or accessibility permissions")
    }

    @MainActor private static func verifyRegionRendering() throws {
        let width = 420, height = 310
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            context.setFillColor(CGColor(red: CGFloat(y % 43) / 43, green: CGFloat(y) / CGFloat(height),
                blue: 0.4, alpha: y < 90 ? 0.35 : 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        let source = context.makeImage()!
        let fixtures: [ImageToolsAnnotation?] = [nil,
            ImageToolsAnnotation(tool: .arrow, points: [CGPoint(x: 10,y: 20), CGPoint(x: 190,y: 160)], color: .red, width: 8),
            ImageToolsAnnotation(tool: .rectangle, points: [CGPoint(x: 20,y: 20), CGPoint(x: 180,y: 140)], color: .blue, width: 9),
            ImageToolsAnnotation(tool: .ellipse, points: [CGPoint(x: 20,y: 20), CGPoint(x: 180,y: 140)], color: .red, width: 4),
            ImageToolsAnnotation(tool: .pen, points: [CGPoint(x: 12,y: 24), CGPoint(x: 150,y: 98), CGPoint(x: 220,y: 140)], color: .green, width: 7),
            ImageToolsAnnotation(tool: .text, points: [CGPoint(x: 20,y: 35)], color: .black, width: 3, text: "Patch 中英文字", fontSize: 30),
            ImageToolsAnnotation(tool: .number, points: [CGPoint(x: 42,y: 42)], color: .red, width: 3, number: 12),
            ImageToolsAnnotation(tool: .sticker, points: [CGPoint(x: 42,y: 42)], color: .red, width: 3, text: "🌼", fontSize: 64),
            ImageToolsAnnotation(tool: .mosaic, points: [CGPoint(x: 20,y: 20), CGPoint(x: 180,y: 140)], color: .red, width: 3)]
        let crops = [CGRect(x: 35,y: 29,width: 100,height: 80),
                     CGRect(x: 0,y: 0,width: 65,height: 54),
                     CGRect(x: 390,y: 280,width: 30,height: 30),
                     CGRect(x: -5.3,y: 10.2,width: 80.7,height: 50.4)]
        func bytes(_ image: CGImage) -> Data {
            let copy = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            copy.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
            return Data(bytes: copy.data!, count: image.width * image.height * 4)
        }
        for (index, annotation) in fixtures.enumerated() {
            let canvas = ImageToolsCanvas(image: source)
            if let annotation { try canvas.verificationAdd(annotation) }
            let full = try canvas.renderedImage()
            for crop in crops {
                let expected = full.cropping(to: crop.integral.intersection(CGRect(x: 0,y: 0,width: width,height: height)))!
                let actual = try canvas.renderedImage(croppingTo: crop)
                try require(actual.width == expected.width && actual.height == expected.height,
                            "Region export dimensions changed for fixture \(index)")
                let actualBytes = bytes(actual), expectedBytes = bytes(expected)
                if actualBytes != expectedBytes {
                    let deltas = zip(actualBytes, expectedBytes).map { abs(Int($0) - Int($1)) }
                    print("REGION DIFF fixture=\(index) changedBytes=\(deltas.filter { $0 != 0 }.count) maxDelta=\(deltas.max() ?? 0)")
                    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp")
                    try ImageToolsUI.png(actual).write(to: output.appendingPathComponent("region-actual.png"))
                    try ImageToolsUI.png(expected).write(to: output.appendingPathComponent("region-expected.png"))
                }
                try require(actualBytes == expectedBytes, "Region export pixels differ from full-image crop for fixture \(index), crop \(crop)")
                try require(actual.bytesPerRow <= actual.width * 4 + 64,
                            "Small exported region still uses a full-image row stride")
                let decoded = NSBitmapImageRep(data: try ImageToolsUI.png(actual))!.cgImage!
                try require(bytes(decoded) == bytes(actual), "Region PNG changed pixels or alpha")
            }
        }
        let canvas = ImageToolsCanvas(image: source)
        for crop in [CGRect.zero, CGRect(x: 900,y: 900,width: 20,height: 20),
                     CGRect(x: CGFloat.nan,y: 0,width: 20,height: 20)] {
            do {
                _ = try canvas.renderedImage(croppingTo: crop)
                throw ImageToolsVerificationFailure(description: "Invalid region was accepted")
            } catch is PatchError { }
        }
        print("PASS: region-sized rendering matches full-image crops for all eight annotation tools, alpha, edge clipping and PNG export; invalid regions rejected")
    }

    @MainActor private static func verifyTextLayout() throws {
        let text = "第一行中英文 mixed text. This line should wrap at a fixed width and remain stable during zoom.\n第二行"
        let pin = ImageToolsPinController(text: text)
        pin.window?.contentView?.layoutSubtreeIfNeeded()
        let initial = try pin.verificationTextLayout()
        try require(initial.text == text && initial.lineEnds.count >= 3,
                    "Text fixture did not preserve text or exercise wrapped lines")
        for factor: CGFloat in [0.2, 2, 4] {
            pin.verificationScale(factor)
            let scaled = try pin.verificationTextLayout()
            try require(scaled == initial, "Text wrapping or content changed at \(factor)x magnification")
        }
        pin.window?.setContentSize(CGSize(width: 220, height: 160))
        pin.window?.contentView?.layoutSubtreeIfNeeded()
        let resized = try pin.verificationTextLayout()
        try require(resized == initial, "Text wrapping or content changed when resizing the pin window")
        print("PASS: editable text keeps its content and line breaks at 0.2x, 2x, 4x and on window resize")
    }

    private static func verifyOCRLanguages() throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        try require(supported.contains("en-US") && supported.contains("zh-Hans") && supported.contains("zh-Hant"),
                    "Runtime OCR does not provide the requested English and Chinese languages: \(supported)")
        print("PASS: runtime Vision supports en-US, zh-Hans and zh-Hant")
    }

    @MainActor private static func verifyOCR(outputDirectory: URL) throws {
        guard let context = CGContext(data: nil, width: 900, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate OCR fixture")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: "Patch", attributes: [
            .font: NSFont.systemFont(ofSize: 80, weight: .semibold), .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 35, y: 35))
        NSAttributedString(string: "屏幕截图 文字提取", attributes: [
            .font: NSFont.systemFont(ofSize: 56, weight: .medium), .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 35, y: 160))
        NSGraphicsContext.restoreGraphicsState()
        guard let fixture = context.makeImage() else {
            throw ImageToolsVerificationFailure(description: "Cannot create OCR fixture")
        }
        try ImageToolsUI.png(fixture).write(to: outputDirectory.appendingPathComponent("ocr-probe.png"), options: .atomic)
        let recognized = try ImageToolsOCRWorker.read(fixture)
        let normalized = recognized.lowercased().filter { $0.isLetter }
        try require(normalized.contains("patch"), "End-to-end OCR did not recognize the generated English fixture")
        try require(recognized.contains("屏幕截图") && recognized.contains("文字提取"),
                    "End-to-end OCR did not recognize the generated Chinese fixture")
        print("PASS: local end-to-end OCR recognized English and Chinese text")
    }

    @MainActor private static func verifyOCRAngles(outputDirectory: URL) throws {
        let lines = ["Patch OCR 2026", "屏幕截图 中文识别", "繁體中文 截圖文字辨識", "Automatic orientation test"]
        let expected = lines.joined()
        guard let context = CGContext(data: nil, width: 1000, height: 450, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot allocate angle fixture")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 450))
        context.translateBy(x: 0, y: 450); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: index == lines.count - 1 ? 48 : 56, weight: .medium), .foregroundColor: NSColor.black
            ]).draw(at: CGPoint(x: 40, y: 35 + index * 95))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let source = context.makeImage() else { throw ImageToolsVerificationFailure(description: "Cannot make angle fixture") }
        for angle in [0.0, 90, 180, 270, -5, 5, -12, 12] {
            let image = try rotatedFixture(source, degrees: angle)
            try ImageToolsUI.png(image).write(to: outputDirectory.appendingPathComponent("ocr-angle-\(Int(angle)).png"), options: .atomic)
            // Exercise the actual product worker, including its native result order and one-pass configuration.
            let result = try ImageToolsOCRWorker.read(image)
            let order = orderedCharacterRecall(expected: expected, actual: result)
            let english = unorderedCharacterRecall(expected: expected, actual: result, chinese: false)
            let chinese = unorderedCharacterRecall(expected: expected, actual: result, chinese: true)
            try require(order >= 0.95 && english >= 0.95 && chinese >= 0.95,
                        "Generated angle \(Int(angle)) OCR lost text or reading order (no recognized content logged)")
            print("PASS: generated English/Chinese OCR angle \(Int(angle))°")
        }
    }

    private static func rotatedFixture(_ image: CGImage, degrees: Double) throws -> CGImage {
        let angle = degrees * .pi / 180
        let width = Double(image.width), height = Double(image.height)
        let newWidth = Int(ceil(abs(width * cos(angle)) + abs(height * sin(angle)) - 0.00001))
        let newHeight = Int(ceil(abs(height * cos(angle)) + abs(width * sin(angle)) - 0.00001))
        guard let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImageToolsVerificationFailure(description: "Cannot rotate generated fixture")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        context.translateBy(x: Double(newWidth) / 2, y: Double(newHeight) / 2)
        context.rotate(by: angle)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageToolsVerificationFailure(description: "Cannot create rotated fixture") }
        return result
    }
    private static func normalizedCharacters(_ text: String) -> [Character] {
        Array(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    private static func orderedCharacterRecall(expected: String, actual: String) -> Double {
        let reference = normalizedCharacters(expected), recognized = normalizedCharacters(actual)
        var previous = [Int](repeating: 0, count: recognized.count + 1)
        for a in reference {
            var next = [Int](repeating: 0, count: recognized.count + 1)
            for (index, b) in recognized.enumerated() {
                next[index + 1] = a == b ? previous[index] + 1 : max(previous[index + 1], next[index])
            }
            previous = next
        }
        return Double(previous.last ?? 0) / Double(max(1, reference.count))
    }
    private static func unorderedCharacterRecall(expected: String, actual: String, chinese: Bool) -> Double {
        func included(_ character: Character) -> Bool { chinese == character.unicodeScalars.contains { $0.value > 0x7f } }
        let reference = normalizedCharacters(expected).filter(included)
        var counts: [Character: Int] = [:]
        for character in normalizedCharacters(actual).filter(included) { counts[character, default: 0] += 1 }
        var matched = 0
        for character in reference where counts[character, default: 0] > 0 {
            matched += 1; counts[character, default: 0] -= 1
        }
        return Double(matched) / Double(max(1, reference.count))
    }
}
