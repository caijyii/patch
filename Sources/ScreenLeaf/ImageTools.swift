// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import OSLog
import UniformTypeIdentifiers
import Vision

/// Owns editor, OCR and pin windows so each capture can remain open independently.
@MainActor
final class ImageToolsCoordinator {
    private var windows: [UUID: NSWindowController] = [:]
    private var pins: [UUID: ImageToolsPinController] = [:]
    private var pinsHidden = false
    private var ocrQueue = ImageToolsOCRQueue()
    private var ocrJobs: [UUID: ImageToolsOCRJob] = [:]

    var hasPins: Bool { !pins.isEmpty }
    var arePinsHidden: Bool { hasPins && pinsHidden }

    init() {}

    deinit { ocrJobs.values.forEach { $0.cancel() } }

    func showEditor(_ image: CGImage) {
        let id = UUID()
        let controller = ImageToolsEditorController(image: image)
        controller.onPin = { [weak self] in self?.pinImage($0) }
        controller.onOCR = { [weak self] in self?.recognize($0) }
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func pinImage(_ image: CGImage) {
        let controller = ImageToolsPinController(image: image)
        controller.onOCR = { [weak self] image in self?.recognize(image) }
        addPin(controller)
    }

    func showSubjectSelection(_ image: CGImage) {
        let id = UUID()
        let controller = SubjectSelectionController(image: image)
        controller.onPin = { [weak self] in self?.pinImage($0) }
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Pins and selection state belong only to this running session.
    func closeAll() {
        ocrJobs.values.forEach { $0.cancel() }
        ocrJobs.removeAll()
        let controllers = Array(windows.values) + Array(pins.values)
        windows.removeAll()
        pins.removeAll()
        pinsHidden = false
        controllers.forEach { $0.close() }
    }

    func pinText(_ text: String) {
        addPin(ImageToolsPinController(text: text))
    }

    func pinClipboard() {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            pinImage(cgImage)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            pinText(text)
        } else {
            showError(ScreenLeafError(message: "剪贴板中没有可贴出的图片或文字。"), title: "无法贴出剪贴板")
        }
    }

    func recognize(_ image: CGImage) {
        let id = UUID()
        let controller = ImageToolsOCRController()
        controller.onClose = { [weak self] in
            self?.ocrJobs.removeValue(forKey: id)?.cancel()
            self?.windows.removeValue(forKey: id)
        }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ocrJobs[id] = ocrQueue.enqueue(image) { [weak self, weak controller] result in
            guard let self, self.ocrJobs.removeValue(forKey: id) != nil,
                  self.windows[id] === controller else { return }
            switch result {
            case .success(let text): controller?.complete(text)
            case .failure(let error): controller?.fail(error)
            }
        }
    }

    func togglePins() {
        guard !pins.isEmpty else { return }
        pinsHidden.toggle()
        for controller in pins.values {
            if pinsHidden { controller.window?.orderOut(nil) }
            else { controller.window?.orderFrontRegardless() }
        }
    }

    private func addPin(_ controller: ImageToolsPinController) {
        let id = UUID()
        if pinsHidden {
            pinsHidden = false
            pins.values.forEach { $0.window?.orderFrontRegardless() }
        }
        pins[id] = controller
        controller.onClose = { [weak self] in self?.pins.removeValue(forKey: id) }
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        controller.focusTextIfNeeded()
    }
}

enum ImageToolsTool: String, CaseIterable {
    case arrow = "箭头", rectangle = "方框", ellipse = "圆形", text = "文字"
    case number = "序号", pen = "画笔", mosaic = "马赛克", sticker = "贴纸"
}

struct ImageToolsAnnotation {
    var tool: ImageToolsTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var textWrapWidth: CGFloat? = nil
    var number: Int = 1
    var mosaic: CGImage?
    var fontSize: CGFloat = 30
    /// Diameter of the filled sequence-number circle, in image pixels.
    var numberSize: CGFloat = 42
    var mosaicBlockSize: CGFloat = 24

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }
}

