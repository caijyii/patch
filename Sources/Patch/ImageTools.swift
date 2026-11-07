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
    private var lastHiddenPinIDs: [UUID] = []
    private var ocrQueue = ImageToolsOCRQueue()
    private var ocrJobs: [UUID: ImageToolsOCRJob] = [:]
    var onPinStateChange: (() -> Void)?

    var hasPins: Bool { !pins.isEmpty }
    var canTogglePins: Bool {
        pins.values.contains { $0.window?.isVisible == true }
            || lastHiddenPinIDs.contains { pins[$0] != nil }
    }
    // New pins can be visible while older ones remain hidden.
    var arePinsHidden: Bool { hasPins && pins.values.allSatisfy { $0.window?.isVisible != true } }

    init() {}

    deinit { ocrJobs.values.forEach { $0.cancel() } }

    func showEditor(_ image: CGImage, pixelScale: CGFloat? = nil) {
        let id = UUID()
        let controller = ImageToolsEditorController(image: image, pixelScale: pixelScale)
        controller.onPin = { [weak self] in self?.pinImage($0, pixelScale: pixelScale) }
        controller.onOCR = { [weak self] in self?.recognize($0) }
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func pinImage(_ image: CGImage, pixelScale: CGFloat? = nil, recordsHistory: Bool = true,
                  anchor: NSPoint? = nil, batchIndex: Int = 0) {
        let point = anchor ?? NSEvent.mouseLocation
        if recordsHistory { ImageToolsUI.onCompletedImage?(image, pixelScale) }
        let controller = ImageToolsPinController(image: image, pixelScale: pixelScale, anchor: point, batchIndex: batchIndex)
        controller.onOCR = { [weak self] image in self?.recognize(image) }
        addPin(controller)
    }

    func showSubjectSelection(_ image: CGImage, pixelScale: CGFloat? = nil) {
        let id = UUID()
        let controller = SubjectSelectionController(image: image, pixelScale: pixelScale)
        controller.onPin = { [weak self] in self?.pinImage($0, pixelScale: pixelScale) }
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
        lastHiddenPinIDs.removeAll()
        controllers.forEach { $0.close() }
        onPinStateChange?()
    }

    func pinText(_ text: String, recordsHistory: Bool = true, anchor: NSPoint? = nil, batchIndex: Int = 0) {
        let point = anchor ?? NSEvent.mouseLocation
        if recordsHistory { ImageToolsUI.onCompletedText?(text) }
        addPin(ImageToolsPinController(text: text, anchor: point, batchIndex: batchIndex))
    }

    func pinText(_ text: NSAttributedString, recordsHistory: Bool = true, anchor: NSPoint? = nil, batchIndex: Int = 0) {
        if recordsHistory { ImageToolsUI.onCompletedRichText?(text) }
        addPin(ImageToolsPinController(attributedText: text, anchor: anchor ?? NSEvent.mouseLocation, batchIndex: batchIndex))
    }

    func pinClipboard(from pasteboard: NSPasteboard = .general, anchor: NSPoint? = nil) {
        let point = anchor ?? NSEvent.mouseLocation
        if let image = ImageToolsUI.clipboardImage(from: pasteboard) {
            pinImage(image.image, pixelScale: image.pixelScale, anchor: point)
        } else if let text = ImageToolsUI.clipboardText(from: pasteboard), text.length > 0 {
            pinText(text, anchor: point)
        } else {
            showError(PatchError(message: L("剪贴板中没有可贴出的图片或文字。")), title: L("无法贴出剪贴板"))
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
        guard canTogglePins else { return }
        let visible = pins.filter { $0.value.window?.isVisible == true }
        if !visible.isEmpty {
            // Remember only this hide operation, in front-to-back order. Older
            // hidden groups must not join a later restore operation.
            lastHiddenPinIDs = NSApp.orderedWindows.compactMap { window in
                visible.first { $0.value.window === window }?.key
            }
            lastHiddenPinIDs += visible.keys.filter { !lastHiddenPinIDs.contains($0) }
            for controller in visible.values {
                guard let window = controller.window else { continue }
                window.orderOut(nil)
                WindowActivationCoordinator.shared.unregister(window)
            }
        } else {
            let restoring = lastHiddenPinIDs
            lastHiddenPinIDs.removeAll()
            for id in restoring.reversed() {
                guard let controller = pins[id], let window = controller.window else { continue }
                if controller.isAnnotating { WindowActivationCoordinator.shared.register(window) }
                window.orderFrontRegardless()
            }
        }
        onPinStateChange?()
    }

    private func addPin(_ controller: ImageToolsPinController) {
        let id = UUID()
        // Repeated pins at one pointer position should leave a small visible edge.
        // Only the new window moves; hidden pins do not reserve desktop positions.
        controller.avoidInitialOverlap(with: pins.values.compactMap {
            guard let window = $0.window, window.isVisible else { return nil }
            return window.frame
        })
        // A new pin must not reveal older pins that the user has hidden.
        pins[id] = controller
        controller.onClose = { [weak self] in
            guard let self, self.pins.removeValue(forKey: id) != nil else { return }
            self.lastHiddenPinIDs.removeAll { $0 == id }
            self.onPinStateChange?()
        }
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        controller.focusTextIfNeeded()
        onPinStateChange?()
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

    override func magnify(with event: NSEvent) {
        enclosingScrollView?.magnify(with: event)
    }

    private(set) var source: CGImage
    var allowsOutsideAnnotations = false
    private var sourceRect: CGRect {
        allowsOutsideAnnotations ? CGRect(x: 0, y: 0, width: source.width, height: source.height) : bounds
    }

    private func exportBounds(for items: [ImageToolsAnnotation]) -> CGRect {
        let image = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard allowsOutsideAnnotations else { return image }
        return items.reduce(image) { $0.union(annotationFrame($1).insetBy(dx: -1, dy: -1)) }.integral
    }

    func workspaceBounds(viewport: CGSize, magnification: CGFloat) -> CGRect {
        let image = sourceRect
        let content = exportBounds(for: annotations)
        let scale = max(0.0001, magnification)
        let padding = 48 / scale
        let halfWidth = max(viewport.width / scale / 2, max(image.midX - content.minX, content.maxX - image.midX) + padding)
        let halfHeight = max(viewport.height / scale / 2, max(image.midY - content.minY, content.maxY - image.midY) + padding)
        return CGRect(x: image.midX - halfWidth, y: image.midY - halfHeight, width: halfWidth * 2, height: halfHeight * 2).integral
    }
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
    override var needsPanelToBecomeKey: Bool { true }

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
        if allowsOutsideAnnotations { NSColor.white.setFill(); bounds.fill() }
        NSImage(cgImage: source, size: sourceRect.size).draw(
            in: sourceRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
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
            attempt { try commitAnnotations(annotations + [annotation], selecting: nil) }
            return
        }
        if tool == .number {
            let number = (annotations.filter { $0.tool == .number }.map(\.number).max() ?? 0) + 1
            let annotation = ImageToolsAnnotation(tool: tool, points: [point],
                color: annotationColor, width: annotationWidth, number: number, numberSize: annotationNumberSize)
            attempt { try commitAnnotations(annotations + [annotation], selecting: nil) }
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
        attempt { try commitAnnotations(annotations + [annotation], selecting: nil) }
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
            throw PatchError(message: L("更新图片的像素尺寸必须保持一致。"))
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
            throw PatchError(message: L("马赛克尚未完成，无法导出图片。"))
        }
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let region: CGRect
        if let pixelRect {
            guard pixelRect.origin.x.isFinite, pixelRect.origin.y.isFinite,
                  pixelRect.width.isFinite, pixelRect.height.isFinite,
                  pixelRect.width > 0, pixelRect.height > 0 else {
                throw PatchError(message: L("无法读取选区，请重新选取。"))
            }
            region = pixelRect.integral.intersection(allowsOutsideAnnotations ? bounds : imageBounds)
            guard !region.isNull, !region.isEmpty else {
                throw PatchError(message: L("无法读取选区，请重新选取。"))
            }
        } else { region = exportBounds(for: items) }
        // CoreGraphics can round stroke coverage differently when the bitmap's
        // clipping bounds change. Keep the original bounds for annotations so
        // edge antialiasing remains pixel-identical to the full-image export.
        let renderRegion = items.isEmpty ? region : exportBounds(for: items).union(region)
        guard let context = CGContext(data: nil, width: Int(renderRegion.width), height: Int(renderRegion.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PatchError(message: L("图片过大，无法分配导出内存。"))
        }
        if allowsOutsideAnnotations {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: renderRegion.size))
        }
        // Preserve image-pixel coordinates even when the workspace includes negative positions.
        context.translateBy(x: -renderRegion.minX, y: renderRegion.maxY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSImage(cgImage: source, size: sourceRect.size).draw(
            in: sourceRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        items.forEach(drawAnnotation)
        NSGraphicsContext.restoreGraphicsState()
        if renderRegion != region {
            guard let cropped = CGContext(data: nil, width: Int(region.width), height: Int(region.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let input = context.data, let output = cropped.data else {
                throw PatchError(message: L("图片过大，无法分配导出内存。"))
            }
            let offset = Int(region.minY - renderRegion.minY) * context.bytesPerRow + Int(region.minX - renderRegion.minX) * 4
            for row in 0..<Int(region.height) {
                output.advanced(by: row * cropped.bytesPerRow).copyMemory(
                    from: input.advanced(by: offset + row * context.bytesPerRow), byteCount: Int(region.width) * 4)
            }
            guard let result = cropped.makeImage() else {
                throw PatchError(message: L("无法导出标注后的图片。"))
            }
            return result
        }
        guard let result = context.makeImage() else {
            throw PatchError(message: L("无法导出标注后的图片。"))
        }
        return result
    }

    private func mosaicPatch(_ crop: CGImage, blockSize: CGFloat) throws -> CGImage {
        // Work on a copied 8-bit raster so exports contain only the replacement pixels.
        guard blockSize.isFinite, blockSize >= 2, blockSize <= CGFloat(Int.max / 2) else {
            throw PatchError(message: L("马赛克块大小无效，请选择有效大小。"))
        }
        let bitmap = NSBitmapImageRep(cgImage: crop)
        guard let bytes = bitmap.bitmapData, bitmap.bitsPerSample == 8,
              bitmap.bitsPerPixel == bitmap.samplesPerPixel * 8, !bitmap.isPlanar else {
            throw PatchError(message: L("无法处理马赛克选区的像素格式。"))
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
            throw PatchError(message: L("无法生成马赛克图片。"))
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
                guard value.isFinite, value > 0 else { throw PatchError(message: L("标注大小无效，请选择有效大小。")) }
            }
            if let block = mosaicBlockSize, !block.isFinite || block < 2 {
                throw PatchError(message: L("马赛克块大小无效，请选择有效大小。"))
            }
            var proposed = annotations
            if let sticker, proposed[index].tool == .sticker {
                guard StickerCatalog.item(for: sticker) != nil || sticker.count == 1 else {
                    throw PatchError(message: L("请选择一张有效贴纸。"))
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
                    throw PatchError(message: L("马赛克区域太小或不在图片中，请调整选区。"))
                }
                annotation.points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
                annotation.mosaic = try mosaicPatch(rasterized(result, croppingTo: rect), blockSize: annotation.mosaicBlockSize)
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
            } else { proposed.append(annotation); selection = nil }
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
    private let pixelScale: CGFloat?
    private let appliesToPin: Bool

    init(image: CGImage, pixelScale: CGFloat? = nil, preferences: PreferencesStore? = nil, appliesToPin: Bool = false) {
        self.pixelScale = pixelScale
        canvas = ImageToolsCanvas(image: image)
        self.appliesToPin = appliesToPin
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(max(740, CGFloat(image.width) + 24), min(1040, visible.width - 100))
        let height = min(max(360, CGFloat(image.height) + 180), min(760, visible.height - 100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: appliesToPin ? L("Patch · 标注贴图") : L("Patch · 截图标注"))
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

    override func showWindow(_ sender: Any?) {
        if let window { WindowActivationCoordinator.shared.register(window) }
        super.showWindow(sender)
    }

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
        let save = SelectionButton(L("保存"), symbol: "square.and.arrow.down") { [weak self] in self?.saveImage() }
        save.toolTip = L("保存 PNG")
        actions = [
            SelectionButton(L("复制"), symbol: "doc.on.doc") { [weak self] in self?.copyImage() },
            save
        ]
        if !appliesToPin {
            let pin = SelectionButton(L("贴图"), symbol: "pin") { [weak self] in self?.pinImage() }
            pin.toolTip = L("将图片贴到屏幕")
            actions.append(pin)
        }
        let ocr = SelectionButton(L("文字"), symbol: "text.viewfinder") { [weak self] in self?.ocr() }
        ocr.toolTip = L("提取图片中的文字")
        actions.append(ocr)
        for case let button as NSButton in actions { button.imagePosition = .imageOnly }
        let minus = SelectionButton(L("缩小"), symbol: "minus.magnifyingglass") { [weak self] in self?.zoomOut() }
        let plus = SelectionButton(L("放大"), symbol: "plus.magnifyingglass") { [weak self] in self?.zoomIn() }
        minus.imagePosition = .imageOnly; plus.imagePosition = .imageOnly
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = ToolbarPalette.secondaryInk
        actions += [minus, zoomLabel, plus]
        if appliesToPin {
            actions.append(SelectionButton.confirmation(L("应用到贴图"), toolTip: L("完成标注，应用到贴图")) { [weak self] in self?.applyImage() })
            toolbar.trailingActions = [actions.last!]
        }
        controls.onUpdate = { [weak self] in self?.layoutEditor() }
        toolbar.onDisplayMetricsChanged = { [weak self] in self?.layoutEditor() }
        canvas.onChange = { [weak self] in self?.controls.refresh(); self?.layoutEditor() }
        controls.choose(tool: .arrow)
        NotificationCenter.default.addObserver(self, selector: #selector(updateZoom),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        layoutEditor()
    }

    private func layoutEditor() {
        guard let content = window?.contentView, controls != nil else { return }
        let backingScale = window?.backingScaleFactor ?? 2
        toolbar.configure(forBackingScaleFactor: backingScale)
        controls.configureToolbar(forBackingScaleFactor: backingScale)
        toolbar.prepareItems(actions)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: toolbar.metrics.parameterSize, weight: .medium)
        let usableWidth = max(40, content.bounds.width - 24)
        toolbar.rows = controls.rows(appendingActions: actions, maxWidth: usableWidth)
        let size = toolbar.arrange(maxWidth: usableWidth)
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
    @objc private func copyImage() { exporting { try ImageToolsUI.copyPNG($0, pixelScale: self.pixelScale) } }
    @objc private func saveImage() {
        exporting { image in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
            WindowActivationCoordinator.shared.register(panel)
            defer { WindowActivationCoordinator.shared.unregister(panel) }
            if panel.runModal() == .OK, let url = panel.url {
                try ImageToolsUI.png(image).write(to: url, options: .atomic)
                ImageToolsUI.onCompletedImage?(image, self.pixelScale)
            }
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

/// Center images smaller than the viewport while preserving native scrolling for large images.
private final class AnnotationClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView {
            if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
            if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        }
        return rect
    }
}

private final class AnnotationScrollView: NSScrollView {
    var onZoom: (() -> Void)?
    override func magnify(with event: NSEvent) {
        guard allowsMagnification, let document = documentView else { return }
        let anchor = document.convert(event.locationInWindow, from: nil)
        setMagnification(min(maxMagnification, max(minMagnification, magnification * (1 + event.magnification))), centeredAt: anchor)
        onZoom?()
    }
}

/// Display-only chrome; never participates in the image canvas or its export.
@MainActor
private final class ImageToolsWindowBorder: NSView {
    static let width: CGFloat = 1
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ToolbarPalette.border.setStroke()
        let edge = NSBezierPath(rect: bounds.insetBy(dx: Self.width / 2, dy: Self.width / 2))
        edge.lineWidth = Self.width
        edge.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class AnnotationZoomLabel: NSTextField {
    // Keep the toolbar width stable when fitting changes 100% to one or two digits.
    override var intrinsicContentSize: NSSize {
        CGSize(width: 40, height: super.intrinsicContentSize.height)
    }
}

/// A document-sized canvas hosted by the existing pin or capture panel.
/// Scrolling/magnification affect the viewport, never the exported pixel dimensions.
@MainActor
final class InlineAnnotationView: NSView {
    let canvas: ImageToolsCanvas
    let scroll: NSScrollView = AnnotationScrollView()
    private let toolbar = SelectionToolbar()
    private let presentationBorder = ImageToolsWindowBorder()
    private(set) var controls: AnnotationControls!
    private let zoomLabel = AnnotationZoomLabel(labelWithString: "100%")
    private var actions: [NSView] = []
    private var arranging = false
    private var completing = false
    private let pixelScale: CGFloat?
    var onComplete: ((CGImage) throws -> Void)?
    var onCancel: (() -> Void)?
    var onError: (Error) -> Void = { showError($0) }

    init(image: CGImage, pixelScale: CGFloat? = nil, preferences: PreferencesStore? = nil, moveHandle: NSView? = nil,
         completionHint: String, showsCopyAction: Bool = true, allowsOutsideAnnotations: Bool = false,
         cancellationHint: String = L("退出标注，保留原图"),
         additionalActions: [(String, String, (CGImage) throws -> Void)] = []) {
        self.pixelScale = pixelScale
        canvas = ImageToolsCanvas(image: image)
        canvas.allowsOutsideAnnotations = allowsOutsideAnnotations
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true
        scroll.minMagnification = 0.02; scroll.maxMagnification = 8
        scroll.contentView = AnnotationClipView()
        scroll.backgroundColor = .white
        scroll.documentView = canvas
        (scroll as? AnnotationScrollView)?.onZoom = { [weak self] in self?.zoomChanged() }
        addSubview(scroll); addSubview(toolbar)
        presentationBorder.frame = bounds
        presentationBorder.autoresizingMask = [.width, .height]
        presentationBorder.setAccessibilityElement(false)
        addSubview(presentationBorder)
        controls = AnnotationControls(canvas: canvas, preferences: preferences, scale: { [weak self] in
            1 / max(0.0001, self?.scroll.magnification ?? 1)
        })
        func icon(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSButton {
            let button = SelectionButton(title, symbol: symbol, action: action)
            button.imagePosition = .imageOnly
            return button
        }
        if let moveHandle { actions.append(moveHandle) }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.alignment = .center
        actions += [icon(L("缩小"), "minus.magnifyingglass") { [weak self] in self?.zoom(by: 1 / 1.25) },
                    zoomLabel, icon(L("放大"), "plus.magnifyingglass") { [weak self] in self?.zoom(by: 1.25) },
                    SelectionButton(L("适合宽度")) { [weak self] in self?.fitWidth() },
                    SelectionButton("100%") { [weak self] in self?.setZoom(1) }]
        for (title, symbol, action) in additionalActions {
            actions.append(icon(title, symbol) { [weak self] in
                guard let self else { return }
                do {
                    self.canvas.finishTextEditing()
                    try action(self.canvas.renderedImage())
                } catch { self.onError(error) }
            })
        }
        if showsCopyAction { actions.append(icon(L("复制"), "doc.on.doc") { [weak self] in self?.copyImage() }) }
        actions += [icon(L("保存 PNG"), "square.and.arrow.down") { [weak self] in self?.saveImage() },
                    SelectionButton.cancellation(toolTip: cancellationHint) { [weak self] in self?.onCancel?() },
                    SelectionButton.confirmation(toolTip: completionHint) { [weak self] in self?.complete() }]
        toolbar.trailingActions = Array(actions.suffix(2))
        controls.onUpdate = { [weak self] in self?.refresh() }
        toolbar.onDisplayMetricsChanged = { [weak self] in self?.refresh() }
        canvas.onChange = { [weak self] in self?.controls.refresh(); self?.refresh() }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        controls.choose(tool: .arrow)
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        needsDisplay = true
    }
    private func refresh() { needsLayout = true; layoutSubtreeIfNeeded() }
    private func configureToolbarMetrics(backingScaleFactor: CGFloat? = nil) {
        let backingScale = backingScaleFactor ?? window?.backingScaleFactor ?? 2
        toolbar.configure(forBackingScaleFactor: backingScale)
        controls.configureToolbar(forBackingScaleFactor: backingScale)
        toolbar.prepareItems(actions)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: toolbar.metrics.parameterSize, weight: .medium)
    }
    override func layout() {
        super.layout()
        guard !arranging, controls != nil else { return }
        arranging = true; defer { arranging = false }
        configureToolbarMetrics()
        let usableWidth = max(40, bounds.width - 16)
        toolbar.rows = controls.rows(appendingActions: actions, maxWidth: usableWidth)
        let size = toolbar.arrange(maxWidth: usableWidth)
        toolbar.frame = CGRect(x: 8, y: max(0, bounds.height - size.height - 8), width: size.width, height: size.height)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(1, toolbar.frame.minY - 8))
        updateWorkspace()
    }
    private func scrollTo(_ point: CGPoint) {
        let clip = scroll.contentView
        let center = canvas.convert(point, to: clip)
        clip.scroll(to: CGPoint(x: center.x - clip.bounds.width / 2, y: center.y - clip.bounds.height / 2))
        scroll.reflectScrolledClipView(clip)
    }
    private func updateWorkspace() {
        guard canvas.allowsOutsideAnnotations else { return }
        let center = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        let area = canvas.workspaceBounds(viewport: scroll.contentSize, magnification: scroll.magnification)
        guard canvas.bounds != area else { return }
        canvas.setFrameSize(area.size)
        canvas.bounds = area
        scrollTo(center)
        canvas.needsDisplay = true
    }
    func fitImage() {
        refresh()
        let zoom = min(1, min(max(1, scroll.contentSize.width - 96) / CGFloat(canvas.source.width),
                              max(1, scroll.contentSize.height - 96) / CGFloat(canvas.source.height)))
        scroll.minMagnification = min(0.02, zoom)
        setZoom(zoom)
        scrollTo(CGPoint(x: CGFloat(canvas.source.width) / 2, y: CGFloat(canvas.source.height) / 2))
    }
    func preferredWindowSize(maximum: CGSize, backingScaleFactor: CGFloat? = nil) -> CGSize {
        configureToolbarMetrics(backingScaleFactor: backingScaleFactor)
        let usableWidth = max(40, maximum.width - 16)
        toolbar.rows = controls.rows(appendingActions: actions, maxWidth: usableWidth)
        let toolbarSize = toolbar.arrange(maxWidth: usableWidth)
        return CGSize(width: min(maximum.width, toolbarSize.width + 16),
                      height: min(maximum.height, max(320, toolbarSize.height + 32 + min(600, CGFloat(canvas.source.height)))))
    }
    func fitWidth() {
        refresh()
        setZoom(min(1, max(1, scroll.contentSize.width - (canvas.allowsOutsideAnnotations ? 96 : 16)) / CGFloat(canvas.source.width)))
        if canvas.allowsOutsideAnnotations {
            scrollTo(CGPoint(x: CGFloat(canvas.source.width) / 2, y: CGFloat(canvas.source.height) / 2))
        }
    }
    func setZoom(_ value: CGFloat) {
        let center = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        scroll.setMagnification(min(scroll.maxMagnification, max(scroll.minMagnification, value)), centeredAt: center)
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
        do { try ImageToolsUI.copyPNG(canvas.renderedImage(), pixelScale: pixelScale) } catch { onError(error) }
    }
    private func saveImage() {
        do {
            let image = try canvas.renderedImage()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
            WindowActivationCoordinator.shared.register(panel)
            defer { WindowActivationCoordinator.shared.unregister(panel) }
            if panel.runModal() == .OK, let url = panel.url {
                try ImageToolsUI.png(image).write(to: url, options: .atomic)
                ImageToolsUI.onCompletedImage?(image, pixelScale)
            }
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

/// Opt-in diagnostics for the development artifact only. The log contains no
/// image/text content, keyboard input, or pointer coordinates.
@MainActor
private enum ImageToolsPinGestureDiagnostics {
    static let enabled = Bundle.main.bundleIdentifier == "dev.screenleaf.development"
        && Bundle.main.object(forInfoDictionaryKey: "PatchPinGestureDiagnosticsEnabled") as? Bool == true
    static let eventMask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .beginGesture, .endGesture, .smartMagnify, .gesture]
    private static var lineCount = 0
    private static let output: FileHandle? = {
        guard enabled else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("patch-pin-gestures.log")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return nil }
        return try? FileHandle(forWritingTo: url)
    }()

    static func accepts(_ event: NSEvent) -> Bool {
        switch event.type {
        case .scrollWheel, .magnify, .beginGesture, .endGesture, .smartMagnify, .gesture: return true
        default: return false
        }
    }

    static func record(_ stage: String, event: NSEvent? = nil, window: NSWindow?,
                       pointerInside: Bool? = nil, before: CGFloat? = nil, after: CGFloat? = nil) {
        guard enabled, lineCount < 2_000, let output else { return }
        var fields = ["stage=\(stage)", "window=\(window?.windowNumber ?? 0)", "isKey=\(window?.isKeyWindow ?? false)"]
        if let event, accepts(event) {
            fields += ["time=\(event.timestamp)", "type=\(event.type.rawValue)", "target=\(event.windowNumber)",
                       "matchesWindow=\(event.window === window)", "phase=\(event.phase.rawValue)",
                       "momentum=\(event.momentumPhase.rawValue)"]
            if event.type == .scrollWheel {
                fields += ["precise=\(event.hasPreciseScrollingDeltas)", "deltaY=\(event.scrollingDeltaY)"]
            } else if event.type == .magnify { fields.append("magnification=\(event.magnification)") }
        }
        if let pointerInside { fields.append("pointerInside=\(pointerInside)") }
        if let before { fields.append("scaleBefore=\(before)") }
        if let after { fields.append("scaleAfter=\(after)") }
        lineCount += 1
        try? output.write(contentsOf: Data((fields.joined(separator: " ") + "\n").utf8))
    }
}

private final class ImageToolsPinPanel: NSPanel, CapturePinWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var diagnosesImageGestures = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if diagnosesImageGestures && ImageToolsPinGestureDiagnostics.accepts(event) {
            ImageToolsPinGestureDiagnostics.record("window", event: event, window: self)
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class ImageToolsPinImageView: NSView {
    var image: CGImage
    /// Full image geometry in this bounded, flipped view. It may extend offscreen.
    var imageRect: CGRect { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
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
        imageRect = CGRect(origin: .zero, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        toolTip = L("拖动移动 · 滚轮缩放 · 单击后捏合缩放 · 右键操作")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        guard let mapping = ImageToolsPinImageGeometry.crop(imageSize: CGSize(width: image.width, height: image.height),
                                                            imageRect: imageRect, visible: bounds),
              let crop = image.cropping(to: mapping.pixels) else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if cornerRadius > 0 {
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        }
        NSImage(cgImage: crop, size: mapping.destination.size).draw(in: mapping.destination, from: .zero,
            operation: .copy, fraction: 1, respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func scrollWheel(with event: NSEvent) {
        ImageToolsPinGestureDiagnostics.record("image-view", event: event, window: window)
        let speed: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
        onZoom?(exp(max(-40, min(40, event.scrollingDeltaY)) * speed), convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        ImageToolsPinGestureDiagnostics.record("image-view", event: event, window: window)
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        // NSTextView's native edge hit area can lag behind a scaled parent.
        // Keep the whole visible card available for editing and dragging.
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }
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
        let speed: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
        onZoom?(exp(max(-40, min(40, event.scrollingDeltaY)) * speed), convert(event.locationInWindow, from: nil))
    }
    override func magnify(with event: NSEvent) {
        onZoom?(max(0.1, 1 + event.magnification), convert(event.locationInWindow, from: nil))
    }
}

/// Opaque images keep a one-point frame outside their pixel-sized viewport.
/// Transparent cutouts keep their original unframed surface.
@MainActor
private final class ImageToolsPinSurface: NSView {
    var displaysImage = false { didSet { needsDisplay = true } }
    var showsBorder = false { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var imageBorderRect: CGRect? { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if !displaysImage {
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if showsBorder {
            ToolbarPalette.border.setStroke()
            let width = ImageToolsWindowBorder.width
            let rect = imageBorderRect ?? bounds.insetBy(dx: width / 2, dy: width / 2)
            let edge = NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5)
            edge.lineWidth = width
            edge.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Selection stays inside the visible viewport, without changing content or hit testing.
@MainActor
private final class ImageToolsPinSelectionOutline: NSView {
    private var opacity: CGFloat = 0
    private var fadeTimer: Timer?
    var selectionRect: CGRect? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0
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
        let rect = selectionRect ?? bounds
        let width = min(1.5, min(rect.width, rect.height) / 4)
        ToolbarPalette.accent.withAlphaComponent(opacity).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
            xRadius: max(0, cornerRadius - width / 2), yRadius: max(0, cornerRadius - width / 2))
        edge.lineWidth = width
        edge.stroke()
        // A fine inner light edge keeps the selection visible over dark or blue images.
        if min(rect.width, rect.height) >= 8 {
            NSColor.white.withAlphaComponent(opacity * 0.85).setStroke()
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: width + 0.25, dy: width + 0.25),
                xRadius: max(0, cornerRadius - width - 0.25), yRadius: max(0, cornerRadius - width - 0.25))
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
        let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: L("移动贴图"))
        symbol?.withSymbolConfiguration(.init(paletteColors: [ToolbarPalette.secondaryInk]))?.draw(
            in: CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16))
    }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// AppKit screen coordinates, with a stable target display for all pins in one batch.
// PIN_IMAGE_GEOMETRY_BEGIN
/// The whole image retains its aspect ratio. Only its on-desktop portion gets a
/// native window/backing store; clipping never changes the stored source bitmap.
enum ImageToolsPinImageGeometry {
    static func initialAvailableSize(visible: CGSize) -> CGSize {
        // Leave room for the frame; the initial card uses at most half of each display dimension.
        CGSize(width: max(1, visible.width / 2 - 2), height: max(1, visible.height / 2 - 2))
    }
    static func naturalSize(pixels: CGSize, sourceScale: CGFloat?) -> CGSize {
        let factor = sourceScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        return CGSize(width: pixels.width / factor, height: pixels.height / factor)
    }
    static func fitScale(size: CGSize, available: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, max(0.0001, min(available.width / size.width, available.height / size.height)))
    }
    static func desktopBounds(_ frames: [CGRect]) -> CGRect {
        frames.filter { !$0.isEmpty && !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
    }
    static func hostFrame(image: CGRect, inset: CGFloat, desktop: CGRect) -> CGRect {
        image.insetBy(dx: -inset, dy: -inset).intersection(desktop).integral
    }
    static func zoomed(_ rect: CGRect, factor: CGFloat, anchor: CGPoint) -> CGRect {
        CGRect(x: anchor.x + (rect.minX - anchor.x) * factor,
               y: anchor.y + (rect.minY - anchor.y) * factor,
               width: rect.width * factor, height: rect.height * factor)
    }
    static func keepingReachable(_ rect: CGRect, within visible: CGRect) -> CGRect {
        // A large image can move past any screen edge, while retaining a handle.
        let gripX = min(32, rect.width), gripY = min(32, rect.height)
        return CGRect(x: min(max(rect.minX, visible.minX + gripX - rect.width), visible.maxX - gripX),
                      y: min(max(rect.minY, visible.minY + gripY - rect.height), visible.maxY - gripY),
                      width: rect.width, height: rect.height)
    }
    static func crop(imageSize: CGSize, imageRect: CGRect, visible: CGRect) -> (pixels: CGRect, destination: CGRect)? {
        let area = imageRect.intersection(visible)
        guard !area.isNull, !area.isEmpty, imageRect.width > 0, imageRect.height > 0 else { return nil }
        let x = imageSize.width / imageRect.width, y = imageSize.height / imageRect.height
        // Include a source-pixel margin so interpolation does not introduce seams
        // at the bounded window edge. The native context clips the extra pixels.
        let pixels = CGRect(x: (area.minX - imageRect.minX) * x, y: (area.minY - imageRect.minY) * y,
                            width: area.width * x, height: area.height * y)
            .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard !pixels.isEmpty else { return nil }
        return (pixels, CGRect(x: imageRect.minX + pixels.minX / x, y: imageRect.minY + pixels.minY / y,
                               width: pixels.width / x, height: pixels.height / y))
    }
}
// PIN_IMAGE_GEOMETRY_END

enum ImageToolsPinPlacement {
    static func avoidingStack(_ preferred: CGRect, visible: CGRect, occupied: [CGRect]) -> CGRect {
        func hasSameCorner(_ candidate: CGRect) -> Bool {
            occupied.contains { abs($0.minX - candidate.minX) < 12 && abs($0.maxY - candidate.maxY) < 12 }
        }
        guard hasSameCorner(preferred) else { return preferred }
        let directionX: CGFloat = preferred.midX > visible.midX ? -1 : 1
        let directionY: CGFloat = preferred.midY > visible.midY ? -1 : 1
        func candidate(_ dx: CGFloat, _ dy: CGFloat) -> CGRect {
            CGRect(x: min(max(preferred.minX + dx, visible.minX), visible.maxX - preferred.width),
                   y: min(max(preferred.minY + dy, visible.minY), visible.maxY - preferred.height),
                   width: preferred.width, height: preferred.height)
        }
        // Prefer a subtle diagonal cascade; near an edge, either axis may still have room.
        // Bound the search even when the viewport fills the entire display.
        for index in 1...20 {
            let step = CGFloat(index) * 18
            for offset in [CGSize(width: directionX * step, height: directionY * step),
                           CGSize(width: directionX * step, height: 0),
                           CGSize(width: 0, height: directionY * step)] {
                let next = candidate(offset.width, offset.height)
                if !hasSameCorner(next) { return next }
            }
        }
        return preferred
    }

    static func screenIndex(for anchor: CGPoint, frames: [CGRect]) -> Int? {
        if let containing = frames.firstIndex(where: { $0.contains(anchor) }) { return containing }
        return frames.indices.min { left, right in
            func distance(_ frame: CGRect) -> CGFloat {
                let dx = max(frame.minX - anchor.x, 0, anchor.x - frame.maxX)
                let dy = max(frame.minY - anchor.y, 0, anchor.y - frame.maxY)
                return dx * dx + dy * dy
            }
            return distance(frames[left]) < distance(frames[right])
        }
    }

    static func frame(size: CGSize, anchor: CGPoint, visible: CGRect, batchIndex: Int = 0) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX), visible.maxX - width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY), visible.maxY - height) }
        let x = clampX(anchor.x + 16), y = clampY(anchor.y - 16 - height)
        // Cascade toward the half of the display with more room, without changing display.
        let step = CGFloat(max(0, batchIndex)) * 32
        let dx = x + width / 2 > visible.midX ? -step : step
        let dy = y + height / 2 > visible.midY ? -step : step
        return CGRect(x: clampX(x + dx), y: clampY(y + dy), width: width, height: height)
    }
}

@MainActor
private final class ImageToolsPinController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onClose: (() -> Void)?
    var onOCR: ((CGImage) -> Void)?
    var isAnnotating: Bool { inlineEditor != nil }
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
    private var textStyleButtons: [NSButton] = []
    private var textSizeControl: AnnotationSizeControl?
    private let preferences: PreferencesStore?
    private var baseSize = CGSize(width: 440, height: 240)
    private let textPresentation = NSView()
    private var textFrame: CGRect?
    private var textLayoutWidthLimit: CGFloat = 440
    private var minimumTextScale: CGFloat = 0.05
    private var scale: CGFloat = 1
    private var imagePixelScale: CGFloat?
    private var imageFrame: CGRect?
    private var lastPresentedHostFrame: CGRect?
    private var isUpdatingImageHost = false
    private var beforeEditingImageFrame: CGRect?
    private var minimumImageScale: CGFloat = 0.05
    private var hudScreenPoint: CGPoint?
    // Recompute only when the source image changes, never while zooming or selecting.
    private var imageHasTransparency = false
    private let initialAnchor: NSPoint
    private let initialBatchIndex: Int
    private var initialVisibleArea: CGRect?
    private var gestureDiagnosticMonitor: Any?

    deinit {
        if let gestureDiagnosticMonitor { NSEvent.removeMonitor(gestureDiagnosticMonitor) }
    }

    convenience init(image: CGImage, pixelScale: CGFloat? = nil, preferences: PreferencesStore? = nil,
                     anchor: NSPoint? = nil, batchIndex: Int = 0) {
        self.init(title: L("Patch · 图片贴图"), preferences: preferences, anchor: anchor ?? NSEvent.mouseLocation, batchIndex: batchIndex)
        imagePixelScale = pixelScale
        let size = Self.initialImageSize(image, pixelScale: pixelScale)
        baseSize = size
        let view = ImageToolsPinImageView(image: image, size: .zero)
        imageView = view
        imageHasTransparency = ImageToolsUI.hasTransparentPixels(image)
        surface.displaysImage = true
        window?.minSize = CGSize(width: 1, height: 1)
        view.onMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        view.onZoom = { [weak self] factor, point in self?.changeScale(by: factor, anchoredAt: point) }
        view.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        view.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        view.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        scroll.isHidden = true
        surface.addSubview(view, positioned: .below, relativeTo: selectionOutline)
        let visible = visibleArea()
        scale = ImageToolsPinImageGeometry.fitScale(size: size,
            available: ImageToolsPinImageGeometry.initialAvailableSize(visible: visible.size))
        minimumImageScale = min(0.2, scale / 4)
        let inset = presentationInset
        let initialSize = CGSize(width: size.width * scale + inset * 2, height: size.height * scale + inset * 2)
        imageFrame = ImageToolsPinPlacement.frame(size: initialSize, anchor: initialAnchor,
            visible: visible, batchIndex: initialBatchIndex).insetBy(dx: inset, dy: inset)
        hudScreenPoint = initialAnchor
        configureHUD()
        updateScale()
        placeInitially()
        installGestureDiagnostics()
    }

    private func installGestureDiagnostics() {
        guard ImageToolsPinGestureDiagnostics.enabled, gestureDiagnosticMonitor == nil else { return }
        (window as? ImageToolsPinPanel)?.diagnosesImageGestures = true
        ImageToolsPinGestureDiagnostics.record("attached", window: window, after: scale)
        gestureDiagnosticMonitor = NSEvent.addLocalMonitorForEvents(matching: ImageToolsPinGestureDiagnostics.eventMask) { [weak self] event in
            guard let self, let window = self.window else { return event }
            let pointerInside = window.isVisible && window.frame.contains(NSEvent.mouseLocation)
            if event.window === window || pointerInside {
                ImageToolsPinGestureDiagnostics.record("app", event: event, window: window, pointerInside: pointerInside)
            }
            return event
        }
    }

    convenience init(attributedText: NSAttributedString, preferences: PreferencesStore? = nil, anchor: NSPoint? = nil, batchIndex: Int = 0) {
        self.init(text: attributedText.string, preferences: preferences, anchor: anchor, batchIndex: batchIndex)
        textView?.textStorage?.setAttributedString(attributedText)
        if let paragraph = textView?.defaultParagraphStyle {
            textView?.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: attributedText.length))
        }
        resizeText(); fitTextInitially(); updateScale()
    }

    convenience init(text: String, preferences: PreferencesStore? = nil, anchor: NSPoint? = nil, batchIndex: Int = 0) {
        self.init(title: L("Patch · 文字贴图"), preferences: preferences, anchor: anchor ?? NSEvent.mouseLocation, batchIndex: batchIndex)
        textLayoutWidthLimit = ImageToolsPinImageGeometry.initialAvailableSize(visible: visibleArea().size).width
        let view = ImageToolsPinTextView(frame: CGRect(origin: .zero, size: baseSize))
        view.isRichText = true
        view.importsGraphics = false; view.allowsUndo = true
        view.isEditable = false; view.isSelectable = false
        view.font = .systemFont(ofSize: 16)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = CGSize(width: 16, height: 16)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = CGSize(width: baseSize.width - 32, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        view.autoresizingMask = []
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        view.defaultParagraphStyle = paragraph
        view.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (text as NSString).length))
        view.typingAttributes[.paragraphStyle] = paragraph
        view.delegate = self
        view.toolTip = L("拖动移动 · 双击编辑文字 · 滚轮或捏合缩放")
        view.onBeginEditing = { [weak self] in self?.setTextEditing(true) }
        view.onMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        view.onZoom = { [weak self] factor, point in self?.changeScale(by: factor, anchoredAt: point) }
        view.onSelect = { [weak self] in self?.selectPin() }
        view.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        view.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        view.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        textView = view
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 6
        surface.layer?.masksToBounds = true
        selectionOutline.cornerRadius = 6
        window?.minSize = CGSize(width: 1, height: 1)
        scroll.isHidden = true
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        textPresentation.addSubview(view)
        surface.addSubview(textPresentation, positioned: .below, relativeTo: selectionOutline)
        resizeText()
        fitTextInitially()
        configureHUD()
        updateScale()
        placeInitially()
    }

    private init(title: String, preferences: PreferencesStore?, anchor: NSPoint, batchIndex: Int) {
        self.preferences = preferences
        initialAnchor = anchor; initialBatchIndex = batchIndex
        let screens = NSScreen.screens
        initialVisibleArea = ImageToolsPinPlacement.screenIndex(for: anchor, frames: screens.map(\.frame))
            .map { screens[$0].visibleFrame } ?? NSScreen.main?.visibleFrame
        let panel = ImageToolsPinPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Image initialization and annotation mode choose the appropriate presentation.
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
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
        NotificationCenter.default.addObserver(self, selector: #selector(displayConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func placeInitially() {
        guard let window else { return }
        if imageFrame != nil || textFrame != nil { initialVisibleArea = nil; layoutHUD(); return }
        let visible = visibleArea()
        // Layout first: text wrapping and image scale determine the actual viewport size.
        window.setFrame(ImageToolsPinPlacement.frame(size: window.frame.size, anchor: initialAnchor,
            visible: visible, batchIndex: initialBatchIndex), display: false)
        initialVisibleArea = nil
        layoutHUD()
    }

    func avoidInitialOverlap(with occupied: [CGRect]) {
        guard let window else { return }
        let frame = ImageToolsPinPlacement.avoidingStack(window.frame, visible: visibleArea(), occupied: occupied)
        if let imageFrame {
            self.imageFrame = imageFrame.offsetBy(dx: frame.minX - window.frame.minX, dy: frame.minY - window.frame.minY)
            updateScale()
            return
        }
        if let textFrame {
            self.textFrame = textFrame.offsetBy(dx: frame.minX - window.frame.minX, dy: frame.minY - window.frame.minY)
            updateScale(); return
        }
        window.setFrameOrigin(frame.origin)
        layoutHUD()
    }

    private static func initialImageSize(_ image: CGImage, pixelScale: CGFloat? = nil) -> CGSize {
        ImageToolsPinImageGeometry.naturalSize(pixels: CGSize(width: image.width, height: image.height), sourceScale: pixelScale)
    }
    private func configureHUD() {
        toolbar.onDisplayMetricsChanged = { [weak self] in self?.layoutHUD() }
        let handle = ImageToolsPinDragHandle()
        handle.toolTip = L("拖动移动贴图")
        handle.setAccessibilityLabel(L("移动贴图"))
        handle.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        handle.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        handle.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        func button(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSButton {
            let button = SelectionButton(title, symbol: symbol, action: action)
            button.imagePosition = .imageOnly
            return button
        }
        var row: [NSView] = [handle]
        var textFormattingRow: [NSView] = []
        var textCompletion: SelectionButton?
        textColorButtons = []; textStyleButtons = []; textSizeControl = nil
        if let textView {
            if textView.isMoving {
                row.append(button(L("编辑文字"), SelectionButton.annotationSymbol) { [weak self] in self?.setTextEditing(true) })
            } else {
                textCompletion = SelectionButton.confirmation(L("完成编辑"), toolTip: L("完成文字编辑，复制并返回贴图")) {
                    [weak self] in self?.completeTextEditing()
                }
            }
            if !textView.isMoving {
                for (title, color) in [(L("默认颜色"), NSColor.labelColor), (L("红色"), .systemRed), (L("橙色"), .systemOrange),
                                       (L("绿色"), .systemGreen), (L("蓝色"), .systemBlue)] {
                    let item = SelectionOptionButton(sample: .color(color), label: title) { [weak self] in self?.colorSelectedText(color) }
                    item.isEnabled = textView.selectedRange().length > 0
                    textColorButtons.append(item); row.append(item)
                }
                let size = AnnotationSizeControl(frame: .zero)
                size.onChange = { [weak self] in self?.resizeSelectedText(CGFloat($0)) }
                size.onBegin = { [weak self] in self?.textView?.undoManager?.beginUndoGrouping() }
                size.onEnd = { [weak self] in self?.textView?.undoManager?.endUndoGrouping() }
                textSizeControl = size
                let sizeLabel = NSTextField(labelWithString: L("字号"))
                sizeLabel.font = .systemFont(ofSize: 11, weight: .medium)
                sizeLabel.textColor = ToolbarPalette.secondaryInk
                textFormattingRow += [sizeLabel, size]
                for (title, symbol, trait) in [("粗体", "bold", NSFontTraitMask.boldFontMask),
                                                ("斜体", "italic", NSFontTraitMask.italicFontMask)] {
                    let item = button(L(title), symbol) { [weak self] in self?.toggleSelectedTextTrait(trait) }
                    item.setButtonType(.pushOnPushOff)
                    item.allowsMixedState = true
                    textStyleButtons.append(item); textFormattingRow.append(item)
                }
                row.append(button(L("撤销"), "arrow.uturn.backward") { [weak self] in self?.textView?.undoManager?.undo() })
            }
        }
        if imageView != nil {
            row.append(button(L("标注"), SelectionButton.annotationSymbol) { [weak self] in self?.annotateImage() })
            row.append(button(L("提取文字"), "text.viewfinder") { [weak self] in self?.ocrImage() })
        }
        row.append(button(imageView != nil ? L("复制图片") : L("复制文字"), "doc.on.doc") { [weak self] in self?.copyContent() })
        if imageView != nil {
            let save = button(L("保存 PNG"), "square.and.arrow.down") { [weak self] in self?.saveImage() }
            save.toolTip = L("保存 PNG（⌘S）")
            row.append(save)
        }
        row.append(button(L("关闭贴图"), "xmark") { [weak self] in self?.closePin() })
        if let textCompletion { row.append(textCompletion) }
        toolbar.trailingActions = textCompletion == nil ? [] : Array(row.suffix(2))
        toolbar.rows = [row] + (textFormattingRow.isEmpty ? [] : [textFormattingRow])
        refreshTextStyleControls()
        if hud != nil { layoutHUD(); return }
        let panel = ImageToolsPinHUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.contentView = toolbar
        hud = panel
        layoutHUD()
    }
    private func selectPin() {
        // A nonactivating panel can take keyboard focus in another app's full-screen
        // Space without bringing Patch's normal windows (and their Space) forward.
        if window?.isVisible == true {
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
    @objc private func applicationDeactivated(_ notification: Notification) {
        setSelected(window?.isKeyWindow == true)
    }
    @objc private func applicationActivated(_ notification: Notification) { if selected { layoutHUD() } }
    @objc private func displayConfigurationChanged(_ notification: Notification) {
        guard imageView != nil || textView != nil, inlineEditor == nil else { return }
        if let point = hudScreenPoint, !NSScreen.screens.contains(where: { $0.frame.contains(point) }) { hudScreenPoint = nil }
        updateScale()
    }
    private func screenPoint(for event: NSEvent) -> CGPoint? {
        (event.window ?? window)?.convertPoint(toScreen: event.locationInWindow)
    }
    private func beginMoving(with event: NSEvent) {
        // Selection may resize the viewport to make room for the detached HUD.
        guard let point = screenPoint(for: event) else { return }
        if imageView != nil && inlineEditor == nil {
            // A nonactivating panel may be key while its application is still
            // background. Real pinch events require foreground activation.
            // Use the running application's state, not NSApp.isActive, which
            // can already be true when this nonactivating panel takes key focus.
            NSRunningApplication.current.activate(options: [])
        }
        selectPin()
        guard let window else { return }
        dragOrigin = (point, inlineEditor == nil ? (imageFrame ?? textFrame ?? window.frame) : window.frame)
    }
    private func continueMoving(with event: NSEvent) {
        guard let dragOrigin, let point = screenPoint(for: event), let window else { return }
        let requested = dragOrigin.frame.offsetBy(dx: point.x - dragOrigin.point.x, dy: point.y - dragOrigin.point.y)
        // Choose the destination display by the pointer, including displays with negative origins.
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? visibleArea()
        if inlineEditor == nil, imageFrame != nil || textFrame != nil {
            hudScreenPoint = point
            let reachable = ImageToolsPinImageGeometry.keepingReachable(requested, within: visible)
            if imageView != nil { imageFrame = reachable } else { textFrame = reachable }
            updateScale()
            return
        }
        window.setFrame(Self.frameFittingVisibleArea(requested, in: visible), display: true)
        layoutHUD()
    }
    private func endMoving(with event: NSEvent) { continueMoving(with: event); dragOrigin = nil }
    private func visibleArea() -> CGRect {
        if let initialVisibleArea { return initialVisibleArea }
        if imageFrame != nil || textFrame != nil, let point = hudScreenPoint,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) { return screen.visibleFrame }
        return window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1400, height: 900)
    }
    private func layoutHUD() {
        guard inlineEditor == nil, let window, let hud else { return }
        toolbar.configure(forBackingScaleFactor: hud.screen?.backingScaleFactor ?? window.backingScaleFactor)
        let visible = visibleArea()
        let size = toolbar.arrange(maxWidth: max(100, min(480, visible.width - 24)))
        hud.setContentSize(size)
        let gap: CGFloat = 6
        let intersected = window.frame.intersection(visible)
        let pin = imageView != nil && !intersected.isEmpty && !intersected.isNull ? intersected : window.frame
        let candidates = [
            CGRect(x: pin.midX - size.width / 2, y: pin.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: pin.midX - size.width / 2, y: pin.maxY + gap, width: size.width, height: size.height),
            CGRect(x: pin.maxX + gap, y: pin.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: pin.minX - gap - size.width, y: pin.midY - size.height / 2, width: size.width, height: size.height)
        ]
        let frame = candidates.map { Self.frameFittingVisibleArea($0, in: visible) }.first { !$0.intersects(window.frame) }
            ?? Self.frameFittingVisibleArea(candidates[0], in: visible)
        hud.setFrame(frame, display: true)
        if selected && window.isVisible && window.isKeyWindow {
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
            _ = add(L("标注"), symbol: SelectionButton.annotationSymbol, action: #selector(annotateImage))
            _ = add(L("提取文字"), symbol: "text.viewfinder", action: #selector(ocrImage))
            _ = add(L("保存 PNG"), symbol: "square.and.arrow.down", action: #selector(saveImage))
        } else {
            _ = add(textView?.isMoving == true ? L("编辑文字") : L("完成编辑"), symbol: textView?.isMoving == true ? SelectionButton.annotationSymbol : "checkmark", action: #selector(toggleMoveMode))
        }
        _ = add(imageView != nil ? L("复制图片") : L("复制文字"), symbol: "doc.on.doc", action: #selector(copyContent))
        menu.addItem(.separator())
        _ = add(L("缩小"), symbol: "minus.magnifyingglass", action: #selector(zoomOut))
        _ = add(L("恢复大小"), symbol: "arrow.counterclockwise", action: #selector(resetZoom))
        _ = add(L("放大"), symbol: "plus.magnifyingglass", action: #selector(zoomIn))
        menu.addItem(.separator())
        _ = add(L("关闭贴图"), symbol: "xmark", action: #selector(closePin))
        return menu
    }

    func focusTextIfNeeded() {
        guard let textView else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        setSelected(true)
    }
    @objc private func zoomOut() { changeScale(by: 1 / 1.25) }
    @objc private func zoomIn() { changeScale(by: 1.25) }
    @objc private func resetZoom() {
        if imageView != nil { changeScale(by: 1 / scale) }
        else { scale = 1; updateScale() }
    }
    @objc private func closePin() { close() }
    @objc private func toggleMoveMode() {
        guard let textView else { return }
        if textView.isMoving { setTextEditing(true) } else { completeTextEditing() }
    }
    private func completeTextEditing() {
        guard let textView, !textView.isMoving else { return }
        // Completion copies the whole card, even when a style-editing range remains selected.
        if textView.hasMarkedText() { textView.unmarkText() }
        do {
            try copyTextContent(selectedOnly: false)
            setTextEditing(false)
        } catch { showError(error) }
    }
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
        changeSelectedTextStyle { text in
            text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
        }
    }
    private func resizeSelectedText(_ size: CGFloat) {
        guard size.isFinite, size > 0 else { return }
        changeSelectedTextStyle { text in
            let original = NSAttributedString(attributedString: text)
            original.enumerateAttribute(.font, in: NSRange(location: 0, length: original.length)) { value, range, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: 16)
                text.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: range)
            }
        }
    }
    private func toggleSelectedTextTrait(_ trait: NSFontTraitMask) {
        changeSelectedTextStyle { text in
            let original = NSAttributedString(attributedString: text)
            let range = NSRange(location: 0, length: original.length)
            var allHaveTrait = true
            original.enumerateAttributes(in: range) { attributes, _, _ in
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
                let selected = trait == .italicFontMask ? ImageToolsUI.textIsItalic(attributes)
                    : NSFontManager.shared.traits(of: font).contains(trait)
                allHaveTrait = allHaveTrait && selected
            }
            original.enumerateAttributes(in: range) { attributes, range, _ in
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
                if trait == .italicFontMask {
                    // Native italic Latin faces do not slant fallback CJK glyphs.
                    // Obliqueness applies to every glyph and survives RTF round-trips.
                    text.addAttribute(.font, value: NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask), range: range)
                    if allHaveTrait { text.removeAttribute(.obliqueness, range: range) }
                    else { text.addAttribute(.obliqueness, value: 0.2, range: range) }
                } else {
                    let converted = allHaveTrait ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
                        : NSFontManager.shared.convert(font, toHaveTrait: trait)
                    text.addAttribute(.font, value: converted, range: range)
                }
            }
        }
    }
    private func changeSelectedTextStyle(_ change: (NSMutableAttributedString) -> Void) {
        guard let textView, !textView.isMoving, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        change(replacement)
        guard !replacement.isEqual(to: storage.attributedSubstring(from: range)) else { return }
        restoreTextStyle(replacement, range: range)
    }
    private func restoreTextStyle(_ replacement: NSAttributedString, range: NSRange) {
        guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        let inverse = storage.attributedSubstring(from: range)
        textView.undoManager?.registerUndo(withTarget: self) { target in target.restoreTextStyle(inverse, range: range) }
        textView.undoManager?.setActionName(L("文字样式"))
        storage.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(range)
        resizeText(); updateScale(); refreshTextStyleControls()
    }
    private func refreshTextStyleControls() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let enabled = !textView.isMoving && range.length > 0 && NSMaxRange(range) <= storage.length
        textColorButtons.forEach { $0.isEnabled = enabled }
        textStyleButtons.forEach { $0.isEnabled = enabled; $0.state = .off }
        textSizeControl?.isEnabled = enabled
        var fonts: [NSFont] = []
        var italicStates: [Bool] = []
        if enabled {
            storage.enumerateAttributes(in: range) { attributes, _, _ in
                fonts.append(attributes[.font] as? NSFont ?? .systemFont(ofSize: 16))
                italicStates.append(ImageToolsUI.textIsItalic(attributes))
            }
        }
        textSizeControl?.configure(category: L("字号"), value: Double(fonts.first?.pointSize ?? 16), range: 8...72, step: 1)
        if let first = fonts.first, fonts.contains(where: { $0.pointSize != first.pointSize }) {
            textSizeControl?.valueLabel.stringValue = "—"
        }
        for (button, trait) in zip(textStyleButtons, [NSFontTraitMask.boldFontMask, .italicFontMask]) {
            let states = trait == .italicFontMask ? italicStates : fonts.map { NSFontManager.shared.traits(of: $0).contains(trait) }
            button.state = states.isEmpty || states.allSatisfy({ !$0 }) ? .off : (states.allSatisfy({ $0 }) ? .on : .mixed)
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) { refreshTextStyleControls() }
    private func changeScale(by factor: CGFloat, anchoredAt point: CGPoint? = nil) {
        let previousScale = scale
        defer {
            if imageView != nil {
                ImageToolsPinGestureDiagnostics.record("scale", event: NSApp.currentEvent, window: window,
                    before: previousScale, after: scale)
            }
        }
        guard factor.isFinite, factor > 0 else { return }
        if let imageView, let imageFrame, let window {
            let next = min(4, max(minimumImageScale, scale * factor))
            let anchor = point.map { window.convertPoint(toScreen: imageView.convert($0, to: nil)) }
                ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
            hudScreenPoint = anchor
            self.imageFrame = ImageToolsPinImageGeometry.zoomed(imageFrame, factor: next / scale, anchor: anchor)
            scale = next
            updateScale()
            return
        }
        if let textView, let textFrame, let window {
            let next = min(4, max(minimumTextScale, scale * factor))
            let anchor = point.map { window.convertPoint(toScreen: textView.convert($0, to: nil)) }
                ?? CGPoint(x: window.frame.midX, y: window.frame.midY)
            hudScreenPoint = anchor
            self.textFrame = ImageToolsPinImageGeometry.zoomed(textFrame, factor: next / scale, anchor: anchor)
            scale = next
            updateScale()
        }
    }
    private func updateScale() {
        guard inlineEditor == nil else { return }
        if imageView != nil { updateImagePresentation() }
        else { updateTextPresentation() }
    }
    private func fitTextInitially() {
        let visible = visibleArea()
        let available = ImageToolsPinImageGeometry.initialAvailableSize(visible: visible.size)
        scale = ImageToolsPinImageGeometry.fitScale(size: baseSize, available: available)
        minimumTextScale = min(0.2, scale / 4)
        let inset = presentationInset
        let size = CGSize(width: baseSize.width * scale + inset * 2, height: baseSize.height * scale + inset * 2)
        textFrame = ImageToolsPinPlacement.frame(size: size, anchor: initialAnchor,
            visible: visible, batchIndex: initialBatchIndex).insetBy(dx: inset, dy: inset)
        hudScreenPoint = initialAnchor
    }
    private func updateTextPresentation() {
        guard let window, textView != nil, var rect = textFrame else { return }
        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        if rect.size != size { rect = CGRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height) }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let desktop = ImageToolsPinImageGeometry.desktopBounds(screens.isEmpty ? [visibleArea()] : screens)
        if !screens.contains(where: { !$0.intersection(rect).isEmpty && !$0.intersection(rect).isNull }) {
            rect = ImageToolsPinImageGeometry.keepingReachable(rect, within: visibleArea())
        }
        textFrame = rect
        let host = ImageToolsPinImageGeometry.hostFrame(image: rect, inset: presentationInset, desktop: desktop)
        guard !host.isNull, !host.isEmpty else { return }
        isUpdatingImageHost = true
        window.setFrame(host, display: false)
        lastPresentedHostFrame = window.frame
        isUpdatingImageHost = false
        scroll.isHidden = true
        refreshPinPresentation()
        layoutHUD()
    }
    private func updateImagePresentation() {
        guard let window, let imageView, var rect = imageFrame else { return }
        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        if rect.size != size { rect = CGRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height) }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let desktop = ImageToolsPinImageGeometry.desktopBounds(screens.isEmpty ? [visibleArea()] : screens)
        if !screens.contains(where: { !$0.intersection(rect).isEmpty && !$0.intersection(rect).isNull }) {
            rect = ImageToolsPinImageGeometry.keepingReachable(rect, within: visibleArea())
        }
        imageFrame = rect
        let host = ImageToolsPinImageGeometry.hostFrame(image: rect, inset: presentationInset, desktop: desktop)
        guard !host.isNull, !host.isEmpty else { return }
        isUpdatingImageHost = true
        window.setFrame(host, display: false)
        lastPresentedHostFrame = window.frame
        isUpdatingImageHost = false
        imageView.frame = surface.bounds
        imageView.imageRect = CGRect(x: rect.minX - host.minX, y: host.maxY - rect.maxY,
                                     width: rect.width, height: rect.height)
        scroll.isHidden = true
        refreshPinPresentation()
        layoutHUD()
    }
    private var hasFramedContent: Bool { textView != nil || (imageView != nil && !imageHasTransparency) }
    private var presentationInset: CGFloat { hasFramedContent ? ImageToolsWindowBorder.width : 0 }
    private func layoutPinSurface() {
        guard inlineEditor == nil else { return }
        if let imageView, let imageFrame, let window {
            imageView.frame = surface.bounds
            imageView.imageRect = CGRect(x: imageFrame.minX - window.frame.minX, y: window.frame.maxY - imageFrame.maxY,
                                         width: imageFrame.width, height: imageFrame.height)
            let local = imageFrame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            selectionOutline.frame = surface.bounds
            selectionOutline.selectionRect = local
            surface.imageBorderRect = local.insetBy(dx: -presentationInset / 2, dy: -presentationInset / 2)
            return
        }
        if let textView, let textFrame, let window {
            let local = textFrame.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            // NSTextView rounds its own transformed geometry and hit regions.
            // Scale a plain parent instead, keeping editable text in logical points.
            textView.frame = CGRect(origin: .zero, size: baseSize)
            textPresentation.frame = local
            textPresentation.setBoundsSize(baseSize)
            selectionOutline.frame = surface.bounds
            selectionOutline.selectionRect = local
            surface.imageBorderRect = local.insetBy(dx: -presentationInset / 2, dy: -presentationInset / 2)
            return
        }
        selectionOutline.selectionRect = nil
        surface.imageBorderRect = nil
        scroll.frame = surface.bounds.insetBy(dx: presentationInset, dy: presentationInset)
        selectionOutline.frame = scroll.frame
    }
    private func refreshPinPresentation() {
        surface.showsBorder = inlineEditor == nil && hasFramedContent
        imageView?.cornerRadius = imageHasTransparency ? 0 : 5
        selectionOutline.cornerRadius = textView != nil ? 6 : (imageHasTransparency ? 0 : 5)
        let fullyVisible = (imageFrame ?? textFrame).map { window?.frame.contains($0.insetBy(dx: -presentationInset, dy: -presentationInset)) == true } ?? true
        window?.hasShadow = inlineEditor != nil || (hasFramedContent && fullyVisible)
        layoutPinSurface()
    }
    private static func frameFittingVisibleArea(_ requested: CGRect, in visible: CGRect) -> CGRect {
        let width = min(requested.width, visible.width), height = min(requested.height, visible.height)
        return CGRect(x: min(max(requested.minX, visible.minX), visible.maxX - width),
                      y: min(max(requested.maxY - height, visible.minY), visible.maxY - height), width: width, height: height)
    }
    @objc private func annotateImage() {
        guard inlineEditor == nil, let imageView, let window else { return }
        WindowActivationCoordinator.shared.register(window)
        beforeEditingFrame = window.frame
        beforeEditingImageFrame = imageFrame
        let handle = ImageToolsPinDragHandle()
        handle.toolTip = L("拖动移动贴图")
        handle.onMouseDown = { [weak self] in self?.beginMoving(with: $0) }
        handle.onMouseDragged = { [weak self] in self?.continueMoving(with: $0) }
        handle.onMouseUp = { [weak self] in self?.endMoving(with: $0) }
        let editor = InlineAnnotationView(image: imageView.image, pixelScale: imagePixelScale, preferences: preferences, moveHandle: handle,
                                          completionHint: L("完成标注，复制并返回贴图"), allowsOutsideAnnotations: true)
        inlineEditor = editor
        refreshPinPresentation()
        editor.onComplete = { [weak self] image in
            guard let self else { return }
            try ImageToolsUI.copyPNG(image, pixelScale: self.imagePixelScale, to: self.clipboard)
            self.endInlineEditing(image: image)
        }
        editor.onCancel = { [weak self] in self?.endInlineEditing(image: nil) }
        hud?.orderOut(nil); scroll.isHidden = true; imageView.isHidden = true; selectionOutline.isHidden = true
        let screenArea = visibleArea()
        let visible = screenArea.insetBy(dx: 20, dy: 20)
        let backingScale = NSScreen.screens.first { $0.visibleFrame == screenArea }?.backingScaleFactor
            ?? window.backingScaleFactor
        let preferredWidth = editor.preferredWindowSize(maximum: visible.size, backingScaleFactor: backingScale).width
        let size = CGSize(width: preferredWidth,
                          height: min(visible.height, max(480, window.frame.height)))
        window.setFrame(Self.frameFittingVisibleArea(CGRect(x: window.frame.minX, y: window.frame.maxY - size.height,
            width: size.width, height: size.height), in: visible), display: true)
        inlineWindowFrame = window.frame
        editor.frame = surface.bounds; editor.autoresizingMask = [.width, .height]
        surface.addSubview(editor); editor.fitImage()
        selectPin(); window.makeFirstResponder(editor.canvas)
    }
    private func endInlineEditing(image: CGImage?) {
        if let window { WindowActivationCoordinator.shared.unregister(window) }
        inlineEditor?.removeFromSuperview(); inlineEditor = nil
        scroll.isHidden = imageView != nil; imageView?.isHidden = false; selectionOutline.isHidden = false
        if let image, let imageView {
            // Keep the original image's pixel-to-point scale when outside marks
            // expand the document, rather than stretching it into the old frame.
            if image.width != imageView.image.width || image.height != imageView.image.height {
                baseSize = CGSize(width: baseSize.width * CGFloat(image.width) / CGFloat(imageView.image.width),
                                  height: baseSize.height * CGFloat(image.height) / CGFloat(imageView.image.height))
            }
            imageView.image = image
            imageHasTransparency = ImageToolsUI.hasTransparentPixels(image)
            imageView.needsDisplay = true
        }
        if let frame = beforeEditingFrame, let start = inlineWindowFrame, let window {
            let restored = frame.offsetBy(dx: window.frame.minX - start.minX, dy: window.frame.minY - start.minY)
            if let original = beforeEditingImageFrame {
                imageFrame = original.offsetBy(dx: window.frame.minX - start.minX, dy: window.frame.minY - start.minY)
            } else { window.setFrame(Self.frameFittingVisibleArea(restored, in: visibleArea()), display: true) }
        }
        beforeEditingFrame = nil
        beforeEditingImageFrame = nil
        inlineWindowFrame = nil
        updateScale(); selectPin()
    }
    private func replaceImage(_ image: CGImage) {
        imageView?.image = image
        imageHasTransparency = ImageToolsUI.hasTransparentPixels(image)
        baseSize = Self.initialImageSize(image, pixelScale: imagePixelScale)
        updateScale()
        if window?.isVisible == true { window?.orderFrontRegardless() }
    }
    @objc private func ocrImage() { if let imageView { onOCR?(imageView.image) } }
    private var clipboard: NSPasteboard = .general

    @objc private func copyContent() {
        do {
            if let imageView { try ImageToolsUI.copyPNG(imageView.image, pixelScale: imagePixelScale, to: clipboard) }
            else { try copyTextContent(selectedOnly: true) }
        } catch { showError(error) }
    }
    private func copyTextContent(selectedOnly: Bool) throws {
        guard let textView else { return }
        let selected = textView.selectedRange()
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        let range = selectedOnly && selected.length > 0 ? selected : all
        let text = (textView.string as NSString).substring(with: range)
        let item = NSPasteboardItem()
        let data = try ImageToolsUI.portableTextRTF(textView.attributedString().attributedSubstring(from: range))
        guard item.setString(text, forType: .string), item.setData(data, forType: .rtf) else {
            throw PatchError(message: L("无法复制文字及样式，请重试。"))
        }
        clipboard.clearContents()
        guard clipboard.writeObjects([item]) else {
            throw PatchError(message: L("无法复制文字及样式，请重试。"))
        }
        ImageToolsUI.onCompletedRichText?(textView.attributedString().attributedSubstring(from: range))
    }
    @objc private func saveImage() {
        guard let imageView else { return }
        let chooser = NSSavePanel()
        chooser.allowedContentTypes = [.png]
        chooser.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
        WindowActivationCoordinator.shared.register(chooser)
        defer { WindowActivationCoordinator.shared.unregister(chooser) }
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do { try ImageToolsUI.png(imageView.image).write(to: url, options: .atomic) }
        catch { showError(error) }
    }
    private func resizeText() {
        guard let textView, let container = textView.textContainer, let layout = textView.layoutManager else { return }
        let padding = textView.textContainerInset
        let naturalWidth = ceil(textView.attributedString().size().width) + padding.width * 2
        baseSize.width = min(textLayoutWidthLimit, max(min(48, textLayoutWidthLimit), naturalWidth))
        container.containerSize = CGSize(width: max(1, baseSize.width - padding.width * 2), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        baseSize.height = max(ceil((textView.font?.pointSize ?? 16) * 1.3), ceil(contentHeight)) + padding.height * 2
        let fit = ImageToolsPinImageGeometry.fitScale(size: baseSize,
            available: ImageToolsPinImageGeometry.initialAvailableSize(visible: visibleArea().size))
        minimumTextScale = min(minimumTextScale, fit / 4)
    }
    func textDidChange(_ notification: Notification) { resizeText(); updateScale(); refreshTextStyleControls() }
    func windowDidBecomeKey(_ notification: Notification) { setSelected(true) }
    func windowDidResignKey(_ notification: Notification) { setSelected(false) }
    func windowDidMove(_ notification: Notification) {
        // Window managers and macOS may move the bounded host without invoking
        // our drag gesture. Keep the whole image at that new screen position.
        if !isUpdatingImageHost, inlineEditor == nil, let frame = imageFrame ?? textFrame, let window,
           let previous = lastPresentedHostFrame {
            let dx = window.frame.minX - previous.minX, dy = window.frame.minY - previous.minY
            if dx != 0 || dy != 0 {
                if imageView != nil { imageFrame = frame.offsetBy(dx: dx, dy: dy) }
                else { textFrame = frame.offsetBy(dx: dx, dy: dy) }
                hudScreenPoint = nil
                updateScale()
            }
        }
        layoutHUD()
    }
    func windowDidResize(_ notification: Notification) { layoutPinSurface(); layoutHUD() }
    func windowDidChangeScreen(_ notification: Notification) { layoutHUD() }
    func windowDidChangeBackingProperties(_ notification: Notification) { imageView?.needsDisplay = true; layoutHUD() }
    func windowWillClose(_ notification: Notification) {
        if let gestureDiagnosticMonitor { NSEvent.removeMonitor(gestureDiagnosticMonitor) }
        gestureDiagnosticMonitor = nil
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
            guard !lines.isEmpty else { throw PatchError(message: L("没有识别到文字。可尝试截取更清晰或更大的文字区域。")) }
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
    private let status = NSTextField(labelWithString: L("识别中…"))
    private var copyButton: NSButton!
    private let writeClipboard: (String) -> Bool
    private var hasResult = false
    init(writeClipboard: ((String) -> Bool)? = nil) {
        self.writeClipboard = writeClipboard ?? { text in
            NSPasteboard.general.clearContents()
            let copied = NSPasteboard.general.setString(text, forType: .string)
            if copied { ImageToolsUI.onCompletedText?(text) }
            return copied
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 280),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: L("Patch · 提取文字"))
        let initialFrame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.setFrame(initialFrame, display: false)
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 300, height: 180)
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = WindowAmbientBackground.color
        window.contentView = WindowAmbientView()
        super.init(window: window)
        window.delegate = self
        setup(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if let window { WindowActivationCoordinator.shared.register(window) }
        super.showWindow(sender)
    }

    private func setup() {
        guard let window, let content = window.contentView,
              let layoutGuide = window.contentLayoutGuide as? NSLayoutGuide else { return }
        copyButton = ImageToolsCopyButton(L("复制并关闭"), symbol: "doc.on.doc") { [weak self] in self?.copyText() }
        copyButton.isEnabled = false
        let spacer = NSView()
        let actions = NSStackView(views: [spacer, copyButton])
        actions.spacing = 8
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        textView.frame = CGRect(x: 0, y: 0, width: 416, height: 220)
        textView.isRichText = false; textView.isEditable = false; textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
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
            stack.topAnchor.constraint(equalTo: layoutGuide.topAnchor, constant: 12),
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
        status.isHidden = true
        textView.isEditable = false
        textView.string = (error as? PatchError)?.message ?? L("无法完成文字识别，请重试。")
        copyButton.isEnabled = false
    }
    @objc private func copyText() {
        guard hasResult, !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard writeClipboard(textView.string) else {
            status.stringValue = L("未能复制，请重试。")
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
    static var onCompletedImage: ((CGImage, CGFloat?) -> Void)?
    static var onCompletedText: ((String) -> Void)?
    static var onCompletedRichText: ((NSAttributedString) -> Void)?

    static func clipboardImage(from pasteboard: NSPasteboard) -> (image: CGImage, pixelScale: CGFloat?)? {
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let saved = pasteboard.string(forType: pixelScalePasteboardType).flatMap(Double.init)
        let metadata = image.size.width > 0 ? CGFloat(cgImage.width) / image.size.width : nil
        return (cgImage, saved.map { CGFloat($0) } ?? metadata)
    }

    static let pixelScalePasteboardType = NSPasteboard.PasteboardType("dev.screenleaf.image-pixel-scale")

    static func png(_ image: CGImage, pixelScale: CGFloat? = nil) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let pixelScale, pixelScale.isFinite, pixelScale > 0 {
            bitmap.size = CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale)
        }
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PatchError(message: L("无法编码 PNG 图片。"))
        }
        return data
    }
    static func textIsItalic(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 16)
        return NSFontManager.shared.traits(of: font).contains(.italicFontMask)
            || abs((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0.001
    }

    /// Default text is automatic in the destination, not a resolved dark/light RGB color.
    /// Explicit colors, including white, remain intentional formatting.
    static func portableTextRTF(_ rich: NSAttributedString) throws -> Data {
        let value = NSMutableAttributedString(attributedString: rich)
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { color, range, _ in
            if (color as? NSColor)?.isEqual(NSColor.labelColor) == true {
                value.removeAttribute(.foregroundColor, range: range)
            }
        }
        return try value.data(from: NSRange(location: 0, length: value.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func normalizedText(_ rich: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: rich.string, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont { result.addAttribute(.font, value: font, range: range) }
            if let color = attributes[.foregroundColor] as? NSColor {
                result.addAttribute(.foregroundColor,
                    value: color.isEqual(NSColor.labelColor) ? NSColor.labelColor : (color.usingColorSpace(.deviceRGB) ?? color), range: range)
            }
            if let value = attributes[.obliqueness] { result.addAttribute(.obliqueness, value: value, range: range) }
        }
        let characters = result.string as NSString
        for index in (0..<result.length).reversed() where characters.character(at: index) == 0xFFFC {
            result.deleteCharacters(in: NSRange(location: index, length: 1))
        }
        return result
    }

    /// Import text styles only; attachments and document layout are not pin content.
    static func clipboardText(from pasteboard: NSPasteboard) -> NSAttributedString? {
        if let data = pasteboard.data(forType: .rtf),
           let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           rich.length > 0 {
            let result = normalizedText(rich)
            if result.length > 0 { return result }
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor])
    }

    static func copyPNG(_ image: CGImage, pixelScale: CGFloat? = nil, to pasteboard: NSPasteboard = .general) throws {
        let data = try png(image, pixelScale: pixelScale)
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw PatchError(message: L("无法将图片写入剪贴板。"))
        }
        if let pixelScale, pixelScale.isFinite, pixelScale > 0 {
            // PNG resolution metadata may round; keep the exact capture scale for our own round-trip.
            pasteboard.setString(String(Double(pixelScale)), forType: pixelScalePasteboardType)
        }
        if pasteboard.name == NSPasteboard.general.name { onCompletedImage?(image, pixelScale) }
    }
    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
