// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

enum ToolbarPalette {
    static let accent = NSColor(srgbRed: 82 / 255, green: 108 / 255, blue: 131 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 45 / 255, green: 57 / 255, blue: 68 / 255, alpha: 1)
    static let secondaryInk = NSColor(srgbRed: 89 / 255, green: 106 / 255, blue: 121 / 255, alpha: 1)
    static let selectedInk = NSColor(srgbRed: 20 / 255, green: 43 / 255, blue: 63 / 255, alpha: 1)
    static let surface = NSColor.white
    static let border = NSColor(srgbRed: 224 / 255, green: 229 / 255, blue: 233 / 255, alpha: 1)
    static let selectedFill = NSColor(srgbRed: 231 / 255, green: 234 / 255, blue: 238 / 255, alpha: 1)
    static let hoverFill = NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1)
    static let pressedFill = NSColor(srgbRed: 220 / 255, green: 226 / 255, blue: 230 / 255, alpha: 1)
}

/// Original Patch sticker PDFs stay vector through preview and export. Legacy identifiers and emoji still resolve.
enum StickerCatalog {
    struct Item: Decodable {
        let id: String
        let legacyIDs: [String]
        let title: String
        let emoji: String
        let category: String
        let file: String
    }
    private static let directory: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("PatchStickers")) }
        if Bundle.main.bundleURL.pathExtension != "app" {
            candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/PatchStickers"))
            candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/PatchStickers"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
    }()
    static let items: [Item] = {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }()
    static var defaultIdentifier: String { item(for: "🌼")?.id ?? "🌼" }
    static func item(for value: String) -> Item? {
        items.first { $0.id == value || $0.emoji == value || $0.legacyIDs.contains(value) }
    }
    static func canonicalIdentifier(_ value: String) -> String { item(for: value)?.id ?? value }
    private static var documents: [String: CGPDFDocument] = [:]
    static func hasVector(_ value: String) -> Bool { document(for: value) != nil }
    private static func document(for value: String) -> CGPDFDocument? {
        guard let item = item(for: value), let directory else { return nil }
        if let cached = documents[item.id] { return cached }
        guard let document = CGPDFDocument(directory.appendingPathComponent(item.file) as CFURL),
              document.numberOfPages == 1 else { return nil }
        documents[item.id] = document
        return document
    }
    @discardableResult static func draw(_ value: String, in rect: CGRect) -> Bool {
        guard let page = document(for: value)?.page(at: 1), let graphics = NSGraphicsContext.current else { return false }
        let context = graphics.cgContext
        context.saveGState()
        context.translateBy(x: rect.minX, y: graphics.isFlipped ? rect.maxY : rect.minY)
        if graphics.isFlipped { context.scaleBy(x: 1, y: -1) }
        let box = page.getBoxRect(.mediaBox)
        // CGPDFPage's fitting transform does not upscale. Explicit scaling preserves vector detail at every size.
        let scale = min(rect.width / max(1, box.width), rect.height / max(1, box.height))
        context.translateBy(x: (rect.width - box.width * scale) / 2, y: (rect.height - box.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        context.restoreGState()
        return true
    }
}

/// A solid porcelain surface shared by toolbars and their auxiliary panels.
class ToolbarMaterialView: NSView {
    enum Role { case primary, parameter }
    let role: Role
    // Retain the initializer contract for callers that used window blending.
    let blendingMode: NSVisualEffectView.BlendingMode
    var reducesTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    override var isOpaque: Bool { true }

    init(role: Role = .primary, blendingMode: NSVisualEffectView.BlendingMode = .withinWindow) {
        self.role = role
        self.blendingMode = blendingMode
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.cornerRadius = role == .primary ? 7 : 6
        layer?.masksToBounds = true
        refreshMaterial()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarPalette.surface.setFill()
        bounds.fill()
    }

    @objc private func accessibilityChanged(_ notification: Notification) { refreshMaterial() }

    func refreshMaterial() {
        layer?.backgroundColor = ToolbarPalette.surface.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? ToolbarPalette.secondaryInk.withAlphaComponent(0.7).cgColor
            : ToolbarPalette.border.cgColor
        needsDisplay = true
    }
}

/// A passive divider between groups in the same toolbar strip.
final class ToolbarSeparator: NSView {
    override var intrinsicContentSize: NSSize { CGSize(width: 8, height: 28) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ToolbarPalette.border.setFill()
        NSBezierPath(rect: CGRect(x: bounds.midX - 0.5, y: bounds.midY - 9, width: 1, height: 18)).fill()
    }
}

class SelectionButton: NSButton {
    static let annotationSymbol = "pencil.tip"
    static func confirmation(_ title: String = "完成", toolTip: String, action: @escaping () -> Void) -> SelectionButton {
        let button = SelectionButton(title, symbol: "checkmark", action: action)
        button.imagePosition = .imageOnly
        button.isPrimaryAction = true
        button.toolTip = toolTip
        return button
    }

    static func cancellation(toolTip: String, action: @escaping () -> Void) -> SelectionButton {
        let button = SelectionButton("取消", symbol: "xmark", action: action)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        return button
    }

    var isPrimaryAction = false { didSet { updateInteraction() } }
    private var retainsSelection = false
    var actionBlock: (() -> Void)?
    private let glyph = PassiveImageView()
    private let caption = PassiveTextField(labelWithString: "")
    private var hoverTracking: NSTrackingArea?
    private(set) var isPointerInside = false
    private let hoverSurface = CALayer()
    private var hoverWork: DispatchWorkItem?
    private var hoverIsReady = false
    // A dwell avoids motion while scanning; only the glyph scales, never the hit target.
    var allowsMotion: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var usesDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private final class PassiveImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private final class PassiveTextField: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        // Commands must not latch; mode and option controls opt into toggling explicitly.
        setButtonType(.momentaryPushIn)
        self.title = title
        toolTip = title
        setAccessibilityLabel(title)
        bezelStyle = .rounded
        controlSize = .small
        focusRingType = .none
        isBordered = false
        wantsLayer = true
        hoverSurface.backgroundColor = ToolbarPalette.hoverFill.cgColor
        hoverSurface.cornerRadius = 6
        hoverSurface.opacity = 0
        layer?.insertSublayer(hoverSurface, at: 0)
        glyph.wantsLayer = true
        glyph.imageScaling = .scaleProportionallyDown
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.alignment = .center
        addSubview(glyph)
        addSubview(caption)
        imagePosition = symbol == nil ? .noImage : .imageLeading
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = .imageLeading
        }
        actionBlock = action
        target = self
        self.action = #selector(invoke)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    deinit {
        hoverWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc private func accessibilityChanged(_ notification: Notification) { updateInteraction() }
    override var state: NSControl.StateValue {
        didSet { updateInteraction() }
    }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hoverWork?.cancel(); hoverIsReady = false }
            updateInteraction()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setButtonType(_ type: NSButton.ButtonType) {
        super.setButtonType(type)
        retainsSelection = [.pushOnPushOff, .toggle, .switch, .radio, .onOff].contains(type)
    }

    @objc private func invoke() {
        // AppKit advances state even for momentary buttons. Our custom drawing
        // reads that state, so clear it before commands run (including failure paths).
        if !retainsSelection { state = .off }
        actionBlock?()
    }

    override var intrinsicContentSize: NSSize {
        if imagePosition == .imageOnly || title.isEmpty { return CGSize(width: 32, height: 28) }
        let leading: CGFloat = image == nil || imagePosition == .noImage ? 0 : 21
        return CGSize(width: captionSize.width + leading + 12, height: 28)
    }

    private var captionSize: NSSize {
        caption.stringValue = title
        // NSTextField includes text-cell padding that NSString's glyph bounds omit.
        let size = caption.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hoverWork?.cancel(); hoverWork = nil
            isPointerInside = false; hoverIsReady = false
            updateInteraction()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isPointerInside else { return }
        isPointerInside = true
        hoverWork?.cancel()
        guard isEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPointerInside, self.isEnabled else { return }
            self.hoverIsReady = true
            self.updateInteraction()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        resetPointerFeedback()
    }

    func resetPointerFeedback() {
        isPointerInside = false
        hoverWork?.cancel(); hoverWork = nil
        hoverIsReady = false
        super.highlight(false)
        updateInteraction()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateInteraction()
    }

    private func updateInteraction() {
        needsDisplay = true
        let hovered = hoverIsReady && isPointerInside && isEnabled && !isHighlighted
        let opacity: Float = hovered ? 1 : 0
        let oldOpacity = hoverSurface.presentation()?.opacity ?? hoverSurface.opacity
        let opacityChanged = hoverSurface.opacity != opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverSurface.backgroundColor = (state == .on || isPrimaryAction
            ? ToolbarPalette.selectedFill.blended(withFraction: 0.35, of: ToolbarPalette.pressedFill) ?? ToolbarPalette.selectedFill
            : usesDarkAppearance ? NSColor.white.withAlphaComponent(0.09) : ToolbarPalette.hoverFill).cgColor
        hoverSurface.opacity = opacity
        CATransaction.commit()
        if !allowsMotion { hoverSurface.removeAllAnimations() }
        else if opacityChanged {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity; fade.toValue = opacity; fade.duration = hovered ? 0.18 : 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hoverSurface.add(fade, forKey: "hoverFade")
        }
        guard let layer = glyph.layer else { return }
        let animates = allowsMotion && isEnabled && !glyph.isHidden
        let scale: CGFloat = animates ? (isHighlighted ? 0.97 : hovered ? 1.03 : 1) : 1
        let current = layer.presentation()?.transform.m11 ?? layer.transform.m11
        let changed = abs(layer.transform.m11 - scale) > 0.0001
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        if !animates { layer.removeAllAnimations(); return }
        guard changed else { return }
        let transition = CABasicAnimation(keyPath: "transform.scale")
        transition.fromValue = current; transition.toValue = scale
        transition.duration = isHighlighted ? 0.10 : 0.16
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "interactionScale")
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hoverSurface.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.commit()
        updateContent()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        updateInteraction()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSurface()
        updateContent()
    }

    func drawSurface() {
        let selected = state == .on || isPrimaryAction
        let opacity: CGFloat = isEnabled ? 1 : 0.4
        let fill: NSColor
        if isHighlighted && isEnabled {
            fill = usesDarkAppearance && !selected ? NSColor.white.withAlphaComponent(0.12) : ToolbarPalette.pressedFill
        }
        else if selected { fill = ToolbarPalette.selectedFill.withAlphaComponent(opacity) }
        else { fill = .clear }
        fill.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
    }

    private func updateContent() {
        let selected = state == .on || isPrimaryAction
        let ink = selected ? ToolbarPalette.selectedInk : contentTintColor ??
            (usesDarkAppearance ? NSColor.labelColor.withAlphaComponent(0.88) : ToolbarPalette.ink)
        glyph.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: selected ? .semibold : .medium)) ?? image
        glyph.contentTintColor = ink
        glyph.alphaValue = isEnabled ? 1 : 0.36
        glyph.isHidden = image == nil || imagePosition == .noImage
        caption.stringValue = title
        caption.textColor = ink.withAlphaComponent(isEnabled ? 1 : 0.36)
        caption.isHidden = title.isEmpty || imagePosition == .imageOnly
        let glyphSize: CGFloat = 16
        if caption.isHidden {
            glyph.frame = CGRect(x: bounds.midX - glyphSize / 2, y: bounds.midY - glyphSize / 2, width: glyphSize, height: glyphSize)
        } else {
            let textSize = captionSize
            let leading: CGFloat = glyph.isHidden ? 0 : glyphSize + 5
            let x = bounds.midX - (textSize.width + leading) / 2
            glyph.frame = CGRect(x: x, y: bounds.midY - glyphSize / 2, width: glyphSize, height: glyphSize)
            caption.frame = CGRect(x: x + leading, y: bounds.midY - textSize.height / 2,
                                   width: textSize.width, height: textSize.height)
        }
    }
}

