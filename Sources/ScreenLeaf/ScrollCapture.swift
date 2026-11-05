// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

private struct ScrollCapturePreview {
    let whole: CGImage
    let recent: CGImage
    /// Top-left document coordinates, normalized to the complete assembled image.
    let viewport: CGRect
}

private actor ScrollCaptureProcessor {
    private let stitcher: ScrollStitcher
    private(set) var previewGenerationCount = 0

    init() { stitcher = ScrollStitcher() }

    func append(_ image: CGImage) -> (ScrollStitcher.Update, ScrollCapturePreview?) {
        let update = stitcher.append(image)
        switch update {
        case .started, .appended:
            guard let whole = stitcher.preview(maximumDimension: 500),
                  let recent = thumbnail(image, maximumDimension: 500) else { return (update, nil) }
            previewGenerationCount += 1
            let viewport = CGRect(x: 0, y: CGFloat(stitcher.lastOrigin - stitcher.minOrigin) / CGFloat(stitcher.height),
                                  width: 1, height: CGFloat(image.height) / CGFloat(stitcher.height))
            return (update, ScrollCapturePreview(whole: whole, recent: recent, viewport: viewport))
        default: return (update, nil)
        }
    }

    func image() -> CGImage? { stitcher.image() }

    private func thumbnail(_ image: CGImage, maximumDimension: CGFloat) -> CGImage? {
        let scale = min(1, maximumDimension / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    func fingerprint(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 40 * 40 * 4)
        bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: 40, height: 40,
                                          bitsPerComponent: 8, bytesPerRow: 160,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        return bytes
    }
}

/// Installed throughout an active capture, including pauses. The callback uses the main run loop.
private final class HorizontalScrollLock {
    private static let logger = Logger(subsystem: "dev.screenleaf.app", category: "HorizontalScrollLock")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let region: CGRect
    private let targetPID: pid_t?
    private let targetApplication: NSRunningApplication?
    private var onFailure: ((String) -> Void)?
    private var observations = 0
    private(set) var failureNote: String?

    var isFiltering: Bool {
        guard failureNote == nil, let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    init(region: CaptureRegion) {
        let top = NSScreen.screens.first?.frame.maxY ?? region.screenFrame.maxY
        self.region = CGRect(x: region.rect.minX, y: top - region.rect.maxY,
                             width: region.rect.width, height: region.rect.height)
        targetPID = region.targetPID
        targetApplication = region.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    func install(onFailure: @escaping (String) -> Void) -> String? {
        self.onFailure = onFailure
        guard AXIsProcessTrusted() else {
            return L("控制权限已失效。请完成或取消当前截图，在隐私与安全中允许小贴控制 Mac 后重新开始。")
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask,
                                         callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HorizontalScrollLock>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let explanation = type == .tapDisabledByTimeout
                    ? L("系统因事件处理超时停用了横向锁，已暂停。点击继续可重新启用。")
                    : L("系统停用了横向锁，已暂停。请检查控制权限，再点击继续。")
                owner.failureNote = explanation
                HorizontalScrollLock.logger.error("Horizontal filter disabled: timeout=\(type == .tapDisabledByTimeout, privacy: .public)")
                owner.onFailure?(explanation)
                return Unmanaged.passUnretained(event)
            }
            let inside = owner.region.contains(event.location)
            let targetFrontmost = ScrollEventRouting.isFrontmost(owner.targetApplication)
            if owner.observations < 5 {
                HorizontalScrollLock.logger.notice("Scroll filter scope: inside=\(inside, privacy: .public), targetFrontmost=\(targetFrontmost, privacy: .public), x=\(event.location.x, privacy: .public), y=\(event.location.y, privacy: .public), horizontal=\(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), privacy: .public), raw=\(event.getDoubleValueField(.scrollWheelEventRawDeltaAxis2), privacy: .public)")
                owner.observations += 1
            }
            guard inside, targetFrontmost else { return Unmanaged.passUnretained(event) }
            HorizontalScrollFilter.apply(to: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return L("无法启用横向锁，长截图尚未开始。请检查小贴的控制权限，再点击开始或继续。")
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return L("无法安装横向锁，长截图尚未开始。请点击开始或继续重试。")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            stop()
            return L("系统未启用横向锁，长截图尚未开始。请检查控制权限后重试。")
        }
        Self.logger.notice("Horizontal filter installed: target=\(self.targetPID ?? -1, privacy: .public), x=\(self.region.minX, privacy: .public), y=\(self.region.minY, privacy: .public), width=\(self.region.width, privacy: .public), height=\(self.region.height, privacy: .public)")
        return nil
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        onFailure = nil
    }

    deinit { stop() }
}

private final class ScrollOutlineWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ScrollHUDPanel: NSPanel {
    var isAnnotating = false
    override var canBecomeKey: Bool { isAnnotating }
    override var canBecomeMain: Bool { false }
}

private final class ScrollOutlineView: NSView {
    var selection = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: selection))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.32).setFill()
        shade.fill()
        ToolbarPalette.accent.setStroke()
        let line = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        line.lineWidth = 2
        line.stroke()
    }
}

