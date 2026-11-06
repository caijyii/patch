// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CoreImage

/// Session-only subject selection. All Vision work stays off the main thread.
@MainActor
final class SubjectSelectionController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onPin: ((CGImage) -> Void)?
    private let pixelScale: CGFloat?
    private let source: CGImage
    private let original = SubjectPreviewView()
    private let preview = SubjectPreviewView()
    private let status = NSTextField(wrappingLabelWithString: L("正在识别画面里的主体…"))
    private let progress = NSProgressIndicator()
    private let worker = DispatchQueue(label: "dev.screenleaf.subject-selection", qos: .userInitiated)
    private var extraction: SubjectExtractionResult?
    private var selected = IndexSet()
    private var history: [IndexSet] = []
    private var output: CGImage?
    private var generation = UUID()
    private var closed = false
    private var rendering = true
    private var undoButton: NSButton!
    private var resetButton: NSButton!
    private var outputButtons: [NSButton] = []

    init(image: CGImage, pixelScale: CGFloat? = nil) {
        self.pixelScale = pixelScale
        source = image
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = SubjectSelectionWindow(contentRect: CGRect(x: 0, y: 0,
            width: min(960, visible.width - 60), height: min(640, visible.height - 60)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: L("Patch · 主体截图"))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = CGSize(width: 650, height: 420)
        window.acceptsMouseMovedEvents = true
        window.contentView = SubjectContentView(frame: window.contentView?.bounds ?? .zero)
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.onShortcut = { [weak self] event in self?.handleShortcut(event) ?? false }
        window.center()
        analyze()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if let window { WindowActivationCoordinator.shared.register(window) }
        super.showWindow(sender)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: L("把画面里的小东西，贴到桌面上"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: L("在左侧点击主体，加入或移除；右侧预览透明结果。"))
        hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.startAnimation(nil)
        let message = NSStackView(views: [progress, status])
        message.spacing = 8
        original.source = source
        preview.source = source
        preview.checkerboard = true
        original.onClick = { [weak self] point in self?.toggle(at: point) }
        original.onHover = { [weak self] point in self?.hover(at: point) }
        let columns = NSStackView(views: [column(L("原图 · 点击选主体"), original), column(L("透明结果"), preview)])
        columns.spacing = 16
        columns.distribution = .fillEqually
        columns.setContentHuggingPriority(.defaultLow, for: .vertical)
        undoButton = SelectionButton(L("撤销"), symbol: "arrow.uturn.backward") { [weak self] in self?.undo() }
        resetButton = SelectionButton(L("重置"), symbol: "arrow.counterclockwise") { [weak self] in self?.reset() }
        let copy = SelectionButton(L("复制"), symbol: "doc.on.doc") { [weak self] in self?.copyImage() }
        copy.toolTip = L("复制透明 PNG（⌘C）")
        let save = SelectionButton(L("保存"), symbol: "square.and.arrow.down") { [weak self] in self?.save() }
        save.toolTip = L("保存透明 PNG（⌘S）")
        let pin = SelectionButton(L("贴到桌面"), symbol: "pin") { [weak self] in self?.pin() }
        let close = SelectionButton(L("关闭"), symbol: "xmark") { [weak self] in self?.close() }
        outputButtons = [copy, save, pin]
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [undoButton, resetButton, spacer, copy, save, pin, close])
        actions.spacing = 8
        let stack = NSStackView(views: [title, hint, columns, message, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            columns.widthAnchor.constraint(equalTo: stack.widthAnchor),
            columns.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        updateButtons()
    }

    private func column(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            view.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -24)])
        return stack
    }

    private func analyze() {
        let image = source
        let id = generation
        worker.async { [weak self] in
            let result = Result { () -> (SubjectExtractionResult, [Int: CGImage]) in
                let extraction = try SubjectExtraction.analyze(image)
                var masks: [Int: CGImage] = [:]
                for instance in extraction.instances {
                    if let mask = try extraction.maskImage(selecting: IndexSet(integer: instance)) {
                        masks[instance] = SubjectImageUtilities.tintedMask(mask)
                    }
                }
                return (extraction, masks)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == id else { return }
                switch result {
                case .success(let value):
                    self.extraction = value.0
                    self.selected = value.0.instances
                    self.original.masks = value.1
                    self.renderSelection()
                case .failure(let error): self.fail(error)
                }
            }
        }
    }

    private func toggle(at point: CGPoint) {
        guard let instance = extraction?.instance(atNormalizedTopLeft: point) else { return }
        history.append(selected)
        if selected.contains(instance) { selected.remove(instance) } else { selected.insert(instance) }
        renderSelection()
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        selected = previous
        renderSelection()
    }

    private func reset() {
        guard let extraction, selected != extraction.instances else { return }
        history.append(selected)
        selected = extraction.instances
        renderSelection()
    }

    private func renderSelection() {
        guard let extraction else { return }
        generation = UUID()
        let id = generation, selection = selected
        original.selected = selection
        output = nil
        rendering = true
        progress.startAnimation(nil)
        status.stringValue = L("正在更新透明结果…")
        updateButtons()
        worker.async { [weak self] in
            let result = Result { () -> (CGImage?, CGImage?) in
                let image = try extraction.image(selecting: selection)
                return (image, image.map { SubjectImageUtilities.trimTransparentMargins($0) })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == id else { return }
                self.rendering = false
                self.progress.stopAnimation(nil)
                switch result {
                case .success(let images):
                    self.output = images.1
                    self.preview.result = images.0
                    self.status.stringValue = selection.isEmpty ? L("还没有选中主体，请在左侧点击加入。") : LF("已选 %d / %d 个主体 · 再点一次可移除", selection.count, extraction.instances.count)
                    self.updateButtons()
                case .failure(let error): self.fail(error)
                }
            }
        }
    }

    private func hover(at point: CGPoint?) {
        original.hovered = point.flatMap { extraction?.instance(atNormalizedTopLeft: $0) }
    }

    private func fail(_ error: Error) {
        rendering = false
        output = nil
        preview.result = nil
        progress.stopAnimation(nil)
        status.stringValue = error.localizedDescription
        updateButtons()
    }

    private func updateButtons() {
        undoButton?.isEnabled = !history.isEmpty
        resetButton?.isEnabled = extraction.map { selected != $0.instances } ?? false
        outputButtons.forEach { $0.isEnabled = !rendering && output != nil }
    }

    private func copyImage() {
        guard !rendering, let output else { return }
        do { try ImageToolsUI.copyPNG(output, pixelScale: pixelScale); status.stringValue = L("已复制透明 PNG") }
        catch { showError(error, title: L("复制未完成")) }
    }

    private func save() {
        guard !rendering, let output, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Patch-主体-\(ImageToolsUI.timestamp()).png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try ImageToolsUI.png(output).write(to: url, options: .atomic); self?.status.stringValue = L("已保存透明 PNG"); ImageToolsUI.onCompletedImage?(output, self?.pixelScale) }
            catch { showError(error, title: L("保存未完成")) }
        }
    }

    private func pin() {
        guard !rendering, let output else { return }
        onPin?(output)
        close()
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { close(); return true }
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copyImage()
        case "s": save()
        case "z": undo()
        default: return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        generation = UUID()
        onClose?()
    }
}