/// One continuous size value shared by stepping, dragging and accessibility.
@MainActor
final class AnnotationSizeControl: NSControl {
    private final class DragSlider: NSSlider {
        var begin: (() -> Void)?
        var end: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            begin?(); defer { end?() }
            super.mouseDown(with: event)
        }
    }
    let slider: NSSlider
    let valueLabel = NSTextField(labelWithString: "")
    private(set) var category = ""
    private var step: Double = 1
    private var currentValue: Double = 18
    var onChange: ((Double) -> Void)?
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    lazy var minus = SelectionButton("减小", symbol: "minus") { [weak self] in self?.adjust(-1) }
    lazy var plus = SelectionButton("增大", symbol: "plus") { [weak self] in self?.adjust(1) }
    override var intrinsicContentSize: NSSize { NSSize(width: 218, height: 28) }
    override var isEnabled: Bool { didSet { slider.isEnabled = isEnabled; minus.isEnabled = isEnabled; plus.isEnabled = isEnabled; sync() } }
    override init(frame: NSRect) {
        slider = DragSlider(value: 18, minValue: 8, maxValue: 72, target: nil, action: nil)
        super.init(frame: frame)
        for button in [minus, plus] { button.imagePosition = .imageOnly; addSubview(button) }
        slider.isContinuous = true
        slider.target = self; slider.action = #selector(slide)
        (slider as? DragSlider)?.begin = { [weak self] in self?.onBegin?() }
        (slider as? DragSlider)?.end = { [weak self] in self?.onEnd?() }
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.alignment = .center; valueLabel.textColor = ToolbarPalette.ink
        addSubview(slider); addSubview(valueLabel)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        minus.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        plus.frame = NSRect(x: bounds.width - 28, y: 0, width: 28, height: 28)
        let labelHeight = min(28, max(14, valueLabel.fittingSize.height))
        valueLabel.frame = NSRect(x: bounds.width - 68, y: bounds.midY - labelHeight / 2,
                                  width: 38, height: labelHeight)
        slider.frame = NSRect(x: 30, y: 4, width: max(20, bounds.width - 102), height: 20)
    }
    func configure(category: String, value: Double, range: ClosedRange<Double>, step: Double) {
        self.category = category; self.step = step
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        // Keep older large annotations/preferences intact until explicitly edited.
        // The slider covers common sizes; minus can reduce an older value gradually.
        currentValue = value
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        slider.setAccessibilityLabel(category)
        minus.setAccessibilityLabel(category + ":减小"); plus.setAccessibilityLabel(category + ":增大")
        minus.toolTip = "减小" + category; plus.toolTip = "增大" + category
        sync()
    }
    private func sync() {
        valueLabel.stringValue = currentValue.formatted(.number.precision(.fractionLength(0...1)))
        minus.isEnabled = isEnabled && currentValue > slider.minValue
        plus.isEnabled = isEnabled && currentValue < slider.maxValue
    }
    private func adjust(_ direction: Double) {
        guard isEnabled else { return }
        currentValue = direction < 0 ? max(slider.minValue, currentValue - step)
            : min(slider.maxValue, currentValue + step)
        slider.doubleValue = min(slider.maxValue, max(slider.minValue, currentValue))
        sync(); onChange?(currentValue)
    }
    @objc private func slide() {
        slider.doubleValue = min(slider.maxValue, max(slider.minValue, (slider.doubleValue / step).rounded() * step))
        currentValue = slider.doubleValue
        sync(); onChange?(currentValue)
    }
}