private final class ScrollHUDContent: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class ScrollPreviewView: NSView {
    var preview: ScrollCapturePreview? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let wholeArea = CGRect(x: 0, y: 0, width: 86, height: max(20, bounds.height - 24))
        let recentArea = CGRect(x: 96, y: 0, width: max(20, bounds.width - 96), height: wholeArea.height)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: ToolbarPalette.secondaryInk]
        ("整张" as NSString).draw(at: CGPoint(x: wholeArea.minX, y: bounds.height - 18), withAttributes: attributes)
        ("最近拼入" as NSString).draw(at: CGPoint(x: recentArea.minX, y: bounds.height - 18), withAttributes: attributes)
        for area in [wholeArea, recentArea] {
            ToolbarPalette.ink.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: area, xRadius: 5, yRadius: 5).fill()
        }
        guard let preview else {
            ("等待首帧" as NSString).draw(at: CGPoint(x: 12, y: bounds.midY - 6), withAttributes: attributes)
            return
        }
        let fitted = draw(preview.whole, in: wholeArea.insetBy(dx: 4, dy: 4))
        let position = CGRect(x: fitted.minX, y: fitted.maxY - preview.viewport.maxY * fitted.height,
                              width: fitted.width, height: preview.viewport.height * fitted.height)
        ToolbarPalette.accent.setStroke()
        let outline = NSBezierPath(rect: position)
        outline.lineWidth = 1
        outline.stroke()
        _ = draw(preview.recent, in: recentArea.insetBy(dx: 4, dy: 4))
    }

    private func draw(_ image: CGImage, in rect: CGRect) -> CGRect {
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let fitted = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        NSImage(cgImage: image, size: size).draw(in: fitted, from: .zero, operation: .sourceOver,
                                               fraction: 1, respectFlipped: true, hints: nil)
        return fitted
    }
}

@MainActor
final class ScrollCaptureCoordinator: NSObject, NSWindowDelegate {
    enum CompletionAction { case copy, annotate }
    private static let logger = Logger(subsystem: "dev.screenleaf.app", category: "ScrollCapture")
    // Recovering keeps sampling without posting events; only a verified overlap resumes stitching.
    private enum State { case preparing, running, recovering, paused, finishing }
    private enum Mode: Equatable {
        case manual, automatic(ScrollStitcher.Direction)
        var isAutomatic: Bool {
            if case .automatic = self { return true }
            return false
        }
        var label: String {
            switch self {
            case .manual: return L("手动 · 可上下滚动")
            case .automatic(.up): return L("自动向上 · 移鼠标暂停")
            case .automatic(.down): return L("自动向下 · 移鼠标暂停")
            }
        }
    }

