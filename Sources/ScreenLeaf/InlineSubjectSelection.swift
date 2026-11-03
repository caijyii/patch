// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// A screenshot-overlay child, never a separate window. All coordinates exposed
/// to its owner are local AppKit points; Vision only sees the frozen image crop.
@MainActor
final class InlineSubjectSelection: NSView {
    var onChange: (() -> Void)?
    private(set) var analysisRect: CGRect?
    private(set) var selected = IndexSet()
    private(set) var hovered: Int?
    private(set) var output: CGImage?
    private(set) var isAnalyzing = false
    private(set) var isRendering = false
    private(set) var isActive = false
    private(set) var status = "切到主体模式后自动识别 · 点击增减主体 · 拖动限定范围"
    var canExport: Bool { isActive && !isAnalyzing && !isRendering && !selected.isEmpty && output != nil }
    var canUndo: Bool { !history.isEmpty && !isAnalyzing }
    var isReady: Bool { extraction != nil && !isAnalyzing }

    private let source: CGImage
    private let worker = DispatchQueue(label: "dev.screenleaf.inline-subject", qos: .userInitiated)
    private var extraction: SubjectExtractionResult?
    private var history: [IndexSet] = []
    private(set) var selectedImage: CGImage?
    private var selectedMask: CGImage?
    private var selectedOutline: CGImage?
    private var hoverMask: CGImage?
    private(set) lazy var feedbackView: NSView = InlineSubjectFeedback(selection: self)
    private var dragRect: CGRect?
    private var lastHover: CGPoint?
    private var session = InlineSubjectWorkToken()
    private var renderWork = InlineSubjectWorkToken()
    private var hoverWork = InlineSubjectWorkToken()
    private struct PreservedResult {
        let extraction: SubjectExtractionResult
        let selected: IndexSet
        let history: [IndexSet]
        let image: CGImage
        let mask: CGImage?
        let outline: CGImage?
        let output: CGImage
        let rect: CGRect
    }
    private var preservedResult: PreservedResult?