@MainActor
final class ImageToolsCanvas: NSView, NSTextFieldDelegate {
    private final class InlineFieldEditor: NSTextView {
        var onCompositionChange: (() -> Void)?
        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            // Wait until AppKit has finished changing the text storage before layout.
            onCompositionChange?()
        }
    }
    private final class InlineTextCell: NSTextFieldCell {
        let editor = InlineFieldEditor(frame: .zero)
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            editor.isFieldEditor = true
            return editor
        }
        override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
        override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    }
    private func styledText(_ annotation: ImageToolsAnnotation) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: annotation.text, attributes: [
            .font: NSFont.systemFont(ofSize: max(1, annotation.fontSize), weight: .medium),
            .foregroundColor: annotation.color, .paragraphStyle: paragraph])
    }
    private func textSize(_ annotation: ImageToolsAnnotation) -> CGSize {
        let text = styledText(annotation)
        let width = max(1, min(annotation.textWrapWidth ?? .greatestFiniteMagnitude, ceil(text.size().width)))
        let measured = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return CGSize(width: width,
                      height: max(ceil(annotation.fontSize * 1.3), ceil(measured.height)))
    }

    private(set) var source: CGImage
    var tool: ImageToolsTool = .arrow
    var annotationColor = NSColor.systemRed
    var annotationWidth: CGFloat = 6
    var annotationFontSize: CGFloat = 30
    var annotationSticker = "🌼"
    var annotationNumberSize: CGFloat = 42
    var mosaicBlockSize: CGFloat = 24
    var isDrawingEnabled = true
    var onChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onAnnotationSelectionChange: ((ImageToolsAnnotation?) -> Void)?
    /// Optional host action after a double click misses text, ink and selection controls.
    var onBlankDoubleClick: ((CGPoint) -> Bool)?
    /// Image-pixel coordinates, matching bounds even when frame uses screen points.
    var interactionBounds: CGRect?
    private(set) var annotations: [ImageToolsAnnotation] = []
    private var draft: ImageToolsAnnotation?
    private var textEditor: NSTextField?
    private var pendingTextAnnotation: ImageToolsAnnotation?
    private var editingTextIndex: Int?
    private var selectedIndex: Int?
    private struct HistoryState {
        let annotations: [ImageToolsAnnotation]
        let selectedIndex: Int?
    }
    private enum DragKind { case move(anchor: CGPoint), endpoint(Int), corner(Int) }
    private struct AnnotationDrag {
        let annotations: [ImageToolsAnnotation]
        let index: Int
        let kind: DragKind
    }
    private var history: [HistoryState] = []
    private var parameterBaseline: HistoryState?
    func beginParameterEditing() {
        finishTextEditing()
        parameterBaseline = HistoryState(annotations: parameterSnapshot(annotations), selectedIndex: selectedIndex)
    }
    func endParameterEditing() {
        guard let baseline = parameterBaseline else { return }
        parameterBaseline = nil
        if !parametersMatch(baseline.annotations, annotations) { history.append(baseline) }
        changed(); notifySelection()
    }
    private var annotationDrag: AnnotationDrag?
    private var annotationDragChanged = false
    private var cursorTracking: NSTrackingArea?
    var canUndo: Bool { !history.isEmpty }
    var selectedAnnotation: ImageToolsAnnotation? {
        selectedIndex.flatMap { annotations.indices.contains($0) ? annotations[$0] : nil }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        source = image
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        drawContents(includeDraft: true)
        drawSelection()
    }

    private func drawContents(includeDraft: Bool) {
        NSImage(cgImage: source, size: bounds.size).draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for (index, annotation) in annotations.enumerated() where index != editingTextIndex {
            drawAnnotation(annotation)
        }
        if includeDraft, let draft {
            if draft.tool == .mosaic {
                NSColor.selectedControlColor.withAlphaComponent(0.24).setFill()
                NSBezierPath(rect: draft.rect).fill()
                NSColor.selectedControlColor.setStroke()
                NSBezierPath(rect: draft.rect).stroke()
            } else { drawAnnotation(draft) }
        }
    }

    private func drawAnnotation(_ annotation: ImageToolsAnnotation) {
        guard let first = annotation.points.first, let last = annotation.points.last else { return }
        annotation.color.setStroke()
        annotation.color.setFill()
        let path = NSBezierPath()
        path.lineWidth = annotation.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch annotation.tool {
        case .arrow:
            let distance = hypot(last.x - first.x, last.y - first.y)
            guard distance >= 0.5 else { return }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(distance, max(16, annotation.width * 3.5))
            // The shaft ends inside the triangle, so a line cap cannot extend past its tip.
            if distance > length {
                let inset = length * cos(CGFloat.pi / 6)
                path.lineCapStyle = .butt
                path.move(to: first)
                path.line(to: CGPoint(x: last.x - inset * cos(angle), y: last.y - inset * sin(angle)))
                path.stroke()
            }
            let head = NSBezierPath()
            head.move(to: last)
            head.line(to: CGPoint(x: last.x - length * cos(angle - .pi / 6),
                                 y: last.y - length * sin(angle - .pi / 6)))
            head.line(to: CGPoint(x: last.x - length * cos(angle + .pi / 6),
                                 y: last.y - length * sin(angle + .pi / 6)))
            head.close(); head.fill()
        case .rectangle:
            let shape = NSBezierPath(rect: annotation.rect)
            shape.lineWidth = annotation.width; shape.stroke()
        case .ellipse:
            let shape = NSBezierPath(ovalIn: annotation.rect)
            shape.lineWidth = annotation.width; shape.stroke()
        case .pen:
            path.move(to: first)
            for point in annotation.points.dropFirst() { path.line(to: point) }
            if annotation.points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: first.x - annotation.width / 2,
                                           y: first.y - annotation.width / 2,
                                           width: annotation.width, height: annotation.width)).fill()
            } else { path.stroke() }
        case .text:
            styledText(annotation).draw(with: annotationFrame(annotation),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
        case .sticker:
            if !StickerCatalog.draw(annotation.text, in: annotationFrame(annotation)) {
                stickerText(annotation).draw(in: annotationFrame(annotation))
            }
        case .number:
            let radius = max(1, annotation.numberSize / 2)
            NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius,
                                       width: radius * 2, height: radius * 2)).fill()
            let text = NSAttributedString(string: String(annotation.number), attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2))
        case .mosaic:
            if let patch = annotation.mosaic {
                // An opaque raster patch replaces this part of the source in every export.
                NSImage(cgImage: patch, size: annotation.rect.size).draw(
                    in: annotation.rect, from: .zero, operation: .copy,
                    fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        cursorTracking = tracking
    }

    override func cursorUpdate(with event: NSEvent) {
        if annotationDrag == nil, let content = window?.contentView {
            let point = content.convert(event.locationInWindow, from: nil)
            guard let hit = content.hitTest(content.convert(point, to: content.superview)),
                  hit === self || hit.isDescendant(of: self) else { return }
        }
        let point = convert(event.locationInWindow, from: nil)
        if let drag = annotationDrag {
            switch drag.kind {
            case .move: NSCursor.closedHand.set()
            case .corner(let corner): resizeCursor(for: corner).set()
            case .endpoint: NSCursor.crosshair.set()
            }
        } else if let textEditor, textEditor.frame.contains(point) {
            NSCursor.iBeam.set()
        } else if let control = selectedControl(at: point) {
            (selectedAnnotation?.tool == .arrow ? NSCursor.crosshair : resizeCursor(for: control)).set()
        } else if annotationIndex(at: point) != nil {
            NSCursor.openHand.set()
        } else {
            (isDrawingEnabled ? (tool == .text ? NSCursor.iBeam : NSCursor.crosshair) : NSCursor.arrow).set()
        }
    }

    private func resizeCursor(for corner: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        return NSCursor.frameResize(position: positions[corner], directions: .all)
    }

    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }

    override func mouseDown(with event: NSEvent) {
        defer { cursorUpdate(with: event) }
        finishTextEditing()
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let selectedIndex, let control = selectedControl(at: point) {
            let kind: DragKind = annotations[selectedIndex].tool == .arrow ? .endpoint(control) : .corner(control)
            annotationDrag = AnnotationDrag(annotations: annotations, index: selectedIndex, kind: kind)
            annotationDragChanged = false
            return
        }
        if let index = annotationIndex(at: point) {
            selectAnnotation(index)
            if event.clickCount >= 2, annotations[index].tool == .text {
                beginTextEditing(at: annotations[index].points[0], annotationIndex: index)
            } else {
                annotationDrag = AnnotationDrag(annotations: annotations, index: index, kind: .move(anchor: point))
                annotationDragChanged = false
            }
            return
        }
        if event.clickCount >= 2, onBlankDoubleClick?(point) == true { return }
        selectAnnotation(nil)
        guard isDrawingEnabled else { return }
        if tool == .text {
            beginTextEditing(at: point)
            return
        }
        if tool == .sticker {
            var annotation = ImageToolsAnnotation(tool: .sticker, points: [point], color: annotationColor,
                width: annotationWidth, text: annotationSticker, fontSize: annotationFontSize)
            let frame = annotationFrame(annotation)
            let delta = boundedDelta(.zero, for: frame)
            annotation.points = [CGPoint(x: point.x + delta.width, y: point.y + delta.height)]
            attempt { try commitAnnotations(annotations + [annotation], selecting: annotations.count) }
            return
        }
        if tool == .number {
            let number = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
            let annotation = ImageToolsAnnotation(tool: tool, points: [point],
                color: annotationColor, width: annotationWidth, number: number, numberSize: annotationNumberSize)
            attempt { try commitAnnotations(annotations + [annotation], selecting: annotations.count) }
            return
        }
        draft = ImageToolsAnnotation(tool: tool, points: [point, point],
                                    color: annotationColor, width: annotationWidth, mosaicBlockSize: mosaicBlockSize)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        defer { cursorUpdate(with: event) }
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let drag = annotationDrag {
            var proposed = drag.annotations
            let original = proposed[drag.index]
            switch drag.kind {
            case .move(let anchor):
                let frame = annotationFrame(original)
                let delta = boundedDelta(CGSize(width: point.x - anchor.x, height: point.y - anchor.y), for: frame)
                proposed[drag.index].points = original.points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
            case .endpoint(let endpoint):
                proposed[drag.index].points[endpoint] = point
            case .corner(let corner):
                let old = original.rect
                let resized = resizedRect(old, corner: corner, to: point)
                proposed[drag.index].points = original.points.map { p in
                    CGPoint(x: resized.minX + (old.width > 0 ? (p.x - old.minX) / old.width : 0.5) * resized.width,
                            y: resized.minY + (old.height > 0 ? (p.y - old.minY) / old.height : 0.5) * resized.height)
                }
            }
            if parametersMatch(annotations, proposed) {
                annotationDragChanged = !parametersMatch(drag.annotations, proposed)
                return
            }
            attempt {
                let rebuilt = try rebuildingMosaics(proposed)
                annotations = rebuilt
                annotationDragChanged = !parametersMatch(drag.annotations, proposed)
                changed()
                notifySelection()
            }
            return
        }
        guard draft != nil else { return }
        if draft?.tool == .pen { draft?.points.append(point) }
        else { draft?.points[1] = point }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { cursorUpdate(with: event) }
        if annotationDrag != nil {
            mouseDragged(with: event)
            finishAnnotationDrag()
            return
        }
        guard var annotation = draft else { return }
        draft = nil
        let point = clamped(convert(event.locationInWindow, from: nil))
        if annotation.tool == .pen { annotation.points.append(point) }
        else { annotation.points[1] = point }
        if annotation.tool == .mosaic {
            let rect = annotation.rect.integral.intersection(bounds)
            guard rect.width >= 2, rect.height >= 2 else { needsDisplay = true; return }
            annotation.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
        } else if annotation.tool != .pen && annotation.rect.width + annotation.rect.height < 2 {
            needsDisplay = true; return
        }
        attempt { try commitAnnotations(annotations + [annotation], selecting: annotations.count) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if !cancelAnnotationEditing() { onCancel?() }
        }
        else if event.keyCode == 51 || event.keyCode == 117 { deleteSelectedAnnotation() }
        else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" { undoAnnotation() }
        else { super.keyDown(with: event) }
    }

    func undoAnnotation() {
        finishTextEditing()
        if annotationDrag != nil { _ = cancelAnnotationEditing(); return }
        guard let state = history.last else { return }
        attempt {
            let restored = try rebuildingMosaics(state.annotations)
            history.removeLast()
            annotations = restored
            selectedIndex = state.selectedIndex
            changed()
            notifySelection()
        }
    }

    func clearAnnotations() {
        cancelTextEditing()
        annotations.removeAll()
        history.removeAll()
        annotationDrag = nil
        annotationDragChanged = false
        draft = nil
        selectedIndex = nil
        changed()
        notifySelection()
    }

    /// Updates the underlying subject image without discarding annotations or their undo history.
    func replaceSourcePreservingAnnotations(_ image: CGImage) throws {
        guard image.width == source.width, image.height == source.height else {
            throw ScreenLeafError(message: "更新图片的像素尺寸必须保持一致。")
        }
        finishTextEditing()
        finishAnnotationDrag()
        let previous = source
        source = image
        do { annotations = try rebuildingMosaics(annotations) }
        catch { source = previous; throw error }
        changed()
        notifySelection()
    }

    /// The crop uses top-left image pixels, as CGImage.cropping(to:) does.
    /// Unannotated captures render directly into a region-sized buffer. Marked
    /// captures preserve the original rasterization and copy only the selected
    /// rows, so neither path retains a full-screen intermediate in a small pin.
    func renderedImage(croppingTo pixelRect: CGRect? = nil) throws -> CGImage {
        finishTextEditing()
        finishAnnotationDrag()
        return try rasterized(annotations, croppingTo: pixelRect)
    }

    private func rasterized(_ items: [ImageToolsAnnotation], croppingTo pixelRect: CGRect? = nil) throws -> CGImage {
        guard items.allSatisfy({ $0.tool != .mosaic || $0.mosaic != nil }) else {
            throw ScreenLeafError(message: "马赛克尚未完成，无法导出图片。")
        }
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let region: CGRect
        if let pixelRect {
            guard pixelRect.origin.x.isFinite, pixelRect.origin.y.isFinite,
                  pixelRect.width.isFinite, pixelRect.height.isFinite,
                  pixelRect.width > 0, pixelRect.height > 0 else {
                throw ScreenLeafError(message: "无法读取选区，请重新选取。")
            }
            region = pixelRect.integral.intersection(imageBounds)
            guard !region.isNull, !region.isEmpty else {
                throw ScreenLeafError(message: "无法读取选区，请重新选取。")
            }
        } else { region = imageBounds }
        // CoreGraphics can round stroke coverage differently when the bitmap's
        // clipping bounds change. Keep the original bounds for annotations so
        // edge antialiasing remains pixel-identical to the full-image export.
        let renderRegion = items.isEmpty ? region : imageBounds
        guard let context = CGContext(data: nil, width: Int(renderRegion.width), height: Int(renderRegion.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenLeafError(message: "图片过大，无法分配导出内存。")
        }
        // Preserve the canvas's top-left document coordinates.
        context.translateBy(x: -renderRegion.minX, y: renderRegion.maxY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSImage(cgImage: source, size: bounds.size).draw(
            in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        items.forEach(drawAnnotation)
        NSGraphicsContext.restoreGraphicsState()
        if renderRegion != region {
            guard let cropped = CGContext(data: nil, width: Int(region.width), height: Int(region.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let input = context.data, let output = cropped.data else {
                throw ScreenLeafError(message: "图片过大，无法分配导出内存。")
            }
            let offset = Int(region.minY) * context.bytesPerRow + Int(region.minX) * 4
            for row in 0..<Int(region.height) {
                output.advanced(by: row * cropped.bytesPerRow).copyMemory(
                    from: input.advanced(by: offset + row * context.bytesPerRow), byteCount: Int(region.width) * 4)
            }
            guard let result = cropped.makeImage() else {
                throw ScreenLeafError(message: "无法导出标注后的图片。")
            }
            return result
        }
        guard let result = context.makeImage() else {
            throw ScreenLeafError(message: "无法导出标注后的图片。")
        }
        return result
    }

    private func mosaicPatch(in rect: CGRect, blockSize: CGFloat, baseImage: CGImage? = nil) throws -> CGImage {
        // Work on a copied 8-bit raster so exports contain only the replacement pixels.
        guard blockSize.isFinite, blockSize >= 2, blockSize <= CGFloat(Int.max / 2) else {
            throw ScreenLeafError(message: "马赛克块大小无效，请选择有效大小。")
        }
        guard let crop = try (baseImage ?? rasterized(annotations)).cropping(to: rect) else {
            throw ScreenLeafError(message: "无法读取马赛克选区。")
        }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        guard let bytes = bitmap.bitmapData, bitmap.bitsPerSample == 8,
              bitmap.bitsPerPixel == bitmap.samplesPerPixel * 8, !bitmap.isPlanar else {
            throw ScreenLeafError(message: "无法处理马赛克选区的像素格式。")
        }
        let step = max(2, Int(blockSize.rounded()))
        let channels = bitmap.samplesPerPixel
        for startY in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for startX in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                let endX = min(startX + step, bitmap.pixelsWide)
                let endY = min(startY + step, bitmap.pixelsHigh)
                var sums = [UInt64](repeating: 0, count: channels)
                for y in startY..<endY {
                    for x in startX..<endX {
                        let offset = y * bitmap.bytesPerRow + x * channels
                        for channel in 0..<channels { sums[channel] += UInt64(bytes[offset + channel]) }
                    }
                }
                let count = UInt64((endX - startX) * (endY - startY))
                let average = sums.map { UInt8($0 / count) }
                for y in startY..<endY {
                    for x in startX..<endX {
                        let offset = y * bitmap.bytesPerRow + x * channels
                        for channel in 0..<channels { bytes[offset + channel] = average[channel] }
                    }
                }
            }
        }
        guard let patch = bitmap.cgImage else {
            throw ScreenLeafError(message: "无法生成马赛克图片。")
        }
        return patch
    }

    func annotationContains(_ point: CGPoint) -> Bool {
        if let textEditor, textEditor.frame.contains(point) { return true }
        return selectedControl(at: point) != nil || annotationIndex(at: point) != nil
    }

    func deselectAnnotation() {
        finishTextEditing()
        finishAnnotationDrag()
        selectAnnotation(nil)
    }

    @discardableResult
    func cancelAnnotationEditing() -> Bool {
        if textEditor != nil { cancelTextEditing(); return true }
        if let drag = annotationDrag {
            annotations = drag.annotations
            annotationDrag = nil
            annotationDragChanged = false
            changed()
            notifySelection()
            return true
        }
        if draft != nil { draft = nil; needsDisplay = true; return true }
        if selectedIndex != nil { selectAnnotation(nil); return true }
        return false
    }

    func deleteSelectedAnnotation() {
        finishTextEditing()
        finishAnnotationDrag()
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        var proposed = annotations
        proposed.remove(at: index)
        attempt { try commitAnnotations(proposed, selecting: nil) }
    }

    func updateSelectedAnnotation(color: NSColor? = nil, width: CGFloat? = nil,
                                  fontSize: CGFloat? = nil, numberSize: CGFloat? = nil,
                                  mosaicBlockSize: CGFloat? = nil, sticker: String? = nil) {
        finishTextEditing()
        finishAnnotationDrag()
        guard let index = selectedIndex, annotations.indices.contains(index) else { return }
        attempt {
            for value in [width, fontSize, numberSize].compactMap({ $0 }) {
                guard value.isFinite, value > 0 else { throw ScreenLeafError(message: "标注大小无效，请选择有效大小。") }
            }
            if let block = mosaicBlockSize, !block.isFinite || block < 2 {
                throw ScreenLeafError(message: "马赛克块大小无效，请选择有效大小。")
            }
            var proposed = annotations
            if let sticker, proposed[index].tool == .sticker {
                guard StickerCatalog.item(for: sticker) != nil || sticker.count == 1 else {
                    throw ScreenLeafError(message: "请选择一张有效贴纸。")
                }
                proposed[index].text = StickerCatalog.canonicalIdentifier(sticker)
            }
            if let color { proposed[index].color = color }
            if let width { proposed[index].width = width }
            if let fontSize { proposed[index].fontSize = fontSize }
            if let numberSize { proposed[index].numberSize = numberSize }
            if let mosaicBlockSize { proposed[index].mosaicBlockSize = mosaicBlockSize }
            try commitAnnotations(proposed, selecting: index)
        }
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() }
        catch {
            needsDisplay = true
            if let onError { onError(error) } else { showError(error) }
        }
    }

    private func parameterSnapshot(_ items: [ImageToolsAnnotation]) -> [ImageToolsAnnotation] {
        items.map { annotation in var copy = annotation; copy.mosaic = nil; return copy }
    }

    private func parametersMatch(_ lhs: [ImageToolsAnnotation], _ rhs: [ImageToolsAnnotation]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.tool == b.tool && a.points == b.points && a.color.isEqual(b.color) && a.width == b.width
                && a.text == b.text && a.textWrapWidth == b.textWrapWidth && a.number == b.number && a.fontSize == b.fontSize
                && a.numberSize == b.numberSize && a.mosaicBlockSize == b.mosaicBlockSize
        }
    }

    private func commitAnnotations(_ proposed: [ImageToolsAnnotation], selecting index: Int?) throws {
        guard !parametersMatch(annotations, proposed) else { selectAnnotation(index); return }
        // Build all replacement patches first. Failure leaves the last valid document intact.
        let rebuilt = try rebuildingMosaics(proposed)
        if parameterBaseline == nil { history.append(HistoryState(annotations: parameterSnapshot(annotations), selectedIndex: selectedIndex)) }
        annotations = rebuilt
        selectedIndex = index
        changed()
        notifySelection()
    }

    private func rebuildingMosaics(_ proposed: [ImageToolsAnnotation]) throws -> [ImageToolsAnnotation] {
        var result: [ImageToolsAnnotation] = []
        for var annotation in proposed {
            if annotation.tool == .mosaic {
                let rect = annotation.rect.integral.intersection(bounds)
                guard !rect.isNull, rect.width >= 2, rect.height >= 2 else {
                    throw ScreenLeafError(message: "马赛克区域太小或不在图片中，请调整选区。")
                }
                annotation.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
                annotation.mosaic = try mosaicPatch(in: rect, blockSize: annotation.mosaicBlockSize,
                                                   baseImage: rasterized(result))
            }
            result.append(annotation)
        }
        return result
    }

    private func finishAnnotationDrag() {
        guard let drag = annotationDrag else { return }
        annotationDrag = nil
        if annotationDragChanged {
            history.append(HistoryState(annotations: parameterSnapshot(drag.annotations), selectedIndex: drag.index))
        }
        annotationDragChanged = false
        changed()
        notifySelection()
    }

    private func selectAnnotation(_ index: Int?) {
        selectedIndex = index
        needsDisplay = true
        notifySelection()
    }

    private func notifySelection() { onAnnotationSelectionChange?(selectedAnnotation) }

    private var controlRadius: CGFloat {
        6 * max(bounds.width / max(1, frame.width), bounds.height / max(1, frame.height))
    }

    private func controlPoints(_ annotation: ImageToolsAnnotation) -> [CGPoint] {
        switch annotation.tool {
        case .arrow: return annotation.points
        case .rectangle, .ellipse, .mosaic, .pen:
            let rect = annotation.rect
            return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        case .text, .number, .sticker: return []
        }
    }

    private func selectedControl(at point: CGPoint) -> Int? {
        guard let annotation = selectedAnnotation else { return nil }
        return controlPoints(annotation).firstIndex { hypot(point.x - $0.x, point.y - $0.y) <= controlRadius }
    }

    private func annotationFrame(_ annotation: ImageToolsAnnotation) -> CGRect {
        guard let point = annotation.points.first else { return .zero }
        switch annotation.tool {
        case .text:
            return CGRect(origin: point, size: textSize(annotation))
        case .number:
            let radius = max(1, annotation.numberSize / 2)
            return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        case .sticker:
            let side = max(1, annotation.fontSize)
            let size = StickerCatalog.hasVector(annotation.text) ? CGSize(width: side, height: side) : stickerText(annotation).size()
            return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                          width: max(1, size.width), height: max(1, size.height))
        case .arrow:
            guard let last = annotation.points.last else { return .zero }
            let angle = atan2(last.y - point.y, last.x - point.x)
            let length = min(hypot(last.x - point.x, last.y - point.y), max(16, annotation.width * 3.5))
            var expanded = annotation
            expanded.points += [CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)),
                                CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6))]
            return expanded.rect.insetBy(dx: -annotation.width / 2, dy: -annotation.width / 2)
        case .mosaic: return annotation.rect
        default: return annotation.rect.insetBy(dx: -annotation.width / 2, dy: -annotation.width / 2)
        }
    }

    private func stickerText(_ annotation: ImageToolsAnnotation) -> NSAttributedString {
        let size = max(1, annotation.fontSize)
        let font = NSFont(name: "Apple Color Emoji", size: size) ?? NSFont.systemFont(ofSize: size)
        return NSAttributedString(string: StickerCatalog.item(for: annotation.text)?.emoji ?? annotation.text,
                                  attributes: [.font: font])
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { contains(point, annotation: annotations[$0]) }
    }

    private func distance(_ point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let square = dx * dx + dy * dy
        let t = square > 0 ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / square)) : 0
        return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
    }

    private func contains(_ point: CGPoint, annotation: ImageToolsAnnotation) -> Bool {
        guard let first = annotation.points.first, let last = annotation.points.last else { return false }
        let tolerance = max(controlRadius, annotation.width / 2 + 2)
        switch annotation.tool {
        case .text, .mosaic, .sticker: return annotationFrame(annotation).insetBy(dx: -2, dy: -2).contains(point)
        case .number: return hypot(point.x - first.x, point.y - first.y) <= annotation.numberSize / 2 + 2
        case .rectangle:
            let rect = annotation.rect
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                && !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .ellipse:
            let rect = annotation.rect
            guard rect.width > 0, rect.height > 0 else { return false }
            let normalized = hypot((point.x - rect.midX) / (rect.width / 2), (point.y - rect.midY) / (rect.height / 2))
            return abs(normalized - 1) * min(rect.width, rect.height) / 2 <= tolerance
        case .pen:
            if annotation.points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= tolerance }
            return zip(annotation.points, annotation.points.dropFirst()).contains { distance(point, toSegment: $0, $1) <= tolerance }
        case .arrow:
            if distance(point, toSegment: first, last) <= tolerance { return true }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(hypot(last.x - first.x, last.y - first.y), max(16, annotation.width * 3.5))
            let head = NSBezierPath()
            head.move(to: last)
            head.line(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
            head.line(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
            head.close()
            return head.contains(point)
        }
    }

    private func boundedDelta(_ delta: CGSize, for rect: CGRect) -> CGSize {
        let area = editableBounds
        return CGSize(width: min(max(delta.width, area.minX - rect.minX), max(area.minX - rect.minX, area.maxX - rect.maxX)),
                      height: min(max(delta.height, area.minY - rect.minY), max(area.minY - rect.minY, area.maxY - rect.maxY)))
    }

    private func resizedRect(_ rect: CGRect, corner: Int, to point: CGPoint) -> CGRect {
        let left = corner == 0 || corner == 3
        let top = corner == 0 || corner == 1
        let x = left ? min(point.x, rect.maxX - 2) : max(point.x, rect.minX + 2)
        let y = top ? min(point.y, rect.maxY - 2) : max(point.y, rect.minY + 2)
        let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
        return CGRect(x: min(x, anchor.x), y: min(y, anchor.y), width: abs(x - anchor.x), height: abs(y - anchor.y))
    }

    private func drawSelection() {
        guard let annotation = selectedAnnotation else { return }
        let frame = annotationFrame(annotation).insetBy(dx: -2, dy: -2)
        let path = NSBezierPath(rect: frame)
        path.lineWidth = max(1, controlRadius / 6)
        path.setLineDash([controlRadius * 0.7, controlRadius * 0.5], count: 2, phase: 0)
        ToolbarPalette.accent.setStroke()
        path.stroke()
        for point in controlPoints(annotation) {
            let size = controlRadius * 1.2
            let handle = NSBezierPath(rect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            NSColor.white.setFill(); handle.fill()
            ToolbarPalette.accent.setStroke(); handle.lineWidth = path.lineWidth; handle.stroke()
        }
    }

    private var editableBounds: CGRect {
        let area = (interactionBounds ?? bounds).intersection(bounds)
        return area.isNull || area.isEmpty ? bounds : area
    }

    private func beginTextEditing(at point: CGPoint, annotationIndex index: Int? = nil) {
        let area = editableBounds
        var annotation = index.map { annotations[$0] } ?? ImageToolsAnnotation(tool: .text, points: [point],
            color: annotationColor, width: annotationWidth, fontSize: annotationFontSize)
        let font = NSFont.systemFont(ofSize: max(1, annotation.fontSize), weight: .medium)
        let origin = CGPoint(x: max(area.minX, min(point.x, area.maxX - min(24, area.width))),
                             y: max(area.minY, min(point.y, area.maxY - min(font.pointSize * 1.3, area.height))))
        annotation.textWrapWidth = min(annotation.textWrapWidth ?? area.width, area.maxX - origin.x)
        let input = NSTextField(frame: CGRect(origin: origin, size: textSize(annotation)))
        let cell = InlineTextCell(textCell: "")
        cell.editor.onCompositionChange = { [weak self] in self?.resizeTextEditor() }
        input.cell = cell
        input.font = font
        input.textColor = annotation.color
        input.stringValue = annotation.text
        input.isBezeled = false
        input.isBordered = false
        input.focusRingType = .none
        input.cell?.wraps = true
        input.cell?.isScrollable = false
        input.cell?.usesSingleLineMode = false
        input.lineBreakMode = .byWordWrapping
        input.isEditable = true
        input.isSelectable = true
        input.backgroundColor = .clear
        input.drawsBackground = false
        input.delegate = self
        if index == nil { annotation.points = [origin] }
        pendingTextAnnotation = annotation
        editingTextIndex = index
        textEditor = input
        addSubview(input)
        window?.makeFirstResponder(input)
        if let editor = input.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            editor.defaultParagraphStyle = paragraph
        }
        resizeTextEditor()
    }

    private func resizeTextEditor() {
        guard let input = textEditor, var annotation = pendingTextAnnotation else { return }
        annotation.text = input.currentEditor()?.string ?? input.stringValue
        let size = textSize(annotation)
        input.setFrameSize(CGSize(width: min(annotation.textWrapWidth ?? size.width, max(24, size.width)),
                                  height: size.height))
        if let editor = input.currentEditor() as? NSTextView {
            editor.textContainer?.containerSize = CGSize(width: input.bounds.width, height: .greatestFiniteMagnitude)
            editor.frame = input.bounds
        }
    }

    func controlTextDidChange(_ notification: Notification) { resizeTextEditor() }

    /// Flush the field editor before exporting, changing the selection, or undoing.
    func finishTextEditing() {
        endTextEditing(commit: true)
    }

    private func cancelTextEditing() {
        endTextEditing(commit: false)
    }

    private func endTextEditing(commit: Bool) {
        guard let input = textEditor, var annotation = pendingTextAnnotation else { return }
        let editor = input.currentEditor()
        let text = editor?.string ?? input.stringValue
        textEditor = nil
        pendingTextAnnotation = nil
        let index = editingTextIndex
        editingTextIndex = nil
        input.delegate = nil
        if let editor, window?.firstResponder === editor {
            window?.makeFirstResponder(self)
        }
        input.removeFromSuperview()
        if commit, index != nil || !text.isEmpty {
            annotation.text = text
            var proposed = annotations
            let selection: Int?
            if let index {
                if text.isEmpty { proposed.remove(at: index); selection = nil }
                else { proposed[index] = annotation; selection = index }
            } else { proposed.append(annotation); selection = proposed.count - 1 }
            attempt { try commitAnnotations(proposed, selecting: selection) }
        } else { needsDisplay = true }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishTextEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || (commandSelector == #selector(NSResponder.insertNewline(_:))
                && NSApp.currentEvent?.modifierFlags.contains(.shift) == true) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            resizeTextEditor()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishTextEditing()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let area = editableBounds
        return CGPoint(x: min(max(point.x, area.minX), area.maxX),
                       y: min(max(point.y, area.minY), area.maxY))
    }
    private func changed() { needsDisplay = true; onChange?() }
}