    private let capture: (CaptureRegion) async throws -> CGImage
    private let onComplete: (CGImage, CompletionAction) throws -> Void
    private var panel: NSPanel?
    private var outline: NSWindow?
    private var inlineEditor: InlineAnnotationView?
    private var hudContent = ScrollHUDContent(frame: .zero)
    private var toolbar = SelectionToolbar(blendingMode: .behindWindow)
    private var detailMaterial = ToolbarMaterialView(role: .parameter, blendingMode: .behindWindow)
    private var detailLabel = NSTextField(wrappingLabelWithString: "")
    private var previewMaterial = ToolbarMaterialView(role: .parameter, blendingMode: .behindWindow)
    private var previewView = ScrollPreviewView(frame: .zero)
    private var previewExpanded = true
    var outputPixelScale: CGFloat? { region?.scale }
    private var region: CaptureRegion?
    private var targetApplication: NSRunningApplication?
    private var processor = ScrollCaptureProcessor()
    private var task: Task<Void, Never>?
    private var scrollLock: HorizontalScrollLock?
    private var session = UUID()
    private var run = UUID()
    private var state: State = .preparing
    private var mode: Mode = .manual
    private var hasFirstFrame = false
    private var duplicateCount = 0
    private var hasPostedAutomaticScroll = false
    private var imageWidth = 0
    private var imageHeight = 0
    private var statusLabel = NSTextField()
    private var dimensionsLabel = NSTextField()
    private var upButton = NSButton()
    private var downButton = NSButton()
    private var pauseButton = NSButton()
    private var previewButton = NSButton()
    private var finishButton = SelectionButton(L("完成"), symbol: "checkmark") {}
    private var annotateButton = NSButton()
    private var cancelButton = NSButton()

    var isActive: Bool { panel != nil }

    init(capture: @escaping (CaptureRegion) async throws -> CGImage,
         onComplete: @escaping (CGImage, CompletionAction) throws -> Void) {
        self.capture = capture
        self.onComplete = onComplete
        super.init()
    }

    func start(region: CaptureRegion, initialFrame: CGImage? = nil) {
        cancel()
        self.region = region
        targetApplication = region.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        processor = ScrollCaptureProcessor()
        mode = .manual
        state = .preparing
        presentHUD(region: region)
        let token = session
        let currentProcessor = processor
        task = Task { [weak self] in
            guard let self else { return }
            if let initialFrame {
                let (update, preview) = await currentProcessor.append(initialFrame)
                guard self.session == token, !Task.isCancelled else { return }
                self.apply(update, width: initialFrame.width, preview: preview)
                guard self.hasFirstFrame else { self.task = nil; return }
            }
            guard self.session == token, !Task.isCancelled else { return }
            self.task = nil
            self.beginCapture()
        }
    }