    init(image: CGImage, size: CGSize) {
        source = image
        super.init(frame: CGRect(origin: .zero, size: size))
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func ensureStarted() {
        if !isActive { begin(in: bounds, selectingAll: false) }
    }

    func begin(in rect: CGRect, selectingAll: Bool) {
        let rect = rect.intersection(bounds)
        let pixels = SelectionGeometry.pixelRect(rect, in: bounds,
            imageSize: CGSize(width: source.width, height: source.height))
        guard rect.width >= 16, rect.height >= 16,
              let image = source.cropping(to: pixels) else {
            status = "识别范围太小，请重新拖动框选。"
            changed()
            return
        }
        if preservedResult == nil, let extraction, let selectedImage, let output, let analysisRect {
            preservedResult = PreservedResult(extraction: extraction, selected: selected, history: history,
                image: selectedImage, mask: selectedMask, outline: selectedOutline, output: output, rect: analysisRect)
        }
        session.cancel(); renderWork.cancel(); hoverWork.cancel()
        hovered = nil; hoverMask = nil; dragRect = nil
        analysisRect = rect
        isActive = true
        isAnalyzing = true
        status = "正在识别主体… · 可以重新框选或按 Esc 取消"
        let ticket = InlineSubjectWorkToken()
        session = ticket
        changed()
        worker.async { [weak self] in
            guard !ticket.cancelled else { return }
            let result = Result { try SubjectExtraction.analyze(image) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !ticket.cancelled, self.session === ticket else { return }
                self.isAnalyzing = false
                switch result {
                case .success(let extraction):
                    if selectingAll && extraction.instances.isEmpty {
                        self.restorePreservedResult()
                        self.status = "范围内未识别到主体 · 保留原结果 · 可重新拖动范围"
                        self.changed()
                        return
                    }
                    self.extraction = extraction
                    self.selected = selectingAll ? extraction.instances : []
                    if selectingAll { self.renderSelection() }
                    else { self.status = "移动鼠标预览主体 · 点击选中 · 拖动限定识别范围"; self.changed() }
                    self.hover(at: self.lastHover)
                case .failure(let error):
                    self.restorePreservedResult()
                    self.status = error.localizedDescription + " · 可重新框选或切回矩形"
                    self.changed()
                }
            }
        }
    }

    func previewRange(_ rect: CGRect) {
        dragRect = rect.intersection(bounds)
        status = "松开鼠标识别框内主体"
        changed()
    }

    func clearRangePreview() {
        guard dragRect != nil else { return }
        dragRect = nil
        if !isAnalyzing && !isRendering {
            status = selected.isEmpty ? "点击增减主体 · 拖动限定识别范围" : "已选 \(selected.count) 个主体 · 点击增减 · 拖动重新限定范围"
        }
        changed()
    }

    func containsSubject(at point: CGPoint) -> Bool {
        instance(at: point) != nil
    }

    @discardableResult
    func toggle(at point: CGPoint) -> Bool {
        guard let instance = instance(at: point) else { return false }
        history.append(selected)
        if selected.contains(instance) { selected.remove(instance) }
        else { selected.insert(instance) }
        renderSelection()
        return true
    }

    func undo() {
        guard !isAnalyzing, let previous = history.popLast() else { return }
        selected = previous
        renderSelection()
    }

    func resetSelection() {
        guard !selected.isEmpty, !isAnalyzing else { return }
        history.append(selected)
        selected = []
        renderSelection()
    }

    func hover(at point: CGPoint?) {
        lastHover = point
        let next = point.flatMap { instance(at: $0) }
        guard next != hovered else { return }
        hoverWork.cancel()
        hovered = next
        hoverMask = nil
        changed()
        guard let next, let extraction else { return }
        let ticket = InlineSubjectWorkToken(), currentSession = session
        hoverWork = ticket
        worker.async { [weak self] in
            guard !ticket.cancelled, !currentSession.cancelled else { return }
            let mask = try? extraction.maskImage(selecting: IndexSet(integer: next))
            let tinted = mask.flatMap { SubjectImageUtilities.tintedMask($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !ticket.cancelled, !currentSession.cancelled,
                      self.session === currentSession, self.hovered == next else { return }
                self.hoverMask = tinted
                self.changed()
            }
        }
    }

    func deactivate() {
        session.cancel(); renderWork.cancel(); hoverWork.cancel()
        extraction = nil
        selected = []; history = []
        hovered = nil; hoverMask = nil; lastHover = nil
        output = nil; selectedImage = nil; selectedMask = nil; selectedOutline = nil
        analysisRect = nil; dragRect = nil
        preservedResult = nil
        isActive = false; isAnalyzing = false; isRendering = false
        status = "切到主体模式后自动识别 · 点击增减主体 · 拖动限定范围"
        changed()
    }

    private func instance(at point: CGPoint) -> Int? {
        guard let extraction, !isAnalyzing, let rect = analysisRect,
              rect.contains(point), rect.width > 0, rect.height > 0 else { return nil }
        return extraction.instance(atNormalizedTopLeft: CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (rect.maxY - point.y) / rect.height))
    }

    private func renderSelection() {
        renderWork.cancel()
        output = nil; selectedImage = nil; selectedMask = nil; selectedOutline = nil
        guard let extraction else { changed(); return }
        if selected.isEmpty {
            isRendering = false
            status = "尚未选中主体 · 点击画面加入 · 拖动重新限定范围"
            changed()
            return
        }
        isRendering = true
        status = "正在更新透明结果…"
        let selection = selected, currentSession = session, ticket = InlineSubjectWorkToken()
        let outlineWidth = 1.5 * CGFloat(extraction.source.width) / max(1, analysisRect?.width ?? bounds.width)
        renderWork = ticket
        changed()
        worker.async { [weak self] in
            guard !ticket.cancelled, !currentSession.cancelled else { return }
            let result = Result { () -> (CGImage?, CGImage?, CGImage?, CGImage?) in
                let image = try extraction.image(selecting: selection)
                let mask = try extraction.maskImage(selecting: selection)
                return (image, image.map { SubjectImageUtilities.trimTransparentMargins($0) },
                        mask.flatMap { SubjectImageUtilities.tintedMask($0) },
                        mask.flatMap { SubjectImageUtilities.selectionOutline($0, width: outlineWidth) })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !ticket.cancelled, !currentSession.cancelled,
                      self.session === currentSession else { return }
                self.isRendering = false
                switch result {
                case .success(let images):
                    self.selectedImage = images.0
                    self.output = images.1
                    self.selectedMask = images.2
                    self.selectedOutline = images.3
                    if images.1 != nil { self.preservedResult = nil }
                    else { self.restorePreservedResult() }
                    self.status = "已选 \(selection.count) 个主体 · 再点移除 · Enter 复制透明 PNG"
                case .failure(let error):
                    self.restorePreservedResult()
                    self.status = error.localizedDescription
                }
                self.changed()
            }
        }
    }

    private func changed() { needsDisplay = true; feedbackView.needsDisplay = true; onChange?() }

    private func restorePreservedResult() {
        guard let previous = preservedResult else { return }
        extraction = previous.extraction; selected = previous.selected; history = previous.history
        selectedImage = previous.image; selectedMask = previous.mask; output = previous.output
        selectedOutline = previous.outline
        analysisRect = previous.rect; isActive = true; isAnalyzing = false; isRendering = false
        preservedResult = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        draw(source, in: bounds)
        NSColor.black.withAlphaComponent(0.42).setFill()
        NSBezierPath(rect: bounds).fill()
        if let rect = analysisRect, !isAnalyzing && !isRendering {
            if let selectedImage { draw(selectedImage, in: rect) }
        }
    }

    /// Draw above the annotation canvas so its opaque subject pixels cannot hide
    /// selection feedback. This view is never part of the exported image.
    fileprivate func drawFeedback() {
        if let rect = analysisRect, !isAnalyzing && !isRendering {
            if !selected.isEmpty {
                if let selectedMask { draw(selectedMask, in: rect, fraction: 0.10) }
                if let selectedOutline { draw(selectedOutline, in: rect, fraction: 0.95) }
            }
            if let hoverMask { draw(hoverMask, in: rect, fraction: 0.28) }
        }
        if let rect = dragRect ?? analysisRect, rect != bounds {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (status as NSString).size(withAttributes: attributes)
        let width = min(size.width, max(20, bounds.width - 40))
        let rect = CGRect(x: max(12, (bounds.width - width) / 2), y: max(12, bounds.height - 54),
                          width: width, height: 20)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -5), xRadius: 7, yRadius: 7).fill()
        (status as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func draw(_ image: CGImage, in rect: CGRect, fraction: CGFloat = 1) {
        NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver,
            fraction: fraction, respectFlipped: true, hints: nil)
    }
}

@MainActor
private final class InlineSubjectFeedback: NSView {
    private weak var selection: InlineSubjectSelection?
    init(selection: InlineSubjectSelection) {
        self.selection = selection
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { selection?.drawFeedback() }
}

/// Queue cancellation is cooperative; a late Vision completion never changes UI.
private final class InlineSubjectWorkToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
