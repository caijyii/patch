// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import UniformTypeIdentifiers

enum CaptureSelectionPurpose {
    case screenshot, text, scroll, record

    var supportsAnnotations: Bool { self == .screenshot }
    var supportsFullScreen: Bool { self == .screenshot || self == .record }

    var primaryAction: CaptureSelectionAction {
        switch self {
        case .screenshot: return .copy
        case .text: return .ocr
        case .scroll: return .scroll
        case .record: return .record
        }
    }
}

enum CaptureSelectionAction {
    case copy, save, pin, ocr, cutout, scroll, record
}

enum ScreenshotSelectionMode { case rectangle, subject, window, screen }

private struct SelectionCandidate {
    let quartzRect: CGRect
    let pid: pid_t
}

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var views: [SelectionView] = []
    private var callback: ((CaptureSelectionAction, CaptureRegion, CGImage?) -> Void)?
    private var target: NSRunningApplication?
    private var selectionID = UUID()
    private var preparation: Task<Void, Never>?
    private var cursorPushed = false
    private var inputObservers: [NSObjectProtocol] = []

    deinit { inputObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    func select(purpose: CaptureSelectionPurpose, initialMode: ScreenshotSelectionMode = .window,
                targetApplication: NSRunningApplication? = nil,
                capture: @escaping (CaptureRegion) async throws -> CGImage,
                completion: @escaping (CaptureSelectionAction, CaptureRegion, CGImage?) -> Void) {
        cancel()
        target = targetApplication ?? NSWorkspace.shared.frontmostApplication
        callback = completion
        let id = selectionID
        let screens = NSScreen.screens
        let candidates = visibleWindows()
        let primaryTop = screens.first?.frame.maxY ?? 0
        // Freeze before installing overlays. Every preview and image action uses these pixels.
        preparation = Task { [weak self] in
            do {
                var snapshots: [(NSScreen, CGImage)] = []
                for screen in screens {
                    guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
                    let region = CaptureRegion(rect: screen.frame, displayID: display.uint32Value,
                                               screenFrame: screen.frame, scale: screen.backingScaleFactor, targetPID: nil)
                    let image = try await capture(region)
                    guard !Task.isCancelled, self?.selectionID == id else { return }
                    snapshots.append((screen, image))
                }
                guard let self, self.selectionID == id, !snapshots.isEmpty else { return }
                self.preparation = nil
                self.show(snapshots, candidates: candidates, primaryTop: primaryTop,
                          purpose: purpose, initialMode: initialMode)
            } catch {
                guard let self, self.selectionID == id, !Task.isCancelled else { return }
                self.cancel()
                showError(error, title: "截图未完成")
            }
        }
    }

    private func show(_ snapshots: [(NSScreen, CGImage)], candidates: [SelectionCandidate],
                      primaryTop: CGFloat, purpose: CaptureSelectionPurpose,
                      initialMode: ScreenshotSelectionMode = .window) {
        for (screen, image) in snapshots {
            let window = SelectionWindow(covering: screen)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let localCandidates = candidates.compactMap { candidate -> CGRect? in
                SelectionGeometry.windowRect(candidate.quartzRect, primaryTop: primaryTop, screenFrame: screen.frame)
            }
            let toolbarArea = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            let view = SelectionView(image: image, size: screen.frame.size, candidates: localCandidates,
                                     purpose: purpose, initialMode: initialMode, toolbarArea: toolbarArea)
            view.onActivate = { [weak self, weak view] in
                guard let self, let view else { return }
                self.views.filter { $0 !== view }.forEach { $0.deactivate() }
            }
            view.onModeChange = { [weak self, weak view] mode in
                guard let self, let view else { return }
                self.views.forEach { $0.setScreenshotMode(mode, startAnalysis: $0 === view) }
            }
            view.onHasSelection = { [weak self] in self?.views.contains(where: { $0.hasSelection }) ?? false }
            view.onBackgroundDoubleClick = { [weak self] in
                self?.views.first(where: { $0.hasSelection })?.confirmSelection() ?? false
            }
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            configureAction(for: view, displayID: displayID, screenFrame: screen.frame,
                            scale: screen.backingScaleFactor, candidates: candidates, primaryTop: primaryTop)
            view.onCancel = { [weak self] in self?.cancelAndRestoreTarget() }
            view.onShortcut = { [weak self, weak view] event in
                guard let self, let view else { return false }
                return self.routeShortcut(event, from: view)
            }
            view.onError = { [weak self, weak view] error in
                guard let self, let view else { return }
                self.windows.forEach { $0.orderOut(nil) }
                NSApp.activate(ignoringOtherApps: true)
                showError(error)
                self.restoreOverlays(focus: view)
            }
            window.contentView = view
            window.onKeyEquivalent = { [weak self, weak view] event in
                guard let self, let view else { return false }
                return self.routeShortcut(event, from: view)
            }
            windows.append(window)
            views.append(view)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
        let mouse = NSEvent.mouseLocation
        let current = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first
        // A key window alone does not take keyboard input away from the previously active app.
        NSApp.activate(ignoringOtherApps: true)
        current?.makeKey()
        current?.makeFirstResponder(current?.contentView)
        installInputObservers()
        if purpose == .screenshot {
            for view in views {
                view.setScreenshotMode(initialMode, startAnalysis: view.window === current)
            }
        }
        NSCursor.crosshair.push()
        cursorPushed = true
        views.forEach { $0.refreshHover() }
    }

    private func configureAction(for view: SelectionView, displayID: CGDirectDisplayID?, screenFrame: CGRect,
                                 scale: CGFloat, candidates: [SelectionCandidate], primaryTop: CGFloat) {
        view.onAction = { [weak self, weak view] action, rect, image in
            guard let self, let view, let displayID else { return }
            let global = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
            let center = CGPoint(x: global.midX, y: primaryTop - global.midY)
            let pid = candidates.first(where: { $0.quartzRect.contains(center) })?.pid
            if let pid, let application = NSRunningApplication(processIdentifier: pid) { self.target = application }
            let targetPID = ScrollEventRouting.captureTargetPID(windowOwnerPID: pid,
                                                               fallbackApplicationPID: self.target?.processIdentifier)
            let region = CaptureRegion(rect: global, displayID: displayID, screenFrame: screenFrame,
                                       scale: scale, targetPID: targetPID)
            if action == .save, let image { self.save(image, focus: view) }
            else { self.finish(action: action, region: region, image: image) }
        }
    }

    private func visibleWindows() -> [SelectionCandidate] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { item in
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pid > 0, pid != ownPID,
                  let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let dictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.width >= 16, bounds.height >= 16,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return SelectionCandidate(quartzRect: bounds, pid: pid)
        }
    }

    private func routeShortcut(_ event: NSEvent, from source: SelectionView) -> Bool {
        if source.window?.firstResponder is NSTextView { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let completesSelection = [UInt16(36), 76, 51, 117, 53].contains(event.keyCode)
            || (event.modifierFlags.contains(.command) && ["c", "s", "z"].contains(key))
        if completesSelection, let selected = views.first(where: { $0.hasSelection }) {
            return selected.handleShortcut(event)
        }
        return source.handleShortcut(event)
    }

    private func save(_ image: CGImage, focus: SelectionView) {
        let id = selectionID
        windows.forEach { $0.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Patch-\(ImageToolsUI.timestamp()).png"
        guard panel.runModal() == .OK, let url = panel.url else {
            if selectionID == id { restoreOverlays(focus: focus) }
            return
        }
        do {
            try ImageToolsUI.png(image).write(to: url, options: .atomic)
            if selectionID == id { cancelAndRestoreTarget() }
        } catch {
            showError(error, title: "保存未完成")
            if selectionID == id { restoreOverlays(focus: focus) }
        }
    }

    private func restoreOverlays(focus: SelectionView) {
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        focus.window?.makeKey()
        focus.window?.makeFirstResponder(focus)
    }

    func cancel() {
        inputObservers.forEach { NotificationCenter.default.removeObserver($0) }
        inputObservers.removeAll()
        selectionID = UUID()
        preparation?.cancel()
        preparation = nil
        callback = nil
        target = nil
        views.forEach { $0.deactivate() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
    }

    private func installInputObservers() {
        inputObservers.forEach { NotificationCenter.default.removeObserver($0) }
        inputObservers = [NSApplication.didResignActiveNotification, NSApplication.didChangeScreenParametersNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.windows.contains(where: { $0.isVisible }) else { return }
                    // Never leave a frozen overlay showing while another app receives typing,
                    // or when a changed display arrangement leaves part of the desktop uncovered.
                    self.cancel()
                }
            }
        }
    }

    private func cancelAndRestoreTarget() {
        let application = target
        cancel()
        application?.activate(options: [])
    }

    private func finish(action: CaptureSelectionAction, region: CaptureRegion, image: CGImage?) {
        let completion = callback
        let application = target
        cancel()
        let id = selectionID
        application?.activate(options: [])
        // OCR consumes the frozen image; only live-capture workflows need the
        // overlay to leave the compositor before their next step starts.
        let delay = action == .ocr ? 0.0 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.selectionID == id else { return }
            completion?(action, region, image)
        }
    }
}