    func cancel() {
        session = UUID()
        run = UUID()
        task?.cancel()
        task = nil
        scrollLock?.stop()
        scrollLock = nil
        inlineEditor = nil
        panel?.delegate = nil
        panel?.close()
        outline?.close()
        panel = nil
        outline = nil
        region = nil
        targetApplication = nil
        processor = ScrollCaptureProcessor()
        hasFirstFrame = false
        duplicateCount = 0
        hasPostedAutomaticScroll = false
        imageWidth = 0
        imageHeight = 0
        previewView.preview = nil
        previewExpanded = true
        state = .preparing
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func presentHUD(region: CaptureRegion) {
        let border = ScrollOutlineWindow(contentRect: region.screenFrame, styleMask: [.borderless],
                                         backing: .buffered, defer: false)
        border.setFrame(region.screenFrame, display: false)
        border.level = .floating
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.isReleasedWhenClosed = false
        let mask = ScrollOutlineView(frame: CGRect(origin: .zero, size: region.screenFrame.size))
        mask.selection = region.rect.offsetBy(dx: -region.screenFrame.minX, dy: -region.screenFrame.minY)
        border.contentView = mask
        outline = border
        border.orderFrontRegardless()

        let panel = ScrollHUDPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.title = L("Patch · 长截图")
        panel.identifier = NSUserInterfaceItemIdentifier("patch.scroll.hud")
        toolbar = SelectionToolbar(blendingMode: .behindWindow)
        hudContent = ScrollHUDContent(frame: .zero)
        detailMaterial = ToolbarMaterialView(role: .parameter, blendingMode: .behindWindow)
        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = ToolbarPalette.ink
        detailLabel.maximumNumberOfLines = 0
        detailLabel.identifier = NSUserInterfaceItemIdentifier("scroll.status.detail")
        previewMaterial = ToolbarMaterialView(role: .parameter, blendingMode: .behindWindow)
        previewView = ScrollPreviewView(frame: .zero)
        hudContent.addSubview(toolbar)
        hudContent.addSubview(detailMaterial)
        hudContent.addSubview(detailLabel)
        hudContent.addSubview(previewMaterial)
        hudContent.addSubview(previewView)
        panel.contentView = hudContent
        statusLabel = NSTextField(labelWithString: L("正在准备首帧"))
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = ToolbarPalette.ink
        statusLabel.identifier = NSUserInterfaceItemIdentifier("scroll.status")
        dimensionsLabel = NSTextField(labelWithString: L("等待首帧"))
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensionsLabel.textColor = ToolbarPalette.secondaryInk
        upButton = SelectionButton(L("自动上"), symbol: "arrow.up") { [weak self] in self?.selectMode(.automatic(.up)) }
        downButton = SelectionButton(L("自动下"), symbol: "arrow.down") { [weak self] in self?.selectMode(.automatic(.down)) }
        pauseButton = SelectionButton(L("暂停自动"), symbol: "pause.fill") { [weak self] in self?.pauseOrResume() }
        previewButton = SelectionButton(L("预览"), symbol: "photo") { [weak self] in self?.togglePreview() }
        finishButton = SelectionButton.confirmation(toolTip: L("完成长截图，复制并关闭")) { [weak self] in self?.finish(.copy) }
        annotateButton = SelectionButton(L("标注"), symbol: SelectionButton.annotationSymbol) { [weak self] in self?.finish(.annotate) }
        annotateButton.toolTip = L("在当前浮层标注完整长图")
        cancelButton = SelectionButton.cancellation(toolTip: L("取消长截图")) { [weak self] in self?.cancel() }
        toolbar.trailingActions = [cancelButton, finishButton]
        for button in [upButton, downButton, pauseButton, previewButton, finishButton, annotateButton, cancelButton] {
            button.imagePosition = .imageOnly
        }
        upButton.toolTip = L("自动向上滚动并拼接")
        downButton.toolTip = L("自动向下滚动并拼接")
        for button in [upButton, downButton, previewButton] { button.setButtonType(.pushOnPushOff) }
        self.panel = panel
        refreshHUD()
        panel.orderFrontRegardless()
    }

    private func refreshHUD() {
        guard let panel, let region else { return }
        upButton.state = mode == .automatic(.up) ? .on : .off
        downButton.state = mode == .automatic(.down) ? .on : .off
        for button in [upButton, downButton] {
            button.isEnabled = state != .finishing
            button.contentTintColor = button.state == .on ? ToolbarPalette.selectedInk : nil
        }
        pauseButton.title = state == .paused ? L("继续") : L("暂停自动")
        pauseButton.setAccessibilityLabel(pauseButton.title)
        let paused = state == .paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: pauseButton.title)
        // AppKit can reset image positioning when the title/image changes.
        pauseButton.imagePosition = .imageOnly
        pauseButton.toolTip = paused ? L("继续捕获已有选区") : L("停止自动滚动，继续手动捕获")
        pauseButton.isEnabled = (state == .running && mode.isAutomatic) || state == .paused
        previewButton.state = previewExpanded ? .on : .off
        previewButton.toolTip = previewExpanded ? L("收起长图预览") : L("展开长图预览")
        finishButton.isEnabled = hasFirstFrame && state != .finishing
        annotateButton.isEnabled = finishButton.isEnabled
        dimensionsLabel.stringValue = hasFirstFrame ? "\(imageWidth) × \(imageHeight) px" : L("等待首帧")
        var actions: [NSView] = [upButton, downButton]
        if state == .paused || (state == .running && mode.isAutomatic) { actions.append(pauseButton) }
        actions += [previewButton, annotateButton, cancelButton, finishButton]
        toolbar.rows = [actions, [statusLabel, dimensionsLabel]]
        let available = NSScreen.screens.first(where: { $0.frame == region.screenFrame })?.visibleFrame ?? region.screenFrame
        let controlsSize = toolbar.arrange(maxWidth: min(520, max(40, available.width - 24)))
        let width = max(controlsSize.width, min(320, available.width - 24))
        let detailWidth = max(16, width - 24)
        detailLabel.preferredMaxLayoutWidth = detailWidth
        let textHeight = detailLabel.stringValue.isEmpty ? 0 : ceil(detailLabel.cell?.cellSize(forBounds:
            CGRect(x: 0, y: 0, width: detailWidth, height: .greatestFiniteMagnitude)).height ?? 0)
        let detailHeight = textHeight > 0 ? textHeight + 20 : 0
        let size = CGSize(width: width,
                          height: controlsSize.height + detailHeight + (previewExpanded ? 162 : 0))
        guard let frame = hudFrame(size: size, selection: region.rect, within: available) else {
            if previewExpanded { previewExpanded = false; refreshHUD(); return }
            return
        }
        panel.setContentSize(frame.size)
        panel.setFrameOrigin(frame.origin)
        toolbar.frame = CGRect(x: 0, y: frame.height - controlsSize.height, width: frame.width, height: controlsSize.height)
        detailMaterial.isHidden = detailHeight == 0
        detailLabel.isHidden = detailHeight == 0
        let detailBottom = frame.height - controlsSize.height - detailHeight
        detailMaterial.frame = CGRect(x: 0, y: detailBottom, width: frame.width, height: max(0, detailHeight - 4))
        detailLabel.frame = CGRect(x: 12, y: detailBottom + 8, width: detailWidth, height: textHeight)
        previewMaterial.isHidden = !previewExpanded
        previewMaterial.frame = CGRect(x: 0, y: 0, width: frame.width, height: 156)
        previewView.isHidden = !previewExpanded
        previewView.frame = CGRect(x: 12, y: 8, width: max(20, frame.width - 24), height: 140)
    }