@MainActor
private final class ImageToolsEditorController: NSWindowController, NSWindowDelegate {
    var onPin: ((CGImage) -> Void)?
    var onOCR: ((CGImage) -> Void)?
    var onApply: ((CGImage) -> Void)?
    var onClose: (() -> Void)?
    private let canvas: ImageToolsCanvas
    private let scroll = NSScrollView()
    private let toolbar = SelectionToolbar()
    private var controls: AnnotationControls!
    private var actions: [NSView] = []
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private let appliesToPin: Bool

    init(image: CGImage, preferences: PreferencesStore? = nil, appliesToPin: Bool = false) {
        canvas = ImageToolsCanvas(image: image)
        self.appliesToPin = appliesToPin
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(max(740, CGFloat(image.width) + 24), min(1040, visible.width - 100))
        let height = min(max(360, CGFloat(image.height) + 180), min(760, visible.height - 100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appliesToPin ? "小贴 · 标注贴图" : "小贴 · 截图标注"
        window.minSize = CGSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setup(preferences: preferences)
        window.center()
        scroll.magnification = max(0.05, min(1, (width - 24) / CGFloat(image.width)))
        updateZoom()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup(preferences: PreferencesStore?) {
        guard let content = window?.contentView else { return }
        controls = AnnotationControls(canvas: canvas, preferences: preferences, scale: { [weak self] in
            // Canvas units are image pixels; magnification maps them to visible screen points.
            1 / max(0.05, self?.scroll.magnification ?? 1)
        })
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.05; scroll.maxMagnification = 8
        scroll.documentView = canvas
        scroll.backgroundColor = .windowBackgroundColor
        content.addSubview(scroll)
        content.addSubview(toolbar)
        let save = SelectionButton("保存", symbol: "square.and.arrow.down") { [weak self] in self?.saveImage() }
        save.toolTip = "保存 PNG"
        actions = [
            SelectionButton("复制", symbol: "doc.on.doc") { [weak self] in self?.copyImage() },
            save
        ]
        if !appliesToPin {
            let pin = SelectionButton("贴图", symbol: "pin") { [weak self] in self?.pinImage() }
            pin.toolTip = "将图片贴到屏幕"
            actions.append(pin)
        }
        let ocr = SelectionButton("文字", symbol: "text.viewfinder") { [weak self] in self?.ocr() }
        ocr.toolTip = "提取图片中的文字"
        actions.append(ocr)
        for case let button as NSButton in actions { button.imagePosition = .imageOnly }
        let minus = SelectionButton("缩小", symbol: "minus.magnifyingglass") { [weak self] in self?.zoomOut() }
        let plus = SelectionButton("放大", symbol: "plus.magnifyingglass") { [weak self] in self?.zoomIn() }
        minus.imagePosition = .imageOnly; plus.imagePosition = .imageOnly
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = ToolbarPalette.secondaryInk
        actions += [minus, zoomLabel, plus]
        if appliesToPin {
            actions.append(SelectionButton("应用到贴图", symbol: "checkmark") { [weak self] in self?.applyImage() })
        }
        controls.onUpdate = { [weak self] in self?.layoutEditor() }
        canvas.onChange = { [weak self] in self?.controls.refresh(); self?.layoutEditor() }
        controls.choose(tool: .arrow)
        NotificationCenter.default.addObserver(self, selector: #selector(updateZoom),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        layoutEditor()
    }

    private func layoutEditor() {
        guard let content = window?.contentView, controls != nil else { return }
        toolbar.rows = controls.rows(appendingActions: actions)
        let size = toolbar.arrange(maxWidth: max(40, content.bounds.width - 24))
        toolbar.frame = CGRect(x: 12, y: max(0, content.bounds.height - size.height - 10), width: size.width, height: size.height)
        scroll.frame = CGRect(x: 0, y: 0, width: content.bounds.width,
                              height: max(0, toolbar.frame.minY - 10))
    }
    func windowDidResize(_ notification: Notification) { layoutEditor() }
    @objc private func undo() { canvas.undoAnnotation() }
    @objc private func zoomOut() { scroll.magnification = max(scroll.minMagnification, scroll.magnification / 1.25); updateZoom() }
    @objc private func zoomIn() { scroll.magnification = min(scroll.maxMagnification, scroll.magnification * 1.25); updateZoom() }
    @objc private func updateZoom() {
        zoomLabel.stringValue = "\(Int((scroll.magnification * 100).rounded()))%"
        controls?.displayScaleDidChange()
        layoutEditor()
    }
    @objc private func copyImage() { exporting { try ImageToolsUI.copyPNG($0) } }
    @objc private func saveImage() {
        exporting { image in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
            if panel.runModal() == .OK, let url = panel.url { try ImageToolsUI.png(image).write(to: url, options: .atomic) }
        }
    }
    @objc private func pinImage() { exporting { self.onPin?($0) } }
    @objc private func ocr() { exporting { self.onOCR?($0) } }
    @objc private func applyImage() {
        do { let image = try canvas.renderedImage(); onApply?(image); close() }
        catch { showError(error) }
    }
    private func exporting(_ action: (CGImage) throws -> Void) {
        do { try action(canvas.renderedImage()) }
        catch { showError(error) }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// A document-sized canvas hosted by the existing pin or capture panel.
/// Scrolling/magnification affect the viewport, never the exported pixel dimensions.
@MainActor
final class InlineAnnotationView: NSView {
    let canvas: ImageToolsCanvas
    let scroll = NSScrollView()
    private let toolbar = SelectionToolbar()
    private(set) var controls: AnnotationControls!
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var actions: [NSView] = []
    private var arranging = false
    private var completing = false
    var onComplete: ((CGImage) throws -> Void)?
    var onCancel: (() -> Void)?
    var onError: (Error) -> Void = { showError($0) }

    init(image: CGImage, preferences: PreferencesStore? = nil, moveHandle: NSView? = nil,
         completionHint: String) {
        canvas = ImageToolsCanvas(image: image)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true
        scroll.minMagnification = 0.02; scroll.maxMagnification = 8
        scroll.documentView = canvas
        addSubview(scroll); addSubview(toolbar)
        controls = AnnotationControls(canvas: canvas, preferences: preferences, scale: { [weak self] in
            1 / max(0.02, self?.scroll.magnification ?? 1)
        })
        func icon(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSButton {
            let button = SelectionButton(title, symbol: symbol, action: action)
            button.imagePosition = .imageOnly
            return button
        }
        if let moveHandle { actions.append(moveHandle) }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        actions += [icon("缩小", "minus.magnifyingglass") { [weak self] in self?.zoom(by: 1 / 1.25) },
                    zoomLabel, icon("放大", "plus.magnifyingglass") { [weak self] in self?.zoom(by: 1.25) },
                    SelectionButton("适合宽度") { [weak self] in self?.fitWidth() },
                    SelectionButton("100%") { [weak self] in self?.setZoom(1) },
                    icon("复制", "doc.on.doc") { [weak self] in self?.copyImage() },
                    icon("保存 PNG", "square.and.arrow.down") { [weak self] in self?.saveImage() },
                    SelectionButton.cancellation(toolTip: "退出标注，保留原图") { [weak self] in self?.onCancel?() },
                    SelectionButton.confirmation(toolTip: completionHint) { [weak self] in self?.complete() }]
        controls.onUpdate = { [weak self] in self?.refresh() }
        canvas.onChange = { [weak self] in self?.controls.refresh(); self?.refresh() }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        controls.choose(tool: .arrow)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func refresh() { needsLayout = true; layoutSubtreeIfNeeded() }
    override func layout() {
        super.layout()
        guard !arranging, controls != nil else { return }
        arranging = true; defer { arranging = false }
        toolbar.rows = controls.rows(appendingActions: actions)
        let size = toolbar.arrange(maxWidth: max(40, bounds.width - 16))
        toolbar.frame = CGRect(x: 8, y: max(0, bounds.height - size.height - 8), width: size.width, height: size.height)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, toolbar.frame.minY - 8))
    }
    func fitWidth() {
        refresh()
        setZoom(min(1, max(1, scroll.contentSize.width - 16) / CGFloat(canvas.source.width)))
    }
    func setZoom(_ value: CGFloat) {
        let center = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        scroll.setMagnification(min(8, max(0.02, value)), centeredAt: center)
        zoomChanged()
    }
    private func zoom(by factor: CGFloat) { setZoom(scroll.magnification * factor) }
    @objc private func zoomChanged() {
        zoomLabel.stringValue = "\(Int((scroll.magnification * 100).rounded()))%"
        controls.displayScaleDidChange(); refresh()
    }
    func complete() {
        guard !completing, let onComplete else { return }
        completing = true
        do { try onComplete(canvas.renderedImage()) }
        catch { completing = false; onError(error) }
    }
    private func copyImage() {
        do { try ImageToolsUI.copyPNG(canvas.renderedImage()) } catch { onError(error) }
    }
    private func saveImage() {
        do {
            let image = try canvas.renderedImage()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
            if panel.runModal() == .OK, let url = panel.url { try ImageToolsUI.png(image).write(to: url, options: .atomic) }
        } catch { onError(error) }
    }
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        // Native text input owns selection, composition, undo and Esc while editing.
        if window?.firstResponder is NSTextView { return false }
        if event.keyCode == 53 {
            if !canvas.cancelAnnotationEditing() { onCancel?() }
            return true
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": canvas.undoAnnotation(); return true
            case "c": copyImage(); return true
            case "s": saveImage(); return true
            default: break
            }
        }
        return false
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

private final class ImageToolsPinPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class ImageToolsPinImageView: NSView {
    var image: CGImage
    var onMenu: (() -> NSMenu)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
        toolTip = "拖动移动 · 滚轮或捏合缩放 · 右键操作"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero,
            operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
            super.scrollWheel(with: event)
        } else {
            let speed: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
            onZoom?(exp(max(-40, min(40, event.scrollingDeltaY)) * speed), convert(event.locationInWindow, from: nil))
        }
    }
    override func magnify(with event: NSEvent) {
        onZoom?(max(0.1, 1 + event.magnification), convert(event.locationInWindow, from: nil))
    }
}

@MainActor
private final class ImageToolsPinTextView: NSTextView {
    var onMenu: (() -> NSMenu)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onSelect: (() -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var isMoving = true
    var onBeginEditing: (() -> Void)?
    private var movingGesture = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if isMoving && event.clickCount == 2 && !event.modifierFlags.contains(.option) { onBeginEditing?() }
        movingGesture = isMoving || event.modifierFlags.contains(.option)
        if movingGesture { NSCursor.closedHand.set(); onMouseDown?(event) }
        else { onSelect?(); super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if movingGesture { onMouseDragged?(event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if movingGesture { onMouseUp?(event); movingGesture = false; NSCursor.openHand.set() } else { super.mouseUp(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isMoving ? .openHand : .iBeam) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) { super.scrollWheel(with: event) }
        else {
            let speed: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
            onZoom?(exp(max(-40, min(40, event.scrollingDeltaY)) * speed), convert(event.locationInWindow, from: nil))
        }
    }
    override func magnify(with event: NSEvent) {
        onZoom?(max(0.1, 1 + event.magnification), convert(event.locationInWindow, from: nil))
    }
}

/// Pins fill their content bounds without an outer frame or shadow gutter.
@MainActor
private final class ImageToolsPinSurface: NSView {
    var displaysImage = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard !displaysImage else { return }
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

/// Selection stays inside the visible viewport, without changing content or hit testing.
@MainActor
private final class ImageToolsPinSelectionOutline: NSView {
    private var opacity: CGFloat = 0
    private var fadeTimer: Timer?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSelected(_ selected: Bool) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        guard !selected, opacity > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            opacity = selected ? 1 : 0
            needsDisplay = true
            return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let initialOpacity = opacity
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.14)
                self.opacity = initialOpacity * CGFloat((1 - progress) * (1 - progress))
                self.needsDisplay = true
                if progress >= 1 { timer.invalidate(); self.fadeTimer = nil }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard opacity > 0 else { return }
        let width = min(1.5, min(bounds.width, bounds.height) / 4)
        ToolbarPalette.accent.withAlphaComponent(opacity).setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2))
        edge.lineWidth = width
        edge.stroke()
        // A fine inner light edge keeps the selection visible over dark or blue images.
        if min(bounds.width, bounds.height) >= 8 {
            NSColor.white.withAlphaComponent(opacity * 0.85).setStroke()
            let inner = NSBezierPath(rect: bounds.insetBy(dx: width + 0.25, dy: width + 0.25))
            inner.lineWidth = 0.5
            inner.stroke()
        }
    }
}

@MainActor
private final class ImageToolsPinHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ImageToolsPinDragHandle: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    override var intrinsicContentSize: NSSize { CGSize(width: 26, height: 28) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "移动贴图")
        symbol?.withSymbolConfiguration(.init(paletteColors: [ToolbarPalette.secondaryInk]))?.draw(
            in: CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
    }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

@MainActor
private final class ImageToolsPinController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?
    var onOCR: ((CGImage) -> Void)?
    private let scroll = NSScrollView()
    private let surface = ImageToolsPinSurface()
    private let selectionOutline = ImageToolsPinSelectionOutline()
    private let toolbar = SelectionToolbar(blendingMode: .behindWindow)
    private var hud: ImageToolsPinHUDPanel?
    private var selected = false
    private static weak var selectedPin: ImageToolsPinController?
    private var dragOrigin: (point: CGPoint, frame: CGRect)?
    private var imageView: ImageToolsPinImageView?
    private var textView: ImageToolsPinTextView?
    private var inlineEditor: InlineAnnotationView?
    private var beforeEditingFrame: CGRect?
    private var inlineWindowFrame: CGRect?
    private var textColorButtons: [NSButton] = []
    private let preferences: PreferencesStore?
    private var baseSize = CGSize(width: 440, height: 240)
    private var scale: CGFloat = 1

    convenience init(image: CGImage, preferences: PreferencesStore? = nil) {
        self.init(title: "小贴 · 图片贴图", preferences: preferences)
        let size = Self.initialImageSize(image)
        baseSize = size
        let view = ImageToolsPinImageView(image: image, size: size)
        imageView = view
        surface.displaysImage = true
        window?.minSize = CGSize(width: 1, height: 1)
        view.onMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        view.onZoom = { [weak self] factor, point in self?.changeScale(by: factor, anchoredAt: point) }
        view.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        view.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        view.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        scroll.documentView = view
        configureHUD()
        updateScale()
    }

    convenience init(text: String, preferences: PreferencesStore? = nil) {
        self.init(title: "小贴 · 文字贴图", preferences: preferences)
        let view = ImageToolsPinTextView(frame: CGRect(origin: .zero, size: baseSize))
        view.isRichText = true
        view.importsGraphics = false; view.allowsUndo = true
        view.isEditable = false; view.isSelectable = false
        view.font = .systemFont(ofSize: 18)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = CGSize(width: 12, height: 12)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: baseSize.width - 24, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = []
        view.minSize = CGSize(width: baseSize.width, height: 100)
        view.maxSize = CGSize(width: baseSize.width, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.delegate = self
        view.toolTip = "拖动移动 · 双击编辑文字 · 双指滚动 · 捏合缩放"
        view.onBeginEditing = { [weak self] in self?.setTextEditing(true) }
        view.onMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        view.onZoom = { [weak self] factor, point in self?.changeScale(by: factor, anchoredAt: point) }
        view.onSelect = { [weak self] in self?.selectPin() }
        view.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        view.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        view.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        textView = view
        scroll.documentView = view
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2; scroll.maxMagnification = 4
        configureHUD()
        resizeText()
        updateScale()
    }

    private init(title: String, preferences: PreferencesStore?) {
        self.preferences = preferences
        let panel = ImageToolsPinPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // WindowServer shadows extend beyond the content even when its view fills the window.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: 60, height: 52)
        super.init(window: panel)
        panel.delegate = self
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        surface.frame = panel.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
        scroll.frame = surface.bounds
        scroll.autoresizingMask = [.width, .height]
        surface.addSubview(scroll)
        selectionOutline.frame = surface.bounds
        selectionOutline.autoresizingMask = [.width, .height]
        selectionOutline.setAccessibilityElement(false)
        surface.addSubview(selectionOutline, positioned: .above, relativeTo: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated),
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        panel.onKeyEquivalent = { [weak self] event in
            guard let self else { return false }
            if let editor = self.inlineEditor { return editor.handleKeyEquivalent(event) }
            if self.textView?.hasMarkedText() == true { return false }
            if event.keyCode == 53 {
                if self.textView?.isMoving == false { self.setTextEditing(false) } else { self.close() }
                return true
            }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": self.copyContent(); return true
                case "s" where self.imageView != nil: self.saveImage(); return true
                default: break
                }
            }
            return false
        }
        panel.center()
        let offset = CGFloat(Int.random(in: -80...80))
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + offset, y: panel.frame.minY - offset / 2))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func initialImageSize(_ image: CGImage) -> CGSize {
        let factor = min(1, min(560 / CGFloat(image.width), 500 / CGFloat(image.height)))
        return CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
    }
    private func configureHUD() {
        let handle = ImageToolsPinDragHandle()
        handle.toolTip = "拖动移动贴图"
        handle.setAccessibilityLabel("移动贴图")
        handle.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        handle.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        handle.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSButton {
            let button = SelectionButton(title, symbol: symbol, action: action)
            button.imagePosition = .imageOnly
            return button
        }
        var row: [NSView] = [handle]
        textColorButtons = []
        if let textView {
            row.append(button(textView.isMoving ? "编辑文字" : "完成编辑", textView.isMoving ? "pencil" : "checkmark") {
                [weak self] in guard let self, let textView = self.textView else { return }
                self.setTextEditing(textView.isMoving)
            })
            if !textView.isMoving {
                for (title, color) in [("默认颜色", NSColor.labelColor), ("红色", .systemRed), ("橙色", .systemOrange),
                                       ("绿色", .systemGreen), ("蓝色", .systemBlue)] {
                    let item = SelectionOptionButton(sample: .color(color), label: title) { [weak self] in self?.colorSelectedText(color) }
                    item.isEnabled = textView.selectedRange().length > 0
                    textColorButtons.append(item); row.append(item)
                }
                row.append(button("撤销", "arrow.uturn.backward") { [weak self] in self?.textView?.undoManager?.undo() })
            }
        }
        if imageView != nil {
            row.append(button("标注", "pencil.tip") { [weak self] in self?.annotateImage() })
            row.append(button("提取文字", "text.viewfinder") { [weak self] in self?.ocrImage() })
        }
        row.append(button(imageView != nil ? "复制图片" : "复制文字", "doc.on.doc") { [weak self] in self?.copyContent() })
        if imageView != nil {
            let save = button("保存 PNG", "square.and.arrow.down") { [weak self] in self?.saveImage() }
            save.toolTip = "保存 PNG（⌘S）"
            row.append(save)
        }
        row.append(button("关闭贴图", "xmark") { [weak self] in self?.closePin() })
        toolbar.rows = [row]
        if hud != nil { layoutHUD(); return }
        let panel = ImageToolsPinHUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = toolbar
        hud = panel
        layoutHUD()
    }
    private func selectPin() {
        // First clicks on a floating panel can arrive while the application is inactive.
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(inlineEditor?.canvas ?? imageView ?? textView)
        }
        setSelected(true)
    }
    private func setSelected(_ value: Bool) {
        guard selected != value else { if value { layoutHUD() }; return }
        selected = value
        surface.selected = value
        selectionOutline.setSelected(value)
        if value {
            Self.selectedPin?.setSelected(false)
            Self.selectedPin = self
        } else {
            if Self.selectedPin === self { Self.selectedPin = nil }
            dragOrigin = nil
            hud?.orderOut(nil)
        }
        updateScale()
    }
    @objc private func applicationDeactivated(_ notification: Notification) { setSelected(false) }
    @objc private func applicationActivated(_ notification: Notification) { if selected { layoutHUD() } }
    private func screenPoint(for event: NSEvent) -> CGPoint? {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow)
    }
    private func beginMoving(with event: NSEvent) {
        // Selection may resize the viewport to make room for the detached HUD.
        guard let point = screenPoint(for: event) else { return }
        selectPin()
        guard let window else { return }
        dragOrigin = (point, window.frame)
    }
    private func continueMoving(with event: NSEvent) {
        guard let dragOrigin, let point = screenPoint(for: event), let window else { return }
        let requested = dragOrigin.frame.offsetBy(dx: point.x - dragOrigin.point.x, dy: point.y - dragOrigin.point.y)
        // Choose the destination display by the pointer, including displays with negative origins.
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? visibleArea()
        window.setFrame(Self.frameFittingVisibleArea(requested, in: visible), display: true)
        layoutHUD()
    }
    private func endMoving(with event: NSEvent) { continueMoving(with: event); dragOrigin = nil }
    private func visibleArea() -> CGRect {
        window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
    }
    private func layoutHUD() {
        guard inlineEditor == nil, let window, let hud else { return }
        let visible = visibleArea()
        let size = toolbar.arrange(maxWidth: max(100, min(480, visible.width - 24)))
        hud.setContentSize(size)
        let gap: CGFloat = 6
        let candidates = [
            CGRect(x: window.frame.midX - size.width / 2, y: window.frame.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: window.frame.midX - size.width / 2, y: window.frame.maxY + gap, width: size.width, height: size.height),
            CGRect(x: window.frame.maxX + gap, y: window.frame.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: window.frame.minX - gap - size.width, y: window.frame.midY - size.height / 2, width: size.width, height: size.height)
        ]
        let frame = candidates.map { Self.frameFittingVisibleArea($0, in: visible) }.first { !$0.intersects(window.frame) }
            ?? Self.frameFittingVisibleArea(candidates[0], in: visible)
        hud.setFrame(frame, display: true)
        if selected && window.isVisible && NSApp.isActive {
            hud.order(.above, relativeTo: window.windowNumber)
        } else { hud.orderOut(nil) }
    }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
            return item
        }
        if imageView != nil {
            _ = add("标注", symbol: "pencil.tip", action: #selector(annotateImage))
            _ = add("提取文字", symbol: "text.viewfinder", action: #selector(ocrImage))
            _ = add("保存 PNG", symbol: "square.and.arrow.down", action: #selector(saveImage))
        } else {
            _ = add(textView?.isMoving == true ? "编辑文字" : "完成编辑", symbol: "pencil", action: #selector(toggleMoveMode))
        }
        _ = add(imageView != nil ? "复制图片" : "复制文字", symbol: "doc.on.doc", action: #selector(copyContent))
        menu.addItem(.separator())
        _ = add("缩小", symbol: "minus.magnifyingglass", action: #selector(zoomOut))
        _ = add("恢复大小", symbol: "arrow.counterclockwise", action: #selector(resetZoom))
        _ = add("放大", symbol: "plus.magnifyingglass", action: #selector(zoomIn))
        menu.addItem(.separator())
        _ = add("关闭贴图", symbol: "xmark", action: #selector(closePin))
        return menu
    }

    func focusTextIfNeeded() {
        guard let textView else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        setSelected(true)
    }
    @objc private func zoomOut() { changeScale(by: 1 / 1.25) }
    @objc private func zoomIn() { changeScale(by: 1.25) }
    @objc private func resetZoom() { scale = 1; updateScale() }
    @objc private func closePin() { close() }
    @objc private func toggleMoveMode() { if let textView { setTextEditing(textView.isMoving) } }
    private func setTextEditing(_ editing: Bool) {
        guard let textView else { return }
        textView.isMoving = !editing
        textView.isSelectable = editing; textView.isEditable = editing
        if !editing { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        window?.invalidateCursorRects(for: textView)
        selectPin(); configureHUD()
        if editing { window?.makeFirstResponder(textView) }
    }
    private func colorSelectedText(_ color: NSColor) {
        guard let textView, !textView.isMoving, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        restoreTextStyle(storage.attributedSubstring(from: range), range: range, applying: color)
    }
    private func restoreTextStyle(_ previous: NSAttributedString, range: NSRange, applying color: NSColor? = nil) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let inverse = storage.attributedSubstring(from: range)
        textView.undoManager?.registerUndo(withTarget: self) { target in target.restoreTextStyle(inverse, range: range) }
        textView.undoManager?.setActionName("文字颜色")
        if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
        else { storage.replaceCharacters(in: range, with: previous) }
        textView.setSelectedRange(range)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        textColorButtons.forEach { $0.isEnabled = (textView?.selectedRange().length ?? 0) > 0 }
    }
    private func changeScale(by factor: CGFloat, anchoredAt point: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let document: NSView? = imageView ?? textView
        let oldSize = document?.frame.size ?? .zero
        let anchor = point ?? CGPoint(x: oldSize.width / 2, y: oldSize.height / 2)
        let fraction = CGPoint(x: oldSize.width > 0 ? anchor.x / oldSize.width : 0.5,
                               y: oldSize.height > 0 ? anchor.y / oldSize.height : 0.5)
        let before = document.flatMap { view in window?.convertPoint(toScreen: view.convert(anchor, to: nil)) }
        let maximum: CGFloat
        if let imageView {
            maximum = max(4, 2 * max(CGFloat(imageView.image.width) / max(1, baseSize.width),
                                     CGFloat(imageView.image.height) / max(1, baseSize.height)))
        } else { maximum = 4 }
        scale = min(maximum, max(0.2, scale * factor))
        updateScale()
        if let document, let before, let window {
            let newPoint = CGPoint(x: document.frame.width * fraction.x, y: document.frame.height * fraction.y)
            let after = window.convertPoint(toScreen: document.convert(newPoint, to: nil))
            let requested = window.frame.offsetBy(dx: before.x - after.x, dy: before.y - after.y)
            let visible = visibleArea()
            window.setFrame(Self.frameFittingVisibleArea(requested, in: visible), display: true)
            layoutHUD()
        }
    }
    private func updateScale() {
        guard inlineEditor == nil else { return }
        let scaledSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        // Native borderless windows round up to whole points; align the image
        // with that geometry so small zoom levels do not leave an empty strip.
        let size = imageView == nil ? scaledSize
            : CGSize(width: ceil(scaledSize.width), height: ceil(scaledSize.height))
        if let imageView { imageView.setFrameSize(size); imageView.needsDisplay = true }
        if let window {
            let visible = visibleArea()
            let minimum = imageView == nil ? CGSize(width: 32, height: 24) : CGSize(width: 1, height: 1)
            // Leave space for the detached action row on very large pins; the document scrolls inside.
            let hudSpace: CGFloat = selected ? (hud?.frame.height ?? 40) + 6 : 0
            let origin = window.frame.origin
            let top = window.frame.maxY
            window.setContentSize(CGSize(width: max(minimum.width, min(size.width, visible.width - 40)),
                                         height: max(minimum.height, min(size.height, visible.height - 40 - hudSpace))))
            let requested = CGRect(x: origin.x, y: top - window.frame.height,
                                   width: window.frame.width, height: window.frame.height)
            window.setFrame(Self.frameFittingVisibleArea(requested, in: visible), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if textView != nil { scroll.magnification = scale }
        layoutHUD()
    }
    private static func frameFittingVisibleArea(_ requested: CGRect, in visible: CGRect) -> CGRect {
        let width = min(requested.width, visible.width), height = min(requested.height, visible.height)
        return CGRect(x: min(max(requested.minX, visible.minX), visible.maxX - width),
                      y: min(max(requested.maxY - height, visible.minY), visible.maxY - height), width: width, height: height)
    }
    @objc private func annotateImage() {
        guard inlineEditor == nil, let imageView, let window else { return }
        beforeEditingFrame = window.frame
        let handle = ImageToolsPinDragHandle()
        handle.toolTip = "拖动移动贴图"
        handle.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        handle.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        handle.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        let editor = InlineAnnotationView(image: imageView.image, preferences: preferences, moveHandle: handle,
                                          completionHint: "完成标注，返回贴图")
        inlineEditor = editor
        editor.onComplete = { [weak self] image in self?.endInlineEditing(image: image) }
        editor.onCancel = { [weak self] in self?.endInlineEditing(image: nil) }
        hud?.orderOut(nil); scroll.isHidden = true; selectionOutline.isHidden = true
        let visible = visibleArea().insetBy(dx: 20, dy: 20)
        let size = CGSize(width: min(visible.width, max(740, window.frame.width)),
                          height: min(visible.height, max(480, window.frame.height)))
        window.setFrame(Self.frameFittingVisibleArea(CGRect(x: window.frame.minX, y: window.frame.maxY - size.height,
            width: size.width, height: size.height), in: visible), display: true)
        inlineWindowFrame = window.frame
        editor.frame = surface.bounds; editor.autoresizingMask = [.width, .height]
        surface.addSubview(editor); editor.fitWidth()
        editor.scroll.contentView.scroll(to: .zero)
        selectPin(); window.makeFirstResponder(editor.canvas)
    }
    private func endInlineEditing(image: CGImage?) {
        inlineEditor?.removeFromSuperview(); inlineEditor = nil
        scroll.isHidden = false; selectionOutline.isHidden = false
        if let image { imageView?.image = image; imageView?.needsDisplay = true }
        if let frame = beforeEditingFrame, let start = inlineWindowFrame, let window {
            let restored = frame.offsetBy(dx: window.frame.minX - start.minX, dy: window.frame.minY - start.minY)
            window.setFrame(Self.frameFittingVisibleArea(restored, in: visibleArea()), display: true)
        }
        beforeEditingFrame = nil
        inlineWindowFrame = nil
        updateScale(); selectPin()
    }
    private func replaceImage(_ image: CGImage) {
        imageView?.image = image
        window?.hasShadow = false
        baseSize = Self.initialImageSize(image)
        updateScale()
        if window?.isVisible == true { window?.orderFrontRegardless() }
    }
    @objc private func ocrImage() { if let imageView { onOCR?(imageView.image) } }
    @objc private func copyContent() {
        do {
            if let imageView { try ImageToolsUI.copyPNG(imageView.image) }
            else if let textView {
                let range = textView.selectedRange()
                let text = range.length > 0 ? (textView.string as NSString).substring(with: range) : textView.string
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let all = NSRange(location: 0, length: (textView.string as NSString).length)
                if let data = textView.rtf(from: range.length > 0 ? range : all) {
                    NSPasteboard.general.setData(data, forType: .rtf)
                }
            }
        } catch { showError(error) }
    }
    @objc private func saveImage() {
        guard let imageView else { return }
        let chooser = NSSavePanel()
        chooser.allowedContentTypes = [.png]
        chooser.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do { try ImageToolsUI.png(imageView.image).write(to: url, options: .atomic) }
        catch { showError(error) }
    }
    private func resizeText() {
        guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        baseSize.height = max(120, layout.usedRect(for: container).height + 28)
        textView.setFrameSize(baseSize)
    }
    func textDidChange(_ notification: Notification) { resizeText(); updateScale() }
    func windowDidBecomeKey(_ notification: Notification) { setSelected(true) }
    func windowDidResignKey(_ notification: Notification) { setSelected(false) }
    func windowDidMove(_ notification: Notification) { layoutHUD() }
    func windowDidResize(_ notification: Notification) { layoutHUD() }
    func windowDidChangeScreen(_ notification: Notification) { layoutHUD() }
    func windowWillClose(_ notification: Notification) {
        setSelected(false)
        NotificationCenter.default.removeObserver(self)
        hud?.close(); hud = nil
        inlineEditor?.removeFromSuperview(); inlineEditor = nil; onClose?()
    }
}

/// Shared between the serial worker and window lifecycle on the main thread.
/// Never invoke Vision while holding the state lock.
private final class ImageToolsOCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    func register(_ request: VNRequest) throws {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { self.request = request }
        lock.unlock()
        if wasCancelled {
            request.cancel()
            throw CancellationError()
        }
    }

    func finishRequest() {
        lock.lock()
        request = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeRequest = request
        request = nil
        lock.unlock()
        activeRequest?.cancel()
    }
}

/// A queued block retains only its job. Cancelled jobs release their input image
/// immediately, without waiting for an earlier Vision request to finish.
private final class ImageToolsOCRJob: @unchecked Sendable {
    typealias Completion = @MainActor (Result<String, Error>) -> Void
    private let lock = NSLock()
    private let cancellation = ImageToolsOCRCancellation()
    private var image: CGImage?
    private var completion: Completion?

    init(image: CGImage, completion: @escaping Completion) {
        self.image = image
        self.completion = completion
    }

    func cancel() {
        lock.lock()
        image = nil
        completion = nil
        lock.unlock()
        cancellation.cancel()
    }

    fileprivate func perform(using recognize: ImageToolsOCRQueue.Recognition) {
        lock.lock()
        let input = image
        image = nil
        lock.unlock()
        guard let input, !cancellation.isCancelled else { return }
        let result = autoreleasepool { Result { try recognize(input, cancellation) } }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let callback = completion
            completion = nil
            lock.unlock()
            guard !cancellation.isCancelled else { return }
            callback?(result)
        }
    }
}

private final class ImageToolsOCRQueue {
    typealias Recognition = @Sendable (CGImage, ImageToolsOCRCancellation) throws -> String
    private let queue = DispatchQueue(label: "dev.screenleaf.ocr", qos: .userInitiated)
    private let recognize: Recognition

    init(recognize: @escaping Recognition = { try ImageToolsOCRWorker.read($0, cancellation: $1) }) {
        self.recognize = recognize
    }

    func enqueue(_ image: CGImage, completion: @escaping ImageToolsOCRJob.Completion) -> ImageToolsOCRJob {
        let job = ImageToolsOCRJob(image: image, completion: completion)
        queue.async { [recognize] in job.perform(using: recognize) }
        return job
    }
}

private enum ImageToolsOCRWorker {
    private static let logger = Logger(subsystem: "dev.screenleaf.app", category: "OCR")

    static func imageDescription(_ image: CGImage) -> String {
        let colorSpace = image.colorSpace?.name.map { $0 as String } ?? "unnamed"
        let model = image.colorSpace?.model.rawValue ?? -1
        return "input width=\(image.width) height=\(image.height) bpc=\(image.bitsPerComponent) bpp=\(image.bitsPerPixel) bitmap=0x\(String(image.bitmapInfo.rawValue, radix: 16)) colorspace=\(colorSpace) model=\(model)"
    }

    private static func logFailure(_ error: Error) {
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        var depth = 0
        while let failure = current, depth < 8, visited.insert(ObjectIdentifier(failure)).inserted {
            logger.error("failure depth=\(depth, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
            // Inspect only the error reference, never log userInfo, pixels or recognized text.
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
    }

    static func read(_ image: CGImage) throws -> String {
        try read(image, cancellation: ImageToolsOCRCancellation())
    }

    static func read(_ image: CGImage, cancellation: ImageToolsOCRCancellation) throws -> String {
        try cancellation.checkCancellation()
        let started = DispatchTime.now().uptimeNanoseconds
        logger.info("\(imageDescription(image), privacy: .public)")
        do {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            let desired = ["zh-Hans", "zh-Hant", "en-US", "en-GB", "en"]
            let languages = desired.filter { supported.contains($0) }
            if !languages.isEmpty { request.recognitionLanguages = languages }
            // The product recognizes Chinese and English. Explicit languages avoid
            // repeating Vision's script/model detection for every text region.
            request.automaticallyDetectsLanguage = false
            let configuredLanguages = request.recognitionLanguages.joined(separator: ",")
            logger.info("request revision=\(request.revision, privacy: .public) level=accurate languageCorrection=true autoDetect=false languages=\(configuredLanguages, privacy: .public)")
            try cancellation.register(request)
            defer { cancellation.finishRequest() }
            try cancellation.checkCancellation()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try cancellation.checkCancellation()
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            guard !lines.isEmpty else { throw ScreenLeafError(message: "没有识别到文字。可尝试截取更清晰或更大的文字区域。") }
            let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            logger.info("recognition completed duration_ms=\(elapsedMilliseconds, privacy: .public)")
            return lines.joined(separator: "\n")
        } catch {
            if !cancellation.isCancelled { logFailure(error) }
            throw error
        }
    }
}

/// Diagnostic entry point for a generated fixture only; it never prints recognized content.
@MainActor
enum ImageToolsDiagnostics {
    static func checkOCR(_ image: CGImage) -> Bool {
        do {
            let text = try ImageToolsOCRWorker.read(image)
            let containsPatch = text.contains("Patch")
            print("OCR self-check: containsPatch=\(containsPatch) result=\(containsPatch ? "PASS" : "FAIL")")
            return containsPatch
        } catch {
            // Failure details are limited to the metadata-safe Unified Logging chain above.
            print("OCR self-check: containsPatch=false result=FAIL")
            return false
        }
    }
}

@MainActor
private final class ImageToolsCopyButton: SelectionButton {
    override var intrinsicContentSize: NSSize {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return CGSize(width: max(84, ceil(textWidth) + 42), height: 28)
    }
    override func drawSurface() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let shade: CGFloat = dark ? (isHighlighted ? 0.28 : 0.20) : (isHighlighted ? 0.80 : 0.90)
        let background = NSColor(calibratedWhite: shade, alpha: 1)
        background.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class ImageToolsOCRController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "识别中…")
    private var copyButton: NSButton!
    private let writeClipboard: (String) -> Bool
    private var hasResult = false
    init(writeClipboard: ((String) -> Bool)? = nil) {
        self.writeClipboard = writeClipboard ?? { text in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "文字"
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 300, height: 180)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        setup(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func setup() {
        guard let content = window?.contentView else { return }
        copyButton = ImageToolsCopyButton("复制并关闭", symbol: "doc.on.doc") { [weak self] in self?.copyText() }
        copyButton.isEnabled = false
        let spacer = NSView()
        let actions = NSStackView(views: [spacer, copyButton])
        actions.spacing = 8
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.frame = CGRect(x: 0, y: 0, width: 416, height: 220)
        textView.isRichText = false; textView.isEditable = false; textView.isSelectable = true
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = CGSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        scroll.documentView = textView
        let stack = NSStackView(views: [status, scroll, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    func complete(_ text: String) {
        hasResult = true
        textView.string = text; textView.isEditable = true
        status.isHidden = true
        refreshCopyAvailability()
        if window?.isKeyWindow == true { window?.makeFirstResponder(textView) }
    }
    func fail(_ error: Error) {
        hasResult = false
        status.stringValue = "识别未完成"
        status.isHidden = false
        textView.isEditable = false
        textView.string = (error as? ScreenLeafError)?.message ?? "无法完成文字识别，请重试。"
        copyButton.isEnabled = false
    }
    @objc private func copyText() {
        guard hasResult, !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard writeClipboard(textView.string) else {
            status.stringValue = "未能复制，请重试。"
            status.isHidden = false
            return
        }
        close()
    }
    private func refreshCopyAvailability() {
        copyButton.isEnabled = hasResult && !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func textDidChange(_ notification: Notification) { refreshCopyAvailability() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
enum ImageToolsUI {
    static func hasTransparentPixels(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = storage.bindMemory(to: UInt8.self)
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] < 255 }
        }
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }
    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenLeafError(message: "无法编码 PNG 图片。")
        }
        return data
    }
    static func copyPNG(_ image: CGImage) throws {
        let data = try png(image)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(data, forType: .png) else {
            throw ScreenLeafError(message: "无法将图片写入剪贴板。")
        }
    }
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