@MainActor
private final class SubjectSelectionWindow: NSWindow {
    var onShortcut: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SubjectContentView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

@MainActor
private final class SubjectPreviewView: NSView {
    var source: CGImage? { didSet { needsDisplay = true } }
    var result: CGImage? { didSet { needsDisplay = true } }
    var masks: [Int: CGImage] = [:] { didSet { needsDisplay = true } }
    var selected = IndexSet() { didSet { needsDisplay = true } }
    var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
    var checkerboard = false
    var onClick: ((CGPoint) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    private var imageRect: CGRect {
        guard let source else { return .zero }
        let area = bounds.insetBy(dx: 12, dy: 12)
        let scale = min(area.width / CGFloat(source.width), area.height / CGFloat(source.height))
        let size = CGSize(width: CGFloat(source.width) * scale, height: CGFloat(source.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let rect = imageRect
        guard !rect.isEmpty else { return }
        if checkerboard {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            for row in 0...Int(ceil(rect.height / 12)) {
                for column in 0...Int(ceil(rect.width / 12)) {
                    NSColor(calibratedWhite: (row + column) % 2 == 0 ? 0.88 : 0.98, alpha: 1).setFill()
                    NSBezierPath(rect: CGRect(x: rect.minX + CGFloat(column) * 12, y: rect.minY + CGFloat(row) * 12, width: 12, height: 12)).fill()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            if let result { draw(result, in: rect) }
        } else {
            if let source { draw(source, in: rect) }
            for instance in selected { if let mask = masks[instance] { draw(mask, in: rect, fraction: 0.16) } }
            if let hovered, let mask = masks[hovered] { draw(mask, in: rect, fraction: 0.30) }
        }
    }

    private func draw(_ image: CGImage, in rect: CGRect, fraction: CGFloat = 1) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver,
            fraction: fraction, respectFlipped: true, hints: nil)
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    override func mouseDown(with event: NSEvent) { if let point = normalized(event) { onClick?(point) } }
    override func mouseMoved(with event: NSEvent) { onHover?(normalized(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { if onClick != nil { addCursorRect(imageRect, cursor: .pointingHand) } }
}

enum SubjectImageUtilities {
    static func selectionOutline(_ mask: CGImage, width: CGFloat) -> CGImage? {
        let source = CIImage(cgImage: mask)
        let alpha = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        // Morphology preserves the image alpha, so derive the contour alpha
        // from its grayscale result rather than tinting that preserved alpha.
        let edge = alpha.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(1, width)])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.22, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.55, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(edge, from: source.extent)
    }

    static func tintedMask(_ mask: CGImage) -> CGImage? {
        let image = CIImage(cgImage: mask).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0.18),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0.90),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0.45),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
    }

    static func trimTransparentMargins(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        pixels.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = storage.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            } }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? image
    }
}