    private func hudFrame(size: CGSize, selection: CGRect, within bounds: CGRect) -> CGRect? {
        guard size.width <= bounds.width, size.height <= bounds.height else { return nil }
        let anchor = CGPoint(x: selection.midX, y: selection.midY)
        let preferred = SelectionGeometry.toolbarFrame(selection: selection, size: size, within: bounds)
        if !preferred.contains(anchor) { return preferred }
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX - size.width, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY - size.height),
                       CGPoint(x: bounds.maxX - size.width, y: bounds.maxY - size.height)]
        return corners.map { CGRect(origin: $0, size: size) }.filter { !$0.contains(anchor) }.min {
            hypot($0.minX - preferred.minX, $0.minY - preferred.minY)
                < hypot($1.minX - preferred.minX, $1.minY - preferred.minY)
        }
    }

    private func togglePreview() {
        previewExpanded.toggle()
        refreshHUD()
    }

    private func setStatus(_ summary: String, detail: String? = nil, showsDetail: Bool = false) {
        if statusLabel.stringValue != summary || statusLabel.toolTip != (detail ?? summary) {
            Self.logger.notice("Capture status: \(summary, privacy: .public); detail: \(detail ?? "", privacy: .public)")
        }
        statusLabel.stringValue = summary
        statusLabel.toolTip = detail ?? summary
        statusLabel.setAccessibilityHelp(detail ?? summary)
        detailLabel.stringValue = showsDetail ? (detail ?? "") : ""
        refreshHUD()
    }

    private func selectMode(_ requested: Mode) {
        guard state != .finishing else { return }
        mode = requested
        if state == .preparing { refreshHUD(); return }
        beginCapture()
    }

    private func pauseOrResume() {
        if state == .running, mode.isAutomatic {
            if stopAutomatic() { beginCapture() }
        }
        else if state == .paused { beginCapture() }
    }

    @discardableResult private func stopAutomatic() -> Bool {
        guard state == .running, mode.isAutomatic else { return false }
        run = UUID()
        task?.cancel()
        task = nil
        mode = .manual
        hasPostedAutomaticScroll = false
        duplicateCount = 0
        setStatus(L("自动已暂停 · 可手动滚动"))
        return true
    }

    private func beginCapture() {
        guard state != .finishing, let region else { return }
        run = UUID()
        task?.cancel()
        task = nil
        guard let application = targetApplication, !application.isTerminated else {
            pause(L("原窗口不可用"), detail: L("无法识别选区所在应用。请取消并在原窗口重新框选。"))
            return
        }
        if !ScrollEventRouting.isFrontmost(application), !application.activate(options: []) {
            pause(L("请前置原窗口后继续"))
            return
        }
        guard installScrollLock() else { return }
        hasPostedAutomaticScroll = false
        duplicateCount = 0
        state = .running
        setStatus(mode.label)
        let token = session
        let operation = run
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<20 {
                    if ScrollEventRouting.isFrontmost(application) { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try Task.checkCancellation()
                guard self.isCapturing(token: token, operation: operation) else { return }
                guard ScrollEventRouting.isFrontmost(application) else {
                    self.pause(L("请前置原窗口后继续"))
                    return
                }
                guard self.checkScrollLock() else { return }
                if !self.hasFirstFrame {
                    let first = try await self.capture(region)
                    try Task.checkCancellation()
                    guard self.isCapturing(token: token, operation: operation) else { return }
                    await self.accept(first, token: token, operation: operation)
                }
                while !Task.isCancelled && self.isCapturing(token: token, operation: operation) {
                    guard self.checkScrollLock() else { return }
                    guard ScrollEventRouting.isFrontmost(application) else {
                        self.pause(L("前台已切换 · 已暂停"))
                        return
                    }
                    let requestedMode = self.mode
                    if case .automatic(let direction) = requestedMode {
                        guard self.scroll(region, direction: direction) else { return }
                    }
                    try await Task.sleep(nanoseconds: requestedMode.isAutomatic ? 250_000_000 : 350_000_000)
                    guard let frame = try await self.stableFrame(region: region, automatic: requestedMode.isAutomatic,
                                                                 token: token, operation: operation) else {
                        if requestedMode.isAutomatic {
                            self.waitForOverlap(L("画面未稳定 · 可手动滚动"))
                        }
                        continue
                    }
                    try Task.checkCancellation()
                    guard self.isCapturing(token: token, operation: operation) else { return }
                    await self.accept(frame, token: token, operation: operation)
                }
            } catch is CancellationError {
                // The horizontal lock remains installed while paused.
            } catch {
                guard self.isCapturing(token: token, operation: operation) else { return }
                self.pause(L("截图失败 · 已暂停"), detail: error.localizedDescription)
            }
        }
    }

    private func isCapturing(token: UUID, operation: UUID) -> Bool {
        session == token && run == operation && (state == .running || state == .recovering)
    }

    private func installScrollLock() -> Bool {
        if scrollLock?.isFiltering == true { return true }
        scrollLock?.stop()
        scrollLock = nil
        guard let region else { return false }
        let lock = HorizontalScrollLock(region: region)
        let token = session
        if let explanation = lock.install(onFailure: { [weak self, weak lock] explanation in
            DispatchQueue.main.async { [weak self, weak lock] in
                guard let self, let lock, self.session == token,
                      self.scrollLock === lock, self.state != .finishing else { return }
                self.pause(L("横向锁已停止 · 已暂停"), detail: explanation)
            }
        }) {
            lock.stop()
            pause(L("请授权控制权限后继续"), detail: explanation)
            return false
        }
        scrollLock = lock
        return true
    }

    private func checkScrollLock() -> Bool {
        guard scrollLock?.isFiltering == true else {
            pause(L("横向锁未启用 · 点继续"), detail: scrollLock?.failureNote)
            return false
        }
        return true
    }

    private func stableFrame(region: CaptureRegion, automatic: Bool,
                             token: UUID, operation: UUID) async throws -> CGImage? {
        let attempts = automatic ? 9 : 4
        var lastSample: [UInt8]?
        for _ in 0..<attempts {
            try Task.checkCancellation()
            guard isCapturing(token: token, operation: operation) else { throw CancellationError() }
            guard checkScrollLock() else { throw CancellationError() }
            guard ScrollEventRouting.isFrontmost(targetApplication) else {
                pause(L("前台已切换 · 已暂停"))
                throw CancellationError()
            }
            let frame = try await capture(region)
            try Task.checkCancellation()
            guard isCapturing(token: token, operation: operation) else { throw CancellationError() }
            guard ScrollEventRouting.isFrontmost(targetApplication) else {
                pause(L("前台已切换 · 已暂停"))
                throw CancellationError()
            }
            let sample = await processor.fingerprint(frame)
            if let lastSample {
                var difference = 0
                for index in sample.indices where index % 4 != 3 {
                    difference += abs(Int(sample[index]) - Int(lastSample[index]))
                }
                if Double(difference) / Double(40 * 40 * 3 * 255) < 0.006 { return frame }
            }
            lastSample = sample
            try await Task.sleep(nanoseconds: 140_000_000)
        }
        if !automatic, state != .recovering { setStatus(L("滚动一小段后稍停")) }
        return nil
    }

    private func accept(_ frame: CGImage, token: UUID, operation: UUID) async {
        guard isCapturing(token: token, operation: operation), checkScrollLock() else { return }
        guard ScrollEventRouting.isFrontmost(targetApplication) else {
            pause(L("前台已切换 · 已暂停"))
            return
        }
        let (update, preview) = await processor.append(frame)
        guard isCapturing(token: token, operation: operation) else { return }
        apply(update, width: frame.width, preview: preview)
    }

    private func apply(_ update: ScrollStitcher.Update, width: Int, preview: ScrollCapturePreview? = nil) {
        if let preview { previewView.preview = preview }
        switch update {
        case .started(let height), .appended(_, let height):
            if state == .recovering { state = .running }
            hasFirstFrame = true
            imageWidth = width
            imageHeight = height
            duplicateCount = 0
            setStatus(mode.label)
        case .revisited(let height):
            if state == .recovering { state = .running }
            imageHeight = height
            duplicateCount = 0
            setStatus(L("已覆盖区域 · 可继续"))
        case .duplicate:
            duplicateCount += 1
            if mode.isAutomatic && duplicateCount >= 3 {
                waitForOverlap(L("画面未变化 · 可手动滚动"))
            }
        case .paused(let message):
            waitForOverlap(compactPauseStatus(for: message), detail: localizedStitchingReason(message))
        case .limitReached(let message):
            pause(L("已达截图上限 · 请完成"), detail: localizedStitchingReason(message))
        }
    }

    @discardableResult private func scroll(_ region: CaptureRegion, direction: ScrollStitcher.Direction) -> Bool {
        guard CGPreflightPostEventAccess() else {
            Self.logger.error("Automatic scroll blocked: event posting permission denied")
            pause(L("控制权限已失效 · 请检查设置"), detail: L("请完成或取消当前截图后检查控制权限。若设置已开启，请退出并重新打开小贴后重试。"))
            return false
        }
        guard let pid = region.targetPID, ScrollEventRouting.isFrontmost(targetApplication) else {
            pause(L("前台已切换 · 已暂停"))
            return false
        }
        let point = region.eventPoint
        let appKitPoint = CGPoint(x: region.rect.midX, y: region.rect.midY)
        let hitWindow = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let hitOwner = ScrollEventRouting.owner(ofWindow: hitWindow, windows: windows)
        guard hitOwner == pid else {
            Self.logger.notice("Automatic scroll blocked: target=\(pid, privacy: .public), hitOwner=\(hitOwner ?? -1, privacy: .public), window=\(hitWindow, privacy: .public), x=\(point.x, privacy: .public), y=\(point.y, privacy: .public)")
            pause(L("选区被遮挡 · 已暂停"), detail: L("请移开遮挡窗口并恢复原位置后继续。"))
            return false
        }
        if hasPostedAutomaticScroll {
            guard let current = CGEvent(source: nil)?.location else {
                pause(L("无法确认鼠标位置"))
                return false
            }
            if ScrollEventRouting.mouseMovedFromAnchor(current: current, anchor: point) {
                if stopAutomatic() { beginCapture() }
                return false
            }
        }
        let distance = Int32(max(40, min(320, region.rect.height * 0.30)))
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .combinedSessionState),
                                  units: .pixel, wheelCount: 2,
                                  wheel1: direction == .up ? distance : -distance,
                                  wheel2: 0, wheel3: 0) else {
            pause(L("无法自动滚动 · 可手动"))
            return false
        }
        event.location = point
        HorizontalScrollFilter.apply(to: event)
        event.post(tap: .cghidEventTap)
        if !hasPostedAutomaticScroll {
            Self.logger.notice("Automatic scroll posted through HID: target=\(pid, privacy: .public), window=\(hitWindow, privacy: .public), x=\(point.x, privacy: .public), y=\(point.y, privacy: .public), vertical=\(distance, privacy: .public)")
            hasPostedAutomaticScroll = true
        }
        return true
    }

    private func pause(_ message: String, detail: String? = nil) {
        run = UUID()
        task?.cancel()
        task = nil
        state = .paused
        setStatus(message, detail: detail)
    }

    private func compactPauseStatus(for reason: String) -> String {
        let hints = [
            ("无法读取", L("读帧失败，重试")),
            ("尺寸发生变化", L("区域变化，重新框选")),
            ("区域太矮", L("区域太矮，重新框选")),
            ("缺少可识别", L("细节不足，缓慢滚动")),
            ("左右偏移", L("左右偏移，回正重试")),
            ("重复度较高", L("画面重复，少量滚动")),
            ("不一致", L("内容变化，回滚重试"))
        ]
        guard let hint = hints.first(where: { reason.contains($0.0) })?.1 else {
            return L("拼接暂停，请回滚重试")
        }
        return L("拼接暂停 · ") + hint
    }

    private func localizedStitchingReason(_ reason: String) -> String {
        // Stitching reasons remain stable for matching; only the displayed detail is localized.
        let prefix = "检测到约 "
        let suffix = " 像素的左右偏移。请回到上一段位置并回正，或完成已有结果后重新截图。"
        if reason.hasPrefix(prefix), reason.hasSuffix(suffix),
           let pixels = Int(reason.dropFirst(prefix.count).dropLast(suffix.count)) {
            return LF("检测到约 %d 像素的左右偏移。请回到上一段位置并回正，或完成已有结果后重新截图。", pixels)
        }
        return L(reason)
    }

    private func waitForOverlap(_ message: String, detail: String? = nil) {
        // Keep this run and its last accepted frame. Rejected pixels never replace the anchor.
        // Stop automatic input until the user explicitly selects an automatic direction again.
        state = .recovering
        mode = .manual
        hasPostedAutomaticScroll = false
        duplicateCount = 0
        let guidance = L("已有长图已保留。小幅回滚并稍停即可尝试接续，也可点自动上／下重试，或完成已有结果。")
        setStatus(message, detail: detail.map { $0 + "\n" + guidance } ?? guidance, showsDetail: false)
    }

    private func presentAnnotation(_ image: CGImage) {
        guard let panel = panel as? ScrollHUDPanel, let region else { return }
        WindowActivationCoordinator.shared.register(panel)
        let editor = InlineAnnotationView(image: image, pixelScale: region.scale, completionHint: L("完成长截图，复制并关闭"),
                                          showsCopyAction: false, allowsOutsideAnnotations: true, cancellationHint: L("取消长截图并关闭"))
        inlineEditor = editor
        let token = session
        editor.onComplete = { [weak self] rendered in
            guard let self, self.session == token else { return }
            try self.onComplete(rendered, .copy)
            self.cancel()
        }
        editor.onCancel = { [weak self] in
            guard let self, self.session == token else { return }
            self.cancel()
        }
        panel.isAnnotating = true
        panel.hasShadow = true
        // Reuse the current floating panel on the capture's display.
        let visible = NSScreen.screens.first { $0.frame == region.screenFrame }?.visibleFrame ?? region.screenFrame
        let available = visible.insetBy(dx: 24, dy: 24)
        let size = editor.preferredWindowSize(maximum: available.size)
        let frame = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        editor.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = editor
        outline?.orderOut(nil)
        editor.fitImage()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(editor.canvas)
    }

    private func finish(_ action: CompletionAction) {
        guard hasFirstFrame, state != .finishing else { return }
        run = UUID()
        task?.cancel()
        task = nil
        scrollLock?.stop()
        scrollLock = nil
        state = .finishing
        setStatus(L("正在生成长截图"))
        let token = session
        let currentProcessor = processor
        task = Task { [weak self] in
            let image = await currentProcessor.image()
            guard let self, self.session == token, !Task.isCancelled else { return }
            self.task = nil
            do {
                guard let image else { throw ScreenLeafError(message: L("无法生成长截图，请重试。")) }
                // Keep the assembled image available until copying or handing it to the editor succeeds.
                if action == .annotate {
                    self.presentAnnotation(image)
                } else {
                    try self.onComplete(image, action)
                    guard self.session == token else { return }
                    self.cancel()
                }
            } catch {
                guard self.session == token else { return }
                self.state = .paused
                self.mode = .manual
                self.setStatus(action == .copy ? L("复制失败 · 可重试") : L("打开标注失败 · 可重试"),
                               detail: error.localizedDescription + L("\n已有长图已保留，可重试或选择另一种完成方式。"))
            }
        }
    }
}