/// Shared screenshot/editor controls. Stored defaults and selected-object values are separate.
@MainActor
final class AnnotationControls {
    let canvas: ImageToolsCanvas
    private let preferences: PreferencesStore
    private let scale: () -> CGFloat
    var onUpdate: (() -> Void)?
    private(set) var activeTool: ImageToolsTool?
    private(set) var toolButtons: [ImageToolsTool: NSButton] = [:]
    let undoButton: NSButton
    private(set) var colorButtons: [NSButton] = []
    private(set) var stickerButtons: [NSButton] = []
    let sizeControl = AnnotationSizeControl(frame: .zero)
    private let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white]
    private let stickers = StickerCatalog.items
    private var defaultSticker = StickerCatalog.defaultIdentifier
    private var stickerPopover: NSPopover?
    private let parameterSeparator = ToolbarSeparator()
    private let actionSeparator = ToolbarSeparator()
    private(set) lazy var moreStickerButton: NSButton = SelectionButton("更多", symbol: "ellipsis") { [weak self] in
        self?.showStickerPicker()
    }

    init(canvas: ImageToolsCanvas, preferences: PreferencesStore? = nil,
         scale: @escaping () -> CGFloat = { 1 }, onUndo: (() -> Void)? = nil) {
        self.canvas = canvas; self.preferences = preferences ?? .shared; self.scale = scale
        undoButton = SelectionButton("撤销", symbol: "arrow.uturn.backward") { [weak canvas] in
            if let onUndo { onUndo() } else { canvas?.undoAnnotation() }
        }
        undoButton.imagePosition = .imageOnly
        undoButton.toolTip = "撤销标注（⌘Z）"
        let symbols: [ImageToolsTool: String] = [.arrow: "arrow.up.right", .rectangle: "rectangle", .ellipse: "circle",
            .text: "textformat", .number: "number.circle", .pen: SelectionButton.annotationSymbol, .mosaic: "square.grid.3x3.fill", .sticker: "leaf"]
        for tool in ImageToolsTool.allCases {
            let button = SelectionButton(tool.rawValue, symbol: symbols[tool]) { [weak self] in self?.choose(tool: tool) }
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageOnly
            button.toolTip = "\(tool.rawValue) · 再点一次结束绘制"
            toolButtons[tool] = button
        }
        for (index, color) in colors.enumerated() {
            let names = ["红色", "黄色", "绿色", "蓝色", "白色"]
            colorButtons.append(SelectionOptionButton(sample: .color(color), label: "标注颜色:\(names[index])") { [weak self] in
                self?.change({ $0.colorID = index }, edit: { $0.updateSelectedAnnotation(color: color) })
            })
        }
        for sticker in stickers {
            stickerButtons.append(SelectionOptionButton(sample: .sticker(sticker.id), label: "贴纸图案:\(sticker.title)") { [weak self] in
                self?.chooseSticker(sticker.id)
            })
        }
        sizeControl.onChange = { [weak self] value in self?.changeSize(value) }
        sizeControl.onBegin = { [weak canvas] in canvas?.beginParameterEditing() }
        sizeControl.onEnd = { [weak canvas] in canvas?.endParameterEditing() }
        canvas.onAnnotationSelectionChange = { [weak self] annotation in
            guard let self else { return }
            if let annotation { self.activeTool = annotation.tool; self.canvas.tool = annotation.tool; self.canvas.isDrawingEnabled = true }
            else { self.applyDefaults() }
            self.refresh(); self.onUpdate?()
        }
        canvas.isDrawingEnabled = false
        refresh()
    }

    var rows: [[NSView]] {
        var rows: [[NSView]] = [ImageToolsTool.allCases.compactMap { toolButtons[$0] } + [undoButton]]
        guard let activeTool else { return rows }
        switch activeTool {
        case .arrow, .rectangle, .ellipse, .pen: rows.append(group("颜色", colorButtons) + [parameterSeparator] + group("粗细", [sizeControl]))
        case .text: rows.append(group("颜色", colorButtons) + [parameterSeparator] + group("字号", [sizeControl]))
        case .number: rows.append(group("颜色", colorButtons) + [parameterSeparator] + group("大小", [sizeControl]))
        case .mosaic: rows.append(group("块大小", [sizeControl]))
        case .sticker:
            rows.append(group("图案", Array(stickerButtons.prefix(10))) + [moreStickerButton, parameterSeparator]
                + group("大小", [sizeControl]))
        }
        return rows
    }

    func rows(appendingActions actions: [NSView]) -> [[NSView]] {
        let controlRows = rows
        let main = (controlRows.first ?? []) + (actions.isEmpty ? [] : [actionSeparator] + actions)
        return [main] + Array(controlRows.dropFirst())
    }

    func choose(tool: ImageToolsTool) {
        canvas.finishTextEditing()
        stickerPopover?.close()
        let next: ImageToolsTool? = activeTool == tool ? nil : tool
        canvas.deselectAnnotation()
        activeTool = next
        canvas.isDrawingEnabled = next != nil
        if let next { canvas.tool = next }
        applyDefaults(); refresh(); onUpdate?()
    }

    func reset() {
        stickerPopover?.close()
        activeTool = nil; canvas.isDrawingEnabled = false
        refresh(); onUpdate?()
    }

    func refresh() {
        undoButton.isEnabled = canvas.canUndo
        for (tool, button) in toolButtons {
            let selected = activeTool == tool
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? ToolbarPalette.selectedInk : nil
            button.needsDisplay = true
        }
        guard let activeTool else { return }
        var value = preferences.annotation(for: activeTool.rawValue)
        if let annotation = canvas.selectedAnnotation {
            value.colorID = colors.firstIndex(where: { $0.isEqual(annotation.color) }) ?? 0
            value.width = Double(annotation.width / scale())
            value.fontSize = Double(annotation.fontSize / scale())
            value.numberSize = Double(annotation.numberSize / scale())
            value.mosaicBlockSize = Double(annotation.mosaicBlockSize / scale())
        }
        for (index, button) in colorButtons.enumerated() {
            button.state = index == value.colorID ? .on : .off; button.needsDisplay = true
        }
        let category: String; let current: Double; let range: ClosedRange<Double>; let step: Double
        switch activeTool {
        case .text: category = "文字大小"; current = value.fontSize; range = 8...72; step = 1
        case .sticker: category = "贴纸大小"; current = value.fontSize; range = 8...96; step = 1
        case .number: category = "序号大小"; current = value.numberSize; range = 8...64; step = 1
        case .mosaic: category = "马赛克大小"; current = value.mosaicBlockSize; range = 1...32; step = 1
        default: category = "标注粗细"; current = value.width; range = 0.5...12; step = 0.5
        }
        sizeControl.configure(category: category, value: current, range: range, step: step)
        let selectedSticker = canvas.selectedAnnotation?.tool == .sticker ? canvas.selectedAnnotation?.text : defaultSticker
        for (index, button) in stickerButtons.enumerated() {
            button.state = stickers[index].id == selectedSticker.map(StickerCatalog.canonicalIdentifier) ? .on : .off
            button.needsDisplay = true
        }
    }

    private func changeSize(_ value: Double) {
        guard let activeTool else { return }
        switch activeTool {
        case .text, .sticker:
            change({ $0.fontSize = value }, edit: { $0.updateSelectedAnnotation(fontSize: CGFloat(value) * self.scale()) })
        case .number:
            change({ $0.numberSize = value }, edit: { $0.updateSelectedAnnotation(numberSize: CGFloat(value) * self.scale()) })
        case .mosaic:
            change({ $0.mosaicBlockSize = value }, edit: { $0.updateSelectedAnnotation(mosaicBlockSize: max(2, CGFloat(value) * self.scale())) })
        default:
            change({ $0.width = value }, edit: { $0.updateSelectedAnnotation(width: CGFloat(value) * self.scale()) })
        }
    }

    private func chooseSticker(_ identifier: String) {
        defaultSticker = StickerCatalog.canonicalIdentifier(identifier)
        canvas.annotationSticker = defaultSticker
        canvas.updateSelectedAnnotation(sticker: defaultSticker)
        stickerPopover?.close()
        refresh(); onUpdate?()
    }

    private func showStickerPicker() {
        guard moreStickerButton.window != nil else { return }
        stickerPopover?.close()
        let selected = canvas.selectedAnnotation?.tool == .sticker ? canvas.selectedAnnotation!.text : defaultSticker
        let controller = StickerPickerController(items: stickers, selected: selected) { [weak self] identifier in
            self?.chooseSticker(identifier)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        stickerPopover = popover
        popover.show(relativeTo: moreStickerButton.bounds, of: moreStickerButton, preferredEdge: .minY)
    }

    private func change(_ change: (inout AnnotationPreference) -> Void, edit: (ImageToolsCanvas) -> Void) {
        guard let activeTool else { return }
        canvas.finishTextEditing()
        var value = preferences.annotation(for: activeTool.rawValue)
        change(&value)
        preferences.setAnnotation(value, for: activeTool.rawValue)
        applyDefaults(); edit(canvas); refresh(); onUpdate?()
    }

    func displayScaleDidChange() {
        applyDefaults()
        refresh()
    }

    private func applyDefaults() {
        guard let activeTool else { return }
        let value = preferences.annotation(for: activeTool.rawValue)
        canvas.annotationColor = colors[value.colorID]
        canvas.annotationWidth = CGFloat(value.width) * scale()
        canvas.annotationFontSize = CGFloat(value.fontSize) * scale()
        canvas.annotationSticker = defaultSticker
        canvas.annotationNumberSize = CGFloat(value.numberSize) * scale()
        canvas.mosaicBlockSize = max(2, CGFloat(value.mosaicBlockSize) * scale())
    }
    private func group(_ title: String, _ buttons: [NSView]) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = ToolbarPalette.secondaryInk
        return [label] + buttons
    }
}