private final class SelectionWindow: NSWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    convenience init(covering screen: NSScreen) {
        self.init(contentRect: CGRect(origin: .zero, size: screen.frame.size),
                  styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        setFrame(screen.frame, display: false)
        ignoresMouseEvents = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class SelectionChrome: NSView {
    var selection: CGRect?
    var hover: CGRect?
    var imageSize = CGSize.zero
    var primaryTitle = "复制"
    var scrollHint = false
    var fullScreenAvailable = true
    var annotationSelected = false
    var emptyHint: String?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let aperture = selection ?? hover
        let shade = NSBezierPath(rect: bounds)
        if let aperture { shade.append(NSBezierPath(rect: aperture)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill()
        shade.fill()
        if let rect = aperture {
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            (selection == nil ? NSColor.white : ToolbarPalette.accent).setStroke()
            if selection == nil { path.setLineDash([5, 4], count: 2, phase: 0) }
            path.stroke()
            if selection != nil {
                for handle in SelectionHandle.allCases {
                    let point = handle.point(in: rect)
                    let box = NSBezierPath(roundedRect: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                    NSColor.white.setFill(); box.fill()
                    ToolbarPalette.accent.setStroke(); box.stroke()
                }
            }
            let pixels = SelectionGeometry.pixelRect(rect, in: bounds, imageSize: imageSize)
            let text = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
            let y = rect.maxY + 8 < bounds.maxY - 24 ? rect.maxY + 8 : max(8, rect.maxY - 28)
            badge(text, near: CGPoint(x: rect.minX, y: y), font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        }
        let hint: String
        if selection == nil { hint = emptyHint ?? ("单击选窗口 · 拖动框选" + (fullScreenAvailable ? " · F 整屏" : "") + " · Esc 取消") }
        else if annotationSelected { hint = "拖动移动 · 设置区修改 · Delete 删除 · Esc 取消选中" }
        else { hint = "双击空白或 Enter \(primaryTitle) · Esc 取消" }
        let text = scrollHint ? hint + "\n只选择随滚动变化的正文，避开固定顶栏和底栏" : hint
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        badge(text, near: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 28), font: .systemFont(ofSize: 13, weight: .medium))
    }

    private func badge(_ text: String, near point: CGPoint, font: NSFont) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let x = min(max(10, point.x), max(10, bounds.width - size.width - 10))
        let y = min(max(10, point.y), max(10, bounds.height - size.height - 10))
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: CGRect(x: x - 7, y: y - 5, width: size.width + 14, height: size.height + 10), xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }
}

private final class SelectionView: NSView {
    var onActivate: (() -> Void)?
    var onAction: ((CaptureSelectionAction, CGRect, CGImage?) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onShortcut: ((NSEvent) -> Bool)?
    var onHasSelection: (() -> Bool)?
    var onBackgroundDoubleClick: (() -> Bool)?
    var onModeChange: ((ScreenshotSelectionMode) -> Void)?
    var hasSelection: Bool { committedMode == .subject ? !subjects.selected.isEmpty : selection != nil }
    private let rectangleCanvas: ImageToolsCanvas
    private let subjectCanvas: ImageToolsCanvas
    private var canvas: ImageToolsCanvas { committedMode == .subject ? subjectCanvas : rectangleCanvas }
    private let subjects: InlineSubjectSelection
    private let chrome = SelectionChrome()
    private let toolbar = SelectionToolbar()
    private let modeSeparator = ToolbarSeparator()
    private let candidates: [CGRect]
    private let purpose: CaptureSelectionPurpose
    private let toolbarArea: CGRect
    private enum SelectionMode { case automatic, free, window }
    private var selectionMode: SelectionMode = .free
    private var selection: CGRect?
    private var screenshotMode: ScreenshotSelectionMode = .rectangle
    private var committedMode: ScreenshotSelectionMode?
    private var pendingModeChange = false
    private var subjectSelectionTool = true
    private var subjectDragRect: CGRect?
    private var installedSubjectImage: CGImage?
    private var choosingSubjects: Bool { screenshotMode == .subject && (pendingModeChange || subjectSelectionTool) }
    private var hover: CGRect?
    private var rectangleControls: AnnotationControls!
    private var subjectControls: AnnotationControls!
    private var controls: AnnotationControls! { committedMode == .subject ? subjectControls : rectangleControls }
    private var activeTool: ImageToolsTool? {
        get { controls?.activeTool }
        set {
            guard let newValue else { controls?.reset(); return }
            if controls?.activeTool != newValue { controls?.choose(tool: newValue) }
        }
    }
    private var tracking: NSTrackingArea?
    private var toolButtons: [ImageToolsTool: NSButton] { controls.toolButtons }
    private var undoButton: NSButton? { controls?.undoButton }
    private var colorButtons: [NSButton] { controls.colorButtons }
    private var screenButton: NSButton!
    private var freeButton: NSButton!
    private var windowButton: NSButton!
    private var cancelButton: NSButton!
    private var confirmButton: NSButton!
    private var imageActions: [NSView] = []
    private var imageActionButtons: [(CaptureSelectionAction, NSButton)] = []
    private var rectangleButton: NSButton!
    private var subjectButton: NSButton!
    private enum Drag {
        case create(anchor: CGPoint, clickedWindow: CGRect?, preserveSelection: Bool)
        case move(rect: CGRect, anchor: CGPoint)
        case resize(rect: CGRect, handle: SelectionHandle)
    }
    private var drag: Drag?
    private var creatingSelection = false
    private var dragStartingSelection: CGRect?
    private var dragStartingMode: ScreenshotSelectionMode = .window
    private var dragStartingSelectionMode: SelectionMode = .automatic
    private var dragStartingPendingModeChange = false
    private var creationPreview: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(image: CGImage, size: CGSize, candidates: [CGRect], purpose: CaptureSelectionPurpose,
         initialMode: ScreenshotSelectionMode = .window,
         preferences: PreferencesStore? = nil, toolbarArea: CGRect? = nil) {
        rectangleCanvas = ImageToolsCanvas(image: image)
        subjectCanvas = ImageToolsCanvas(image: image)
        subjects = InlineSubjectSelection(image: image, size: size)
        self.candidates = candidates
        self.purpose = purpose
        self.toolbarArea = toolbarArea ?? CGRect(origin: .zero, size: size)
        super.init(frame: CGRect(origin: .zero, size: size))
        if purpose == .text || purpose == .record { selectionMode = .automatic }
        for drawingCanvas in [rectangleCanvas, subjectCanvas] {
            drawingCanvas.frame = bounds
            drawingCanvas.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            drawingCanvas.autoresizingMask = [.width, .height]
            drawingCanvas.wantsLayer = true
        }
        addSubview(rectangleCanvas)
        subjects.isHidden = true
        addSubview(subjects)
        subjectCanvas.isHidden = true
        addSubview(subjectCanvas)
        subjects.feedbackView.frame = bounds
        subjects.feedbackView.autoresizingMask = [.width, .height]
        addSubview(subjects.feedbackView)
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.imageSize = CGSize(width: image.width, height: image.height)
        chrome.primaryTitle = purpose == .screenshot ? "复制" : "确认选区"
        chrome.scrollHint = purpose == .scroll
        chrome.fullScreenAvailable = purpose.supportsFullScreen
        addSubview(chrome)
        addSubview(toolbar)
        rectangleControls = AnnotationControls(canvas: rectangleCanvas, preferences: preferences,
            scale: { [weak self] in self?.imageScale ?? 1 })
        subjectControls = AnnotationControls(canvas: subjectCanvas, preferences: preferences,
            scale: { [weak self] in self?.imageScale ?? 1 },
            onUndo: { [weak self] in self?.undoCurrentAction() })
        for (drawingCanvas, toolControls) in [(rectangleCanvas, rectangleControls!), (subjectCanvas, subjectControls!)] {
            toolControls.onUpdate = { [weak self, weak drawingCanvas] in
                guard let self else { return }
                if drawingCanvas === self.subjectCanvas {
                    self.subjectSelectionTool = self.subjectControls.activeTool == nil
                }
                self.arrangeToolbar(); self.updateButtons(); self.updateSelection()
            }
            drawingCanvas.onChange = { [weak self] in self?.controls.refresh(); self?.updateButtons() }
            drawingCanvas.onCancel = { [weak self] in self?.onCancel?() }
            drawingCanvas.isDrawingEnabled = false
            drawingCanvas.onError = { [weak self] error in self?.onError?(error) }
            drawingCanvas.onBlankDoubleClick = { [weak self, weak drawingCanvas] point in
                guard let self, let drawingCanvas, drawingCanvas === self.canvas,
                      !self.pendingModeChange, !self.choosingSubjects else { return false }
                let local = self.convert(point, from: drawingCanvas)
                if self.committedMode != .subject {
                    guard let selection = self.selection,
                          selection.insetBy(dx: 5, dy: 5).contains(local), self.handle(at: local) == nil else { return false }
                }
                return self.confirmSelection()
            }
        }
        subjects.onChange = { [weak self] in
            guard let self, self.screenshotMode == .subject else { return }
            self.updateSubjectCanvas()
            self.updateSelection()
        }
        buildToolbar()
        if purpose == .screenshot { setScreenshotMode(initialMode, startAnalysis: false) }
        else { updateSelection() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildToolbar() {
        screenButton = SelectionButton("整屏", symbol: "display") { [weak self] in
            guard let self else { return }
            if self.purpose == .screenshot { self.requestMode(.screen) } else { self.selectScreen() }
        }
        screenButton.toolTip = "选取当前显示器的完整画面（F）"
        freeButton = SelectionButton("自由框选", symbol: "crop") { [weak self] in self?.reset(mode: .free) }
        windowButton = SelectionButton("窗口框选", symbol: "macwindow") { [weak self] in
            guard let self else { return }
            if self.purpose == .screenshot { self.requestMode(.window) } else { self.reset(mode: .window) }
        }
        cancelButton = SelectionButton.cancellation(toolTip: "取消（Esc）") { [weak self] in self?.onCancel?() }
        confirmButton = SelectionButton.confirmation("确认", toolTip: "确认选区，进入下一步（Enter / 双击空白）") {
            [weak self] in _ = self?.confirmSelection()
        }
        if purpose == .scroll {
            cancelButton.imagePosition = .imageLeading
            confirmButton.imagePosition = .imageLeading
        }
        guard purpose.supportsAnnotations else { return }
        rectangleButton = SelectionButton("框选", symbol: "rectangle.dashed") { [weak self] in self?.requestMode(.rectangle) }
        rectangleButton.toolTip = "拖动框选截图范围（R）"
        subjectButton = SelectionButton("主体", symbol: "viewfinder") { [weak self] in self?.requestMode(.subject) }
        subjectButton.toolTip = "识别并选择主体 · 点击此处结束标注，继续增减主体或重新框选"
        windowButton.title = "窗口"
        windowButton.setAccessibilityLabel("窗口")
        windowButton.toolTip = "悬停高亮窗口，单击选择或直接拖动框选（W）"
        for button in [rectangleButton!, subjectButton!, windowButton!, screenButton!] {
            button.imagePosition = .noImage
            button.setButtonType(.pushOnPushOff)
        }
        let definitions: [(String, String, CaptureSelectionAction)] = [
            ("完成", "checkmark", .copy), ("保存", "square.and.arrow.down", .save),
            ("贴图", "pin", .pin), ("文字", "text.viewfinder", .ocr)
        ]
        for (title, symbol, action) in definitions {
            let handler: () -> Void = { [weak self] in self?.perform(action) }
            let button = action == .copy
                ? SelectionButton.confirmation(toolTip: "完成截图，复制并关闭（⌘C / Enter）", action: handler)
                : SelectionButton(title, symbol: symbol, action: handler)
            button.imagePosition = .imageOnly
            if action == .save { button.toolTip = "保存 PNG（⌘S）" }
            if action == .pin { button.toolTip = "将选区贴到屏幕" }
            imageActions.append(button)
            imageActionButtons.append((action, button))
        }
    }

    private func requestMode(_ mode: ScreenshotSelectionMode) {
        guard purpose == .screenshot else { return }
        if let onModeChange { onModeChange(mode) }
        else { setScreenshotMode(mode, startAnalysis: true) }
    }

    func setScreenshotMode(_ mode: ScreenshotSelectionMode, startAnalysis: Bool) {
        guard purpose == .screenshot else { return }
        [rectangleButton, subjectButton, windowButton, screenButton].forEach {
            ($0 as? SelectionButton)?.resetPointerFeedback()
        }
        canvas.finishTextEditing()
        controls.reset()
        screenshotMode = mode
        drag = nil; creatingSelection = false; creationPreview = nil; hover = nil; subjectDragRect = nil
        selectionMode = mode == .window ? .automatic : .free
        pendingModeChange = hasSelection && committedMode != mode
        if mode == .subject {
            subjectCanvas.deselectAnnotation()
            subjectSelectionTool = true
        }
        else { subjects.hover(at: nil) }
        if mode == .screen, startAnalysis { selectScreen(); return }
        updateSelection()
        if mode == .subject, startAnalysis { subjects.ensureStarted(); refreshHover() }
    }

    private var imageScale: CGFloat { CGFloat(canvas.source.width) / max(1, bounds.width) }

    private func arrangeToolbar() {
        let selectionActions: [NSView] = purpose.supportsFullScreen
            ? (selection == bounds ? [freeButton, windowButton] : [screenButton]) : []
        if purpose == .screenshot {
            let modes: [NSView] = [rectangleButton, subjectButton, windowButton, screenButton]
            let visibleControls = screenshotMode == .subject ? subjectControls! : rectangleControls!
            let controlRows = visibleControls.rows(appendingActions: Array(imageActions.dropFirst()) + [cancelButton!, imageActions[0]])
            toolbar.rows = [modes + [modeSeparator] + (controlRows.first ?? [])]
                + Array(controlRows.dropFirst())
        } else if selection == nil {
            toolbar.rows = purpose.supportsFullScreen ? [[screenButton, cancelButton]] : []
        } else {
            toolbar.rows = [selectionActions + [cancelButton, confirmButton]]
        }
        toolbar.isHidden = toolbar.rows.isEmpty
        let clipped = toolbarArea.intersection(bounds)
        let available = clipped.isNull || clipped.isEmpty ? bounds : clipped
        let size = toolbar.arrange(maxWidth: min(1120, max(40, available.width - 24)), maxHeight: available.height)
        toolbar.frame = SelectionGeometry.toolbarFrame(selection: selection, size: size, within: available)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    func refreshHover() {
        guard let window, drag == nil else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        refreshHover(at: point)
    }

    private func refreshHover(at point: CGPoint) {
        guard drag == nil else { return }
        if choosingSubjects {
            guard bounds.contains(point) else { subjects.hover(at: nil); return }
            subjects.ensureStarted()
            subjects.hover(at: point)
            return
        }
        guard selection == nil || pendingModeChange else { return }
        hover = selectionMode != .free && bounds.contains(point) ? candidates.first(where: { $0.contains(point) }) : nil
        chrome.hover = hover
        chrome.needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { window?.makeKey() }
        defer { cursorUpdate(with: event) }
        if choosingSubjects {
            if drag == nil {
                subjects.ensureStarted()
                subjects.hover(at: bounds.contains(point) ? point : nil)
            }
            return
        }
        refreshHover(at: point)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if !toolbar.isHidden && toolbar.frame.contains(point) { NSCursor.arrow.set(); return }
        if choosingSubjects {
            (subjects.hovered == nil ? NSCursor.crosshair : NSCursor.pointingHand).set(); return
        }
        if pendingModeChange { NSCursor.crosshair.set(); return }
        if let target = hitTest(convert(point, to: superview)) as? ImageToolsCanvas {
            target.cursorUpdate(with: event)
            return
        }
        if case .move = drag { NSCursor.closedHand.set(); return }
        if let handle = handle(at: point) { cursor(for: handle).set(); return }
        if let selection, selection.contains(point), activeTool == nil { NSCursor.openHand.set(); return }
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        if choosingSubjects { subjects.hover(at: nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // AppKit hitTest takes a point in the receiver's superview coordinates.
        if !toolbar.isHidden, toolbar.frame.contains(local) { return toolbar.hitTest(local) }
        if pendingModeChange || choosingSubjects { return self }
        if committedMode == .subject {
            return subjectCanvas.hitTest(local)
        }
        if let selection, selection.contains(local), handle(at: local) == nil {
            let pixelPoint = convert(local, to: canvas)
            if canvas.annotationContains(pixelPoint) || (activeTool != nil && !nearBorder(local, rect: selection)) {
                return canvas.hitTest(local)
            }
        }
        return self
    }

    override func resetCursorRects() {
        if pendingModeChange {
            addCursorRect(bounds, cursor: .crosshair)
            addCursorRect(toolbar.frame, cursor: .arrow)
            return
        }
        if choosingSubjects {
            addCursorRect(bounds, cursor: subjects.hovered == nil ? .crosshair : .pointingHand)
            addCursorRect(toolbar.frame, cursor: .arrow)
            return
        }
        if committedMode == .subject && !pendingModeChange {
            addCursorRect(bounds, cursor: activeTool == nil ? .arrow : .crosshair)
            addCursorRect(toolbar.frame, cursor: .arrow)
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
        if let selection, activeTool == nil { addCursorRect(selection, cursor: .openHand) }
        if let selection {
            for handle in SelectionHandle.allCases {
                let point = handle.point(in: selection)
                addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14), cursor: cursor(for: handle))
            }
        }
        addCursorRect(toolbar.frame, cursor: .arrow)
    }

    private func cursor(for handle: SelectionHandle) -> NSCursor {
        handle == .top || handle == .bottom ? .resizeUpDown : handle == .left || handle == .right ? .resizeLeftRight : .crosshair
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        guard let selection else { return nil }
        return SelectionHandle.allCases.first {
            let anchor = $0.point(in: selection)
            return abs(point.x - anchor.x) <= 7 && abs(point.y - anchor.y) <= 7
        }
    }

    private func nearBorder(_ point: CGPoint, rect: CGRect) -> Bool {
        rect.insetBy(dx: -5, dy: -5).contains(point) && !rect.insetBy(dx: 5, dy: 5).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        canvas.finishTextEditing()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStartingSelection = selection
        dragStartingMode = screenshotMode
        dragStartingSelectionMode = selectionMode
        dragStartingPendingModeChange = pendingModeChange
        creationPreview = nil
        if choosingSubjects {
            creatingSelection = false
            drag = .create(anchor: point, clickedWindow: nil, preserveSelection: hasSelection)
            return
        }
        let outside = selection.map { !$0.insetBy(dx: -5, dy: -5).contains(point) } ?? true
        if event.clickCount >= 2, !pendingModeChange {
            let blankInside = selection?.insetBy(dx: 5, dy: 5).contains(point) == true
                && handle(at: point) == nil && !canvas.annotationContains(convert(point, to: canvas))
            if outside || blankInside {
                drag = nil
                if outside ? (onBackgroundDoubleClick?() ?? confirmSelection()) : confirmSelection() { return }
            }
        }
        if purpose == .screenshot, screenshotMode == .window, pendingModeChange || selection == nil {
            let preserve = !pendingModeChange && (onHasSelection?() ?? hasSelection)
            drag = .create(anchor: point, clickedWindow: candidates.first(where: { $0.contains(point) }), preserveSelection: preserve)
            creatingSelection = false
            return
        }
        if purpose == .screenshot, screenshotMode == .rectangle, pendingModeChange {
            drag = .create(anchor: point, clickedWindow: nil, preserveSelection: true)
            creatingSelection = false
            return
        }
        creatingSelection = false
        if let rect = selection, let handle = handle(at: point) {
            onActivate?()
            drag = .resize(rect: rect, handle: handle)
        }
        else if let rect = selection, rect.insetBy(dx: -5, dy: -5).contains(point) {
            onActivate?()
            drag = .move(rect: rect, anchor: point)
            NSCursor.closedHand.set()
        } else {
            // A first outside click must preserve the image for a possible second click.
            let clicked = selectionMode != .free ? candidates.first(where: { $0.contains(point) }) : nil
            drag = .create(anchor: point, clickedWindow: clicked,
                           preserveSelection: onHasSelection?() ?? hasSelection)
        }
        updateSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if choosingSubjects {
            guard case .create(let anchor, _, _) = drag,
                  creatingSelection || abs(point.x - anchor.x) >= 4 || abs(point.y - anchor.y) >= 4 else { return }
            if !creatingSelection { creatingSelection = true }
            subjectDragRect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
            subjects.previewRange(subjectDragRect!)
            updateSelection()
            return
        }
        switch drag {
        case .create(let anchor, _, _):
            guard creatingSelection || abs(point.x - anchor.x) >= 4 || abs(point.y - anchor.y) >= 4 else { return }
            if !creatingSelection {
                activeTool = nil
                canvas.isDrawingEnabled = false
                hover = nil
                creatingSelection = true
                if purpose == .screenshot {
                    screenshotMode = .rectangle
                    selectionMode = .free
                    pendingModeChange = true
                }
            }
            creationPreview = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                                     width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        case .move(let rect, let anchor):
            selection = SelectionGeometry.move(rect, by: CGSize(width: point.x - anchor.x, height: point.y - anchor.y), within: bounds)
            if purpose == .screenshot, selection != rect { screenshotMode = .rectangle; committedMode = .rectangle; selectionMode = .free }
        case .resize(let rect, let handle):
            selection = SelectionGeometry.resize(rect, handle: handle, to: point, within: bounds)
            if purpose == .screenshot, selection != rect { screenshotMode = .rectangle; committedMode = .rectangle; selectionMode = .free }
        }
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        guard let operation = drag else { return }
        mouseDragged(with: event)
        if choosingSubjects {
            let point = convert(event.locationInWindow, from: nil)
            if creatingSelection {
                if let rect = subjectDragRect, rect.width >= 16, rect.height >= 16 {
                    subjects.begin(in: rect.integral.intersection(bounds), selectingAll: true)
                }
            } else if subjects.containsSubject(at: point) {
                subjects.toggle(at: point)
            } else { subjects.ensureStarted() }
            drag = nil; creatingSelection = false; subjectDragRect = nil
            subjects.clearRangePreview()
            updateSelection(); refreshHover()
            return
        }
        if case .create(_, let clicked, let preserveSelection) = operation, !creatingSelection, !preserveSelection, let clicked {
            commitRectangle(clicked, mode: purpose == .screenshot ? .window : .rectangle)
        } else if case .create = operation, creatingSelection {
            if let rect = creationPreview, rect.width >= 16, rect.height >= 16 {
                commitRectangle(rect, mode: .rectangle)
            } else {
                selection = dragStartingSelection
                screenshotMode = dragStartingMode
                selectionMode = dragStartingSelectionMode
                pendingModeChange = dragStartingPendingModeChange
            }
        }
        drag = nil
        creatingSelection = false
        creationPreview = nil
        if let rect = selection, rect.width < 16 || rect.height < 16 { selection = dragStartingSelection }
        if let rect = selection { selection = rect.integral.intersection(bounds) }
        updateSelection()
        refreshHover()
    }

    private func chooseTool(_ tool: ImageToolsTool?) {
        guard !pendingModeChange else { return }
        if let tool { controls.choose(tool: tool) } else { controls.reset() }
        window?.makeFirstResponder(self)
    }

    private func reset(mode: SelectionMode = .automatic) {
        if purpose == .screenshot {
            requestMode(mode == .window ? .window : .rectangle)
            refreshHover()
            return
        }
        canvas.clearAnnotations()
        selectionMode = mode
        selection = nil
        activeTool = nil
        canvas.isDrawingEnabled = false
        drag = nil
        creatingSelection = false
        creationPreview = nil
        updateSelection()
        refreshHover()
        window?.makeFirstResponder(self)
    }

    private func selectScreen() {
        guard purpose.supportsFullScreen else { return }
        if purpose == .screenshot { screenshotMode = .screen }
        commitRectangle(bounds, mode: .screen)
        drag = nil; creatingSelection = false; creationPreview = nil
        updateSelection()
        window?.makeFirstResponder(self)
    }

    private func commitRectangle(_ rect: CGRect, mode: ScreenshotSelectionMode) {
        guard rect.width >= 16, rect.height >= 16 else { return }
        onActivate?()
        committedMode = mode
        if purpose == .screenshot {
            screenshotMode = mode
            selectionMode = mode == .window ? .automatic : .free
        }
        pendingModeChange = false
        selection = rect.integral.intersection(bounds)
        rectangleCanvas.clearAnnotations()
        subjectCanvas.clearAnnotations()
        rectangleControls.reset(); subjectControls.reset()
        subjects.deactivate(); installedSubjectImage = nil
        hover = nil
        rectangleCanvas.isDrawingEnabled = false
    }

    private func updateSubjectCanvas() {
        guard subjects.canExport, let image = subjects.selectedImage,
              installedSubjectImage !== image, let rect = subjects.analysisRect else { return }
        let original = rectangleCanvas.source
        guard let context = CGContext(data: nil, width: original.width, height: original.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let pixels = SelectionGeometry.pixelRect(rect, in: bounds, imageSize: chrome.imageSize)
        context.draw(image, in: CGRect(x: pixels.minX, y: CGFloat(original.height) - pixels.maxY,
            width: pixels.width, height: pixels.height))
        guard let source = context.makeImage() else { return }
        do {
            let replacing = committedMode != .subject
            if replacing { subjectCanvas.clearAnnotations() }
            try subjectCanvas.replaceSourcePreservingAnnotations(source)
            installedSubjectImage = image
            if replacing {
                onActivate?()
                rectangleControls.reset(); rectangleCanvas.clearAnnotations()
                committedMode = .subject
                selection = nil
            }
            pendingModeChange = false
        } catch { onError?(error) }
    }

    func deactivate() {
        subjects.deactivate()
        rectangleCanvas.clearAnnotations(); subjectCanvas.clearAnnotations()
        rectangleControls.reset(); subjectControls.reset()
        installedSubjectImage = nil; committedMode = nil; pendingModeChange = false
        selection = nil
        hover = nil
        rectangleCanvas.isDrawingEnabled = false; subjectCanvas.isDrawingEnabled = false
        drag = nil
        creatingSelection = false
        creationPreview = nil
        updateSelection()
    }

    private func updateSelection() {
        let subjectMode = screenshotMode == .subject || (committedMode == .subject && !creatingSelection)
        subjects.isHidden = !subjectMode
        subjects.feedbackView.isHidden = !subjectMode
        rectangleCanvas.isHidden = subjectMode
        subjectCanvas.isHidden = committedMode != .subject || !subjectMode || !subjects.canExport
        chrome.isHidden = subjectMode && screenshotMode != .window
        subjectCanvas.isDrawingEnabled = !pendingModeChange && subjects.canExport
            && !subjectSelectionTool && subjectControls.activeTool != nil
        rectangleCanvas.isDrawingEnabled = !pendingModeChange && rectangleControls.activeTool != nil
        chrome.selection = creationPreview ?? (pendingModeChange && screenshotMode == .window ? nil : selection)
        chrome.hover = selection == nil || pendingModeChange ? hover : nil
        if purpose == .screenshot {
            chrome.emptyHint = screenshotMode == .window ? "悬停识别窗口 · 单击选择 · 拖动框选 · Esc 取消" : "拖动框选范围 · R 框选 · W 窗口 · F 整屏 · Esc 取消"
        } else if purpose == .scroll {
            chrome.emptyHint = selectionMode == .window
                ? "单击选择窗口 · R 返回正文框选 · Esc 取消"
                : "拖动框选正文 · W 窗口框选 · Esc 取消"
        }
        chrome.needsDisplay = true
        rectangleCanvas.interactionBounds = selection.map { SelectionGeometry.pixelRect($0, in: bounds, imageSize: chrome.imageSize) }
        subjectCanvas.interactionBounds = subjectCanvas.bounds
        arrangeToolbar()
        updateButtons()
        window?.invalidateCursorRects(for: self)
    }

    private func updateButtons() {
        if purpose == .screenshot {
            for (mode, button) in [(ScreenshotSelectionMode.rectangle, rectangleButton), (.subject, subjectButton),
                                   (.window, windowButton), (.screen, screenButton)] {
                button?.state = screenshotMode == mode ? .on : .off
                button?.contentTintColor = screenshotMode == mode ? ToolbarPalette.selectedInk : nil
                button?.needsDisplay = true
            }
            let subject = screenshotMode == .subject
            let ready = !pendingModeChange && (committedMode == .subject ? subjects.canExport : selection != nil)
            imageActionButtons.forEach { action, button in
                button.isEnabled = ready && !(subject && action == .ocr)
                if action == .ocr {
                    button.toolTip = subject ? "主体模式暂不支持提取文字，可切换到框选、窗口或整屏。" : "提取当前选区中的文字"
                }
            }
            let visibleControls = subject ? subjectControls! : rectangleControls!
            let canAnnotate = ready
            visibleControls.toolButtons.values.forEach { $0.isEnabled = canAnnotate }
            visibleControls.refresh()
            visibleControls.rows.dropFirst().flatMap { $0 }.compactMap { $0 as? NSControl }
                .forEach { $0.isEnabled = canAnnotate }
            let undoingSubjects = screenshotMode == .subject && subjectSelectionTool
            visibleControls.undoButton.isEnabled = !pendingModeChange
                && (undoingSubjects ? subjects.canUndo : canAnnotate && canvas.canUndo)
            visibleControls.undoButton.toolTip = undoingSubjects ? "撤销主体选择（⌘Z）" : "撤销标注（⌘Z）"
        }
        chrome.annotationSelected = canvas.selectedAnnotation != nil
        chrome.needsDisplay = true
    }

    private func undoCurrentAction() {
        guard !pendingModeChange else { return }
        if committedMode == .subject && subjectSelectionTool { subjects.undo() }
        else { canvas.undoAnnotation() }
    }

    @discardableResult func confirmSelection() -> Bool {
        guard !pendingModeChange else { return false }
        if committedMode == .subject {
            guard subjects.canExport else { return false }
            perform(.copy)
            return true
        }
        guard hasSelection else { return false }
        perform(purpose.primaryAction)
        return true
    }

    private func perform(_ action: CaptureSelectionAction) {
        guard !pendingModeChange else { return }
        guard screenshotMode != .subject || action != .ocr else { return }
        if committedMode == .subject {
            guard [.copy, .save, .pin].contains(action), subjects.canExport,
                  subjects.selectedImage === installedSubjectImage else { return }
            do {
                let image = try subjectCanvas.renderedImage()
                let trimmed = SubjectImageUtilities.trimTransparentMargins(image)
                onAction?(action, subjects.analysisRect ?? bounds, trimmed)
            } catch { onError?(error) }
            return
        }
        guard let selection, selection.width >= 16, selection.height >= 16 else { return }
        guard purpose.supportsAnnotations || action == purpose.primaryAction else { return }
        do {
            canvas.finishTextEditing()
            if action == .record { onAction?(action, selection, nil); return }
            let crop = SelectionGeometry.pixelRect(selection, in: bounds, imageSize: chrome.imageSize)
            let image = try canvas.renderedImage(croppingTo: crop)
            onAction?(action, selection, image)
        } catch { onError?(error) }
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        // Let the inline text field retain standard text editing shortcuts.
        if window?.firstResponder is NSTextView { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            guard purpose.supportsAnnotations else { return false }
            switch key {
            case "c": perform(.copy)
            case "s": perform(.save)
            case "z": undoCurrentAction()
            default: return false
            }
            return true
        }
        if event.modifierFlags.intersection([.control, .option]).isEmpty {
            switch event.keyCode {
            case 53:
                if !canvas.cancelAnnotationEditing() { onCancel?() }
            case 51, 117:
                if pendingModeChange { return true }
                if committedMode == .subject && subjectSelectionTool { subjects.resetSelection() }
                else if purpose.supportsAnnotations { canvas.deleteSelectedAnnotation() }
            case 36, 76: perform(purpose.primaryAction)
            case 3:
                guard purpose.supportsFullScreen else { return false }
                if purpose == .screenshot { requestMode(.screen) } else { selectScreen() }
            case 13: reset(mode: .window)
            case 15, 49: reset(mode: .free)
            default: return false
            }
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if !(onShortcut?(event) ?? handleShortcut(event)) { super.keyDown(with: event) }
    }
}