final class SelectionOptionButton: SelectionButton {
    enum Sample {
        case color(NSColor), line(CGFloat), font(CGFloat), number(CGFloat), mosaic(CGFloat), sticker(String)
    }
    private let sample: Sample
    private final class SampleView: NSView {
        weak var owner: SelectionOptionButton?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { owner?.drawSample() }
    }
    private let sampleView = SampleView()

    init(sample: Sample, label: String, action: @escaping () -> Void) {
        self.sample = sample
        super.init("", action: action)
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        setAccessibilityLabel(label)
        toolTip = label.replacingOccurrences(of: ":", with: " · ")
        // Color and sticker samples must composite above the animated hover layer,
        // just like the ordinary button's glyph and caption subviews.
        sampleView.owner = self
        sampleView.wantsLayer = true
        addSubview(sampleView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize {
        switch sample {
        case .color, .sticker: return CGSize(width: 30, height: 28)
        case .font: return CGSize(width: 34, height: 28)
        default: return CGSize(width: 38, height: 28)
        }
    }

    override func layout() {
        super.layout()
        sampleView.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSurface()
        sampleView.needsDisplay = true
    }

    private func drawSample() {
        let selected = state == .on || isPrimaryAction
        let neutral: NSColor = usesDarkAppearance ? .white : ToolbarPalette.ink
        let ink = selected ? ToolbarPalette.selectedInk : usesDarkAppearance ? NSColor.labelColor : ToolbarPalette.ink
        switch sample {
        case .color(let color):
            let box = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
            color.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            neutral.withAlphaComponent(0.15).setStroke()
            let edge = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            edge.lineWidth = 0.75; edge.stroke()
            if selected {
                let check = NSBezierPath()
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.move(to: CGPoint(x: box.minX + 3, y: box.midY))
                check.line(to: CGPoint(x: box.midX - 1, y: box.minY + 4))
                check.line(to: CGPoint(x: box.maxX - 3, y: box.maxY - 4))
                if color.isEqual(NSColor.white) || color.isEqual(NSColor.systemYellow) { NSColor.black.setStroke() }
                else { NSColor.white.setStroke() }
                check.stroke()
            }
        case .line(let width):
            ink.setStroke()
            let line = NSBezierPath()
            line.lineWidth = width
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: 8, y: bounds.midY))
            line.line(to: CGPoint(x: bounds.maxX - 8, y: bounds.midY))
            line.stroke()
        case .font(let size):
            let value = String(Int(size))
            centeredText(value, font: .systemFont(ofSize: min(19, 9 + size / 5), weight: .medium), color: ink)
        case .number(let diameter):
            let radius = min(11, max(4, diameter / 4))
            ink.setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - radius, y: bounds.midY - radius,
                                       width: radius * 2, height: radius * 2)).fill()
            centeredText("1", font: .systemFont(ofSize: radius * 1.3, weight: .bold), color: usesDarkAppearance && !selected ? .black : .white)
        case .mosaic(let block):
            let box = bounds.insetBy(dx: 8, dy: 5)
            let cell = min(9, max(1.5, block / 3))
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).addClip()
            var row = 0
            for y in stride(from: box.minY, to: box.maxY, by: cell) {
                var column = 0
                for x in stride(from: box.minX, to: box.maxX, by: cell) {
                    ink.withAlphaComponent((row + column) % 2 == 0 ? 0.9 : 0.3).setFill()
                    CGRect(x: x, y: y, width: cell, height: cell).fill()
                    column += 1
                }
                row += 1
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        case .sticker(let sticker):
            let rect = CGRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
            if !StickerCatalog.draw(sticker, in: rect) {
                centeredText(StickerCatalog.item(for: sticker)?.emoji ?? sticker,
                             font: NSFont(name: "Apple Color Emoji", size: 20) ?? .systemFont(ofSize: 20), color: .white)
            }
        }
    }

    private func centeredText(_ text: String, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// A compact picker keeps the expanded library out of the persistent toolbar.
final class StickerPickerController: NSViewController {
    private let items: [StickerCatalog.Item]
    private let selected: String
    private let onPick: (String) -> Void
    init(items: [StickerCatalog.Item], selected: String, onPick: @escaping (String) -> Void) {
        self.items = items; self.selected = StickerCatalog.canonicalIdentifier(selected); self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let columns = 6
        let rows = (items.count + columns - 1) / columns
        let size = CGSize(width: 252, height: 48 + CGFloat(rows) * 38)
        let root = ToolbarMaterialView()
        root.frame = CGRect(origin: .zero, size: size)
        let title = NSTextField(labelWithString: "更多贴纸")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = ToolbarPalette.ink
        title.frame = CGRect(x: 14, y: size.height - 30, width: 200, height: 20)
        root.addSubview(title)
        for (index, item) in items.enumerated() {
            let button = SelectionOptionButton(sample: .sticker(item.id), label: "贴纸图案:\(item.title)") { [weak self] in
                self?.onPick(item.id)
            }
            button.toolTip = "\(item.category) · \(item.title)"
            button.state = item.id == selected ? .on : .off
            button.frame = CGRect(x: 12 + CGFloat(index % columns) * 38,
                                  y: size.height - 42 - CGFloat(index / columns + 1) * 38, width: 36, height: 34)
            root.addSubview(button)
        }
        view = root
    }
}

final class SelectionToolbar: NSView {
    var rows: [[NSView]] = []
    /// Reserve the upper-right corner for final actions while other tools wrap below.
    var trailingActions: [NSView] = []
    private var installedItems: [NSView] = []
    private var surfaces: [ToolbarRowSurface] = []
    private var rowRules: [ToolbarRowRule] = []
    private let blendingMode: NSVisualEffectView.BlendingMode

    init(blendingMode: NSVisualEffectView.BlendingMode = .withinWindow) {
        self.blendingMode = blendingMode
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private final class ToolbarRowSurface: ToolbarMaterialView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private final class ToolbarRowRule: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            ToolbarPalette.border.setFill()
            bounds.fill()
        }
    }

    func arrange(maxWidth: CGFloat, maxHeight: CGFloat? = nil) -> CGSize {
        let visible = rows.flatMap { $0 }
        installedItems.filter { child in !visible.contains(where: { $0 === child }) }.forEach { $0.removeFromSuperview() }
        installedItems = visible
        let widthLimit = max(40, maxWidth)
        let horizontalInset: CGFloat = 8
        let itemGap: CGFloat = 2
        var placements: [(NSView, CGRect)] = []
        var rowFrames: [CGRect] = []
        var top: CGFloat = 0
        var widest: CGFloat = 0
        var height: CGFloat = 0
        // Keep normal spacing when it fits. In a short display area, tighten
        // only the row padding and gaps; buttons keep their 28-point hit targets.
        for spacing in [(padding: CGFloat(6), row: CGFloat(4), line: CGFloat(32)),
                        (padding: CGFloat(4), row: CGFloat(2), line: CGFloat(30))] {
            placements.removeAll(keepingCapacity: true)
            rowFrames.removeAll(keepingCapacity: true)
            top = 0; widest = 0
            for row in rows where !row.isEmpty {
                let groupWidth = trailingActions.reduce(CGFloat(0)) { $0 + itemWidth($1, limit: widthLimit) }
                    + CGFloat(max(0, trailingActions.count - 1)) * itemGap
                let pinsActions = !trailingActions.isEmpty && groupWidth <= widthLimit - horizontalInset * 2
                    && trailingActions.allSatisfy({ action in row.contains { $0 === action } })
                let items = pinsActions ? row.filter { item in !trailingActions.contains { $0 === item } } : row
                let naturalWidth = row.reduce(horizontalInset * 2) { $0 + itemWidth($1, limit: widthLimit) }
                    + CGFloat(max(0, row.count - 1)) * itemGap
                let rowLimit = pinsActions ? min(widthLimit, naturalWidth) : widthLimit
                let firstLine = top + spacing.padding
                var x = horizontalInset
                var lineTop = firstLine
                var rowWidth: CGFloat = pinsActions ? rowLimit : 0
                for (index, item) in items.enumerated() {
                    let width = itemWidth(item, limit: widthLimit)
                    let lineLimit = rowLimit - horizontalInset
                        - (pinsActions && lineTop == firstLine ? groupWidth + itemGap : 0)
                    if item is ToolbarSeparator {
                        let nextWidth = items.dropFirst(index + 1).first(where: { !($0 is ToolbarSeparator) })
                            .map { itemWidth($0, limit: widthLimit) }
                        item.isHidden = x == horizontalInset || nextWidth == nil || x + width + itemGap + (nextWidth ?? 0) > lineLimit
                        if item.isHidden { continue }
                    }
                    if x + width > lineLimit, x > horizontalInset || (pinsActions && lineTop == firstLine) {
                        lineTop += spacing.line; x = horizontalInset
                    }
                    placements.append((item, CGRect(x: x, y: lineTop, width: width, height: 28)))
                    x += width + itemGap
                    rowWidth = max(rowWidth, x - itemGap + horizontalInset)
                }
                if pinsActions {
                    var actionX = rowLimit - horizontalInset - groupWidth
                    for action in trailingActions {
                        let width = itemWidth(action, limit: widthLimit)
                        placements.append((action, CGRect(x: actionX, y: firstLine, width: width, height: 28)))
                        actionX += width + itemGap
                    }
                }
                let rowHeight = lineTop + 28 + spacing.padding - top
                rowFrames.append(CGRect(x: 0, y: top, width: min(widthLimit, rowWidth), height: rowHeight))
                widest = max(widest, rowWidth)
                top += rowHeight + spacing.row
            }
            height = max(0, top - spacing.row)
            if let maxHeight, height > maxHeight { continue }
            break
        }
        let size = CGSize(width: min(widthLimit, widest), height: height)
        let trailingIndices = trailingActions.compactMap { action in placements.firstIndex { $0.0 === action } }
        if !trailingIndices.isEmpty, trailingIndices.count == trailingActions.count,
           let last = trailingIndices.last,
           trailingIndices.allSatisfy({ placements[$0].1.minY == placements[last].1.minY }) {
            let shift = max(0, size.width - horizontalInset - placements[last].1.maxX)
            for index in trailingIndices { placements[index].1 = placements[index].1.offsetBy(dx: shift, dy: 0) }
        }
        let surfaceCount = rowFrames.isEmpty ? 0 : 1
        while surfaces.count > surfaceCount { surfaces.removeLast().removeFromSuperview() }
        while surfaces.count < surfaceCount {
            let surface = ToolbarRowSurface(role: .primary, blendingMode: blendingMode)
            surfaces.append(surface)
            addSubview(surface, positioned: .below, relativeTo: nil)
        }
        surfaces.first?.frame = CGRect(origin: .zero, size: size)
        let ruleCount = max(0, rowFrames.count - 1)
        while rowRules.count > ruleCount { rowRules.removeLast().removeFromSuperview() }
        while rowRules.count < ruleCount {
            let rule = ToolbarRowRule()
            rule.identifier = NSUserInterfaceItemIdentifier("toolbar.parameter-rule")
            rowRules.append(rule)
            addSubview(rule)
        }
        for (index, rule) in rowRules.enumerated() {
            let offset = (rowFrames[index].maxY + rowFrames[index + 1].minY) / 2
            rule.frame = CGRect(x: horizontalInset, y: size.height - offset - 0.5, width: max(0, size.width - horizontalInset * 2), height: 1)
        }
        for (item, rect) in placements {
            let height = item is NSTextField ? min(28, max(14, item.fittingSize.height)) : rect.height
            item.frame = CGRect(x: rect.minX, y: size.height - rect.maxY + (rect.height - height) / 2,
                                width: rect.width, height: height)
            if item.superview !== self { addSubview(item) }
        }
        return size
    }

    private func itemWidth(_ item: NSView, limit: CGFloat) -> CGFloat {
        if item is ToolbarSeparator { return 8 }
        return min(limit - 16, max(item is NSTextField ? 22 : 30, item.fittingSize.width))
    }
}
