// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Logical-point sizes. A 1× display uses larger native artwork, never a
/// magnified bitmap of the compact toolbar.
struct ToolbarMetrics: Equatable {
    let buttonWidth: CGFloat
    let buttonHeight: CGFloat
    let symbolSize: CGFloat
    let glyphSize: CGFloat
    let captionSize: CGFloat
    let parameterSize: CGFloat
    static let compact = ToolbarMetrics(buttonWidth: 32, buttonHeight: 28,
        symbolSize: 13, glyphSize: 16, captionSize: 12, parameterSize: 11)
    static let comfortable = ToolbarMetrics(buttonWidth: 40, buttonHeight: 36,
        symbolSize: 17, glyphSize: 20, captionSize: 13, parameterSize: 12)
    static func forBackingScaleFactor(_ factor: CGFloat) -> ToolbarMetrics {
        factor.isFinite && factor > 0 && factor < 1.5 ? .comfortable : .compact
    }
    @MainActor func apply(to items: [NSView]) {
        for item in items {
            if let button = item as? SelectionButton { button.toolbarMetrics = self }
            else if let size = item as? AnnotationSizeControl { size.toolbarMetrics = self }
            else if let separator = item as? ToolbarSeparator { separator.toolbarMetrics = self }
        }
    }
}

enum ToolbarPalette {
    static let accent = AppTheme.color(NSColor(srgbRed: 82 / 255, green: 108 / 255, blue: 131 / 255, alpha: 1), NSColor(srgbRed: 0.55, green: 0.72, blue: 0.87, alpha: 1))
    static let ink = AppTheme.color(NSColor(srgbRed: 45 / 255, green: 57 / 255, blue: 68 / 255, alpha: 1), NSColor(srgbRed: 0.88, green: 0.91, blue: 0.94, alpha: 1))
    static let secondaryInk = AppTheme.color(NSColor(srgbRed: 89 / 255, green: 106 / 255, blue: 121 / 255, alpha: 1), NSColor(srgbRed: 0.69, green: 0.75, blue: 0.81, alpha: 1))
    static let selectedInk = AppTheme.color(NSColor(srgbRed: 20 / 255, green: 43 / 255, blue: 63 / 255, alpha: 1), NSColor(srgbRed: 0.93, green: 0.97, blue: 1, alpha: 1))
    static let surface = AppTheme.color(NSColor.white, NSColor(srgbRed: 0.14, green: 0.16, blue: 0.18, alpha: 1))
    static let border = AppTheme.color(NSColor(srgbRed: 224 / 255, green: 229 / 255, blue: 233 / 255, alpha: 1), NSColor(srgbRed: 0.32, green: 0.36, blue: 0.40, alpha: 1))
    static let selectedFill = AppTheme.color(NSColor(srgbRed: 231 / 255, green: 234 / 255, blue: 238 / 255, alpha: 1), NSColor(srgbRed: 0.27, green: 0.38, blue: 0.48, alpha: 1))
    static let hoverFill = AppTheme.color(NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 248 / 255, alpha: 1), NSColor(srgbRed: 0.23, green: 0.27, blue: 0.31, alpha: 1))
    static let pressedFill = AppTheme.color(NSColor(srgbRed: 220 / 255, green: 226 / 255, blue: 230 / 255, alpha: 1), NSColor(srgbRed: 0.33, green: 0.43, blue: 0.52, alpha: 1))
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
        let retired: Bool?
        var groupRank: Int {
            if category == "动物" { return 0 }
            if category == "表情" { return 1 }
            if ["patch-sun", "patch-rainbow"].contains(id) { return 2 }
            if category == "树木" { return 3 }
            if ["patch-seedling", "patch-leaf-fluttering-in-wind", "patch-four-leaf-clover", "patch-maple-leaf", "patch-cactus", "patch-herb"].contains(id) { return 4 }
            if ["patch-blossom", "patch-tulip", "patch-sunflower", "patch-cherry-blossom"].contains(id) { return 5 }
            return 6
        }
        var groupTitle: String { ["动物", "表情", "天气", "树木", "草叶", "花朵", "其他"][groupRank] }
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
    private static let allItems: [Item] = {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }()
    static let items: [Item] = {
        allItems.filter { $0.retired != true }.enumerated().sorted {
            $0.element.groupRank == $1.element.groupRank ? $0.offset < $1.offset : $0.element.groupRank < $1.element.groupRank
        }.map(\.element)
    }()
    static var defaultIdentifier: String { item(for: "🌼")?.id ?? "🌼" }
    static func item(for value: String) -> Item? {
        allItems.first { $0.id == value || $0.emoji == value || $0.legacyIDs.contains(value) }
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); refreshMaterial()
    }

    func refreshMaterial() {
        effectiveAppearance.performAsCurrentDrawingAppearance { updateMaterialColors() }
    }

    private func updateMaterialColors() {
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
    var toolbarMetrics = ToolbarMetrics.compact { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize { CGSize(width: 8, height: toolbarMetrics.buttonHeight) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ToolbarPalette.border.setFill()
        NSBezierPath(rect: CGRect(x: bounds.midX - 0.5, y: bounds.midY - 9, width: 1, height: 18)).fill()
    }
}

class SelectionButton: NSButton {
    static let annotationSymbol = "pencil.tip"
    /// A template T has the same shape in every app/system language. SF textformat localizes its artwork.
    static var textAnnotationImage: NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: 2, y: 11.5, width: 12, height: 2), xRadius: 0.6, yRadius: 0.6).fill()
            NSBezierPath(roundedRect: CGRect(x: 7, y: 2.5, width: 2, height: 10), xRadius: 0.6, yRadius: 0.6).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    static func confirmation(_ title: String = L("完成"), toolTip: String, action: @escaping () -> Void) -> SelectionButton {
        let button = SelectionButton(title, symbol: "checkmark", action: action)
        button.imagePosition = .imageOnly
        button.isPrimaryAction = true
        button.toolTip = toolTip
        return button
    }

    static func cancellation(toolTip: String, action: @escaping () -> Void) -> SelectionButton {
        let button = SelectionButton(L("取消"), symbol: "xmark", action: action)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        return button
    }

    var isPrimaryAction = false { didSet { updateInteraction() } }
    var toolbarMetrics = ToolbarMetrics.compact {
        didSet {
            guard toolbarMetrics != oldValue else { return }
            caption.font = .systemFont(ofSize: toolbarMetrics.captionSize, weight: .medium)
            invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true
        }
    }
    private var retainsSelection = false
    var actionBlock: (() -> Void)?
    private let glyph = PassiveImageView()
    private let caption = PassiveTextField(labelWithString: "")
    private var hoverTracking: NSTrackingArea?
    private(set) var isPointerInside = false
    private let hoverSurface = CALayer()
    private var hoverWork: DispatchWorkItem?
    private var hoverIsReady = false
    // A dwell avoids flashing while scanning; hit targets and glyph geometry stay stable.
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
        self.title = L(title)
        toolTip = L(title)
        setAccessibilityLabel(L(title))
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
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: L(title))
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
        if imagePosition == .imageOnly || title.isEmpty { return CGSize(width: toolbarMetrics.buttonWidth, height: toolbarMetrics.buttonHeight) }
        let leading: CGFloat = image == nil || imagePosition == .noImage ? 0 : toolbarMetrics.glyphSize + 5
        return CGSize(width: max(toolbarMetrics.buttonWidth, captionSize.width + leading + 12), height: toolbarMetrics.buttonHeight)
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
        needsLayout = true
        if window == nil {
            hoverWork?.cancel(); hoverWork = nil
            isPointerInside = false; hoverIsReady = false
            updateInteraction()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true; needsDisplay = true
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
        effectiveAppearance.performAsCurrentDrawingAppearance { updateInteractionColors() }
    }

    private func updateInteractionColors() {
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
        // Keep small symbol strokes on the native pixel grid. Hover still fades
        // its surface, but does not resample the icon at a fractional scale.
        guard let layer = glyph.layer else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.removeAnimation(forKey: "interactionScale")
        CATransaction.commit()
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
        if state == .mixed {
            (usesDarkAppearance ? NSColor.labelColor : ToolbarPalette.ink).withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: CGRect(x: bounds.midX - 4, y: bounds.minY + 3, width: 8, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    private func updateContent() {
        let selected = state == .on || isPrimaryAction
        let ink = selected ? ToolbarPalette.selectedInk : contentTintColor ??
            (usesDarkAppearance ? NSColor.labelColor.withAlphaComponent(0.88) : ToolbarPalette.ink)
        glyph.image = image?.withSymbolConfiguration(.init(pointSize: toolbarMetrics.symbolSize, weight: selected ? .semibold : .medium)) ?? image
        glyph.contentTintColor = ink
        glyph.alphaValue = isEnabled ? 1 : 0.36
        glyph.isHidden = image == nil || imagePosition == .noImage
        caption.stringValue = title
        caption.textColor = ink.withAlphaComponent(isEnabled ? 1 : 0.36)
        caption.isHidden = title.isEmpty || imagePosition == .imageOnly
        let glyphSize = toolbarMetrics.glyphSize
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
        if window != nil {
            glyph.frame = backingAlignedRect(glyph.frame, options: .alignAllEdgesNearest)
            caption.frame = backingAlignedRect(caption.frame, options: .alignAllEdgesNearest)
        }
    }
}

/// One continuous size value shared by stepping, dragging and accessibility.
@MainActor
final class AnnotationSizeControl: NSControl {
    var toolbarMetrics = ToolbarMetrics.compact {
        didSet {
            guard toolbarMetrics != oldValue else { return }
            minus.toolbarMetrics = toolbarMetrics; plus.toolbarMetrics = toolbarMetrics
            valueLabel.font = .monospacedDigitSystemFont(ofSize: toolbarMetrics.parameterSize, weight: .medium)
            invalidateIntrinsicContentSize(); needsLayout = true
        }
    }
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
    lazy var minus = SelectionButton(L("减小"), symbol: "minus") { [weak self] in self?.adjust(-1) }
    lazy var plus = SelectionButton(L("增大"), symbol: "plus") { [weak self] in self?.adjust(1) }
    private var stepButtonWidth: CGFloat { toolbarMetrics == .compact ? 28 : toolbarMetrics.buttonWidth }
    override var intrinsicContentSize: NSSize { NSSize(width: 218 + (stepButtonWidth - 28) * 2, height: toolbarMetrics.buttonHeight) }
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
        let buttonWidth = stepButtonWidth, height = toolbarMetrics.buttonHeight
        minus.frame = NSRect(x: 0, y: 0, width: buttonWidth, height: height)
        plus.frame = NSRect(x: bounds.width - buttonWidth, y: 0, width: buttonWidth, height: height)
        let labelHeight = min(height, max(14, valueLabel.fittingSize.height))
        valueLabel.frame = NSRect(x: bounds.width - buttonWidth - 40, y: bounds.midY - labelHeight / 2,
                                  width: 38, height: labelHeight)
        slider.frame = NSRect(x: buttonWidth + 2, y: bounds.midY - 10,
                             width: max(20, bounds.width - buttonWidth * 2 - 46), height: 20)
    }
    func configure(category: String, value: Double, range: ClosedRange<Double>, step: Double) {
        self.category = category; self.step = step
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        // Keep older large annotations/preferences intact until explicitly edited.
        // The slider covers common sizes; minus can reduce an older value gradually.
        currentValue = value
        slider.doubleValue = min(range.upperBound, max(range.lowerBound, value))
        slider.setAccessibilityLabel(category)
        minus.setAccessibilityLabel(LF("减小%@", category)); plus.setAccessibilityLabel(LF("增大%@", category))
        minus.toolTip = LF("减小%@", category); plus.toolTip = LF("增大%@", category)
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
    private var toolbarMetrics = ToolbarMetrics.compact
    func configureToolbar(forBackingScaleFactor factor: CGFloat) {
        toolbarMetrics = .forBackingScaleFactor(factor)
        toolbarMetrics.apply(to: Array(toolButtons.values) + colorButtons + stickerButtons
            + [undoButton, moreStickerButton, sizeControl, parameterSeparator, actionSeparator])
    }
    static let displayOrder: [ImageToolsTool] = [.arrow, .pen, .rectangle, .ellipse, .text, .number, .sticker, .mosaic]
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
    private var stickers: [StickerCatalog.Item] = []
    var orderedStickerIdentifiers: [String] { stickers.map(\.id) }
    private var defaultSticker = StickerCatalog.defaultIdentifier
    private var stickerPopover: NSPopover?
    private weak var stickerPicker: StickerPickerController?
    private var stickerOrderObserver: NSObjectProtocol?
    private let parameterSeparator = ToolbarSeparator()
    private let actionSeparator = ToolbarSeparator()
    private(set) lazy var moreStickerButton: NSButton = SelectionButton(L("更多"), symbol: "ellipsis") { [weak self] in
        self?.showStickerPicker()
    }

    init(canvas: ImageToolsCanvas, preferences: PreferencesStore? = nil,
         scale: @escaping () -> CGFloat = { 1 }, onUndo: (() -> Void)? = nil) {
        self.canvas = canvas; self.preferences = preferences ?? .shared; self.scale = scale
        undoButton = SelectionButton(L("撤销"), symbol: "arrow.uturn.backward") { [weak canvas] in
            if let onUndo { onUndo() } else { canvas?.undoAnnotation() }
        }
        undoButton.imagePosition = .imageOnly
        undoButton.toolTip = L("撤销标注（⌘Z）")
        let symbols: [ImageToolsTool: String] = [.arrow: "arrow.up.right", .rectangle: "rectangle", .ellipse: "circle",
            .number: "number.circle", .pen: SelectionButton.annotationSymbol, .mosaic: "square.grid.3x3.fill", .sticker: "leaf"]
        for tool in Self.displayOrder {
            let button = SelectionButton(tool.rawValue, symbol: symbols[tool]) { [weak self] in self?.choose(tool: tool) }
            if tool == .text { button.image = SelectionButton.textAnnotationImage }
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageOnly
            button.toolTip = LF("%@ · 再点一次结束绘制", L(tool.rawValue))
            toolButtons[tool] = button
        }
        for (index, color) in colors.enumerated() {
            let names = [L("红色"), L("黄色"), L("绿色"), L("蓝色"), L("白色")]
            colorButtons.append(SelectionOptionButton(sample: .color(color), label: LF("标注颜色:%@", names[index])) { [weak self] in
                self?.change({ $0.colorID = index }, edit: { $0.updateSelectedAnnotation(color: color) })
            })
        }
        rebuildStickers()
        stickerOrderObserver = NotificationCenter.default.addObserver(forName: PreferencesStore.stickerOrderDidChange, object: self.preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildStickers(); self.stickerPicker?.replaceItems(self.stickers)
                self.refresh(); self.onUpdate?()
            }
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
    deinit { if let stickerOrderObserver { NotificationCenter.default.removeObserver(stickerOrderObserver) } }

    private func rebuildStickers() {
        let catalog = StickerCatalog.items
        let order = preferences.orderedStickerIdentifiers(defaults: catalog.map(\.id), canonicalize: StickerCatalog.canonicalIdentifier)
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        stickers = order.compactMap { byID[$0] }
        stickerButtons = stickers.map { sticker in
            let button = SelectionOptionButton(sample: .sticker(sticker.id), label: LF("贴纸图案:%@", L(sticker.title))) { [weak self] in
                self?.chooseSticker(sticker.id)
            }
            button.identifier = NSUserInterfaceItemIdentifier(sticker.id)
            button.toolbarMetrics = toolbarMetrics
            return button
        }
    }

    var rows: [[NSView]] { rows(maxWidth: .greatestFiniteMagnitude) }

    func rows(maxWidth: CGFloat) -> [[NSView]] {
        var rows: [[NSView]] = [Self.displayOrder.compactMap { toolButtons[$0] } + [undoButton]]
        guard let activeTool else { return rows }
        switch activeTool {
        case .arrow, .rectangle, .ellipse, .pen: rows.append(group(L("颜色"), colorButtons) + [parameterSeparator] + group(L("粗细"), [sizeControl]))
        case .text: rows.append(group(L("颜色"), colorButtons) + [parameterSeparator] + group(L("字号"), [sizeControl]))
        case .number: rows.append(group(L("颜色"), colorButtons) + [parameterSeparator] + group(L("大小"), [sizeControl]))
        case .mosaic: rows.append(group(L("块大小"), [sizeControl]))
        case .sticker:
            let prefix = group(L("图案"), [])
            let suffix = [moreStickerButton, parameterSeparator] + group(L("大小"), [sizeControl])
            var inline: [NSView] = []
            for button in stickerButtons {
                guard SelectionToolbar.singleLineWidth(prefix + inline + [button] + suffix) <= maxWidth else { break }
                inline.append(button)
            }
            rows.append(prefix + inline + suffix)
        }
        return rows
    }

    func rows(appendingActions actions: [NSView], maxWidth: CGFloat = .greatestFiniteMagnitude) -> [[NSView]] {
        let controlRows = rows(maxWidth: maxWidth)
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
        case .text: category = L("文字大小"); current = value.fontSize; range = 8...72; step = 1
        case .sticker: category = L("贴纸大小"); current = value.fontSize; range = 8...96; step = 1
        case .number: category = L("序号大小"); current = value.numberSize; range = 8...64; step = 1
        case .mosaic: category = L("马赛克大小"); current = value.mosaicBlockSize; range = 1...32; step = 1
        default: category = L("标注粗细"); current = value.width; range = 0.5...12; step = 0.5
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
        let controller = StickerPickerController(items: stickers, selected: selected,
            availableWidth: moreStickerButton.window?.screen.map { max(62, $0.visibleFrame.width - 16) }, onReorder: { [weak self] identifiers in
            self?.preferences.setStickerOrder(identifiers, defaults: StickerCatalog.items.map(\.id), canonicalize: StickerCatalog.canonicalIdentifier)
        }) { [weak self] identifier in
            self?.chooseSticker(identifier)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = controller
        stickerPopover = popover
        stickerPicker = controller
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
        label.font = .systemFont(ofSize: toolbarMetrics.parameterSize, weight: .medium)
        label.textColor = ToolbarPalette.secondaryInk
        return [label] + buttons
    }
}

class SelectionOptionButton: SelectionButton {
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
        if toolbarMetrics != .compact {
            return CGSize(width: max(toolbarMetrics.buttonWidth, sampleWidth), height: toolbarMetrics.buttonHeight)
        }
        return CGSize(width: sampleWidth, height: toolbarMetrics.buttonHeight)
    }
    private var sampleWidth: CGFloat {
        switch sample {
        case .color, .sticker: return 30
        case .font: return 34
        default: return 38
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
            let side = toolbarMetrics.glyphSize
            let box = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
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
            let side = toolbarMetrics == .compact ? CGFloat(20) : 24
            let rect = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            if !StickerCatalog.draw(sticker, in: rect) {
                centeredText(StickerCatalog.item(for: sticker)?.emoji ?? sticker,
                             font: NSFont(name: "Apple Color Emoji", size: side) ?? .systemFont(ofSize: side), color: .white)
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
    private(set) var items: [StickerCatalog.Item]
    private let selected: String
    private let onPick: (String) -> Void
    private let onReorder: (([String]) -> Void)?
    private var buttons: [StickerDragButton] = []
    private var insertionIndex: Int?
    private let columns: Int
    private static let pitch: CGFloat = 38
    init(items: [StickerCatalog.Item], selected: String, availableWidth: CGFloat? = nil, onReorder: (([String]) -> Void)? = nil,
         onPick: @escaping (String) -> Void) {
        self.items = items; self.selected = StickerCatalog.canonicalIdentifier(selected)
        columns = max(1, min(8, Int(floor(((availableWidth ?? 328) - 24) / Self.pitch))))
        self.onPick = onPick; self.onReorder = onReorder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        let root = StickerPickerRoot()
        root.owner = self
        view = root
        renderItems()
    }
    func replaceItems(_ items: [StickerCatalog.Item]) {
        self.items = items
        if isViewLoaded { renderItems() }
    }
    private func renderItems() {
        view.subviews.forEach { $0.removeFromSuperview() }; buttons.removeAll()
        let rows = (items.count + columns - 1) / columns
        let size = CGSize(width: 24 + CGFloat(columns) * Self.pitch, height: 70 + CGFloat(rows) * Self.pitch)
        view.frame.size = size
        let title = NSTextField(labelWithString: L("更多贴纸"))
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.textColor = ToolbarPalette.ink
        title.frame = CGRect(x: 14, y: size.height - 29, width: size.width - 28, height: 20)
        view.addSubview(title)
        let hint = NSTextField(labelWithString: L("拖动图案可调整顺序"))
        hint.font = .systemFont(ofSize: 11); hint.textColor = ToolbarPalette.secondaryInk
        hint.frame = CGRect(x: 14, y: size.height - 48, width: size.width - 28, height: 18)
        view.addSubview(hint)
        for (index, item) in items.enumerated() {
            let button = StickerDragButton(item: item) { [weak self] in self?.onPick(item.id) }
            button.owner = self; button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.toolTip = "\(L(item.groupTitle)) · \(L(item.title))"
            button.state = item.id == selected ? .on : .off
            button.frame = CGRect(x: 12 + CGFloat(index % columns) * Self.pitch,
                                  y: size.height - 62 - CGFloat(index / columns + 1) * Self.pitch, width: 36, height: 34)
            buttons.append(button); view.addSubview(button)
        }
        clearDropIndicator()
    }
    /// The insertion slot is measured before removing the source, just like the drag indicator.
    @discardableResult func moveSticker(_ identifier: String, toInsertionIndex index: Int) -> Bool {
        guard let source = items.firstIndex(where: { $0.id == identifier }), (0...items.count).contains(index) else { return false }
        let destination = index > source ? index - 1 : index
        guard source != destination else { return false }
        var reordered = items
        let item = reordered.remove(at: source); reordered.insert(item, at: destination)
        replaceItems(reordered)
        onReorder?(reordered.map(\.id))
        return true
    }
    @discardableResult fileprivate func updateReorder(_ identifier: String, at point: CGPoint) -> Bool {
        guard let source = items.firstIndex(where: { $0.id == identifier }),
              view.bounds.contains(point), point.y <= view.bounds.height - 58 else { clearDropIndicator(); return false }
        let row = max(0, Int((view.bounds.height - 62 - point.y) / Self.pitch))
        let column = min(columns, max(0, Int(floor((point.x - 12 + 18) / Self.pitch))))
        var index = min(items.count, row * columns + column)
        // A drop over an item's centre moves past it in the travel direction.
        // In particular, dragging onto the next item must swap the two items.
        if let target = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            index = target > source ? target + 1 : target
        }
        insertionIndex = index
        let rect: CGRect
        if index < buttons.count { rect = buttons[index].frame }
        else if let last = buttons.last { rect = last.frame.offsetBy(dx: Self.pitch, dy: 0) }
        else { return false }
        (view as? StickerPickerRoot)?.dropIndicator = CGRect(x: rect.minX - 2, y: rect.minY, width: 2, height: rect.height)
        return true
    }
    fileprivate func finishReorder(_ identifier: String, at point: CGPoint) {
        guard updateReorder(identifier, at: point), let index = insertionIndex else { return }
        moveSticker(identifier, toInsertionIndex: index)
        clearDropIndicator()
    }
    fileprivate func clearDropIndicator() {
        insertionIndex = nil; (viewIfLoaded as? StickerPickerRoot)?.dropIndicator = nil
    }
}

private final class StickerPickerRoot: ToolbarMaterialView {
    weak var owner: StickerPickerController?
    var dropIndicator: CGRect? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let dropIndicator { ToolbarPalette.accent.setFill(); NSBezierPath(roundedRect: dropIndicator, xRadius: 1, yRadius: 1).fill() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

private final class StickerDragButton: SelectionOptionButton {
    weak var owner: StickerPickerController?
    private let item: StickerCatalog.Item
    private var cursorTracking: NSTrackingArea?
    private var isReordering = false
    init(item: StickerCatalog.Item, action: @escaping () -> Void) {
        self.item = item
        super.init(sample: .sticker(item.id), label: LF("贴纸图案:%@", L(item.title)), action: action)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); cursorTracking = tracking
    }
    override func cursorUpdate(with event: NSEvent) { (isReordering ? NSCursor.closedHand : .openHand).set() }
    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, let owner else { return }
        func pickerPoint(_ event: NSEvent) -> CGPoint {
            var point = event.locationInWindow
            if let eventWindow = event.window, eventWindow !== window {
                point = window.convertPoint(fromScreen: eventWindow.convertPoint(toScreen: point))
            }
            return owner.view.convert(point, from: nil)
        }
        let start = pickerPoint(event)
        var lastPoint = start
        defer {
            isReordering = false; alphaValue = 1; highlight(false)
            owner.clearDropIndicator()
            (owner.view.window?.isVisible == true && owner.view.bounds.contains(lastPoint) ? NSCursor.openHand : .arrow).set()
        }
        highlight(true)
        // Reordering never leaves this picker, so retain the pointer gesture here
        // through mouse-up instead of handing it to a separate system drag session.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown {
                if next.keyCode == 53 { return }
                continue
            }
            lastPoint = pickerPoint(next)
            if next.type == .leftMouseUp {
                if isReordering { owner.finishReorder(item.id, at: lastPoint) }
                else if bounds.contains(convert(lastPoint, from: owner.view)) { performClick(nil) }
                return
            }
            if !isReordering, hypot(lastPoint.x - start.x, lastPoint.y - start.y) >= 5 {
                isReordering = true; highlight(false); alphaValue = 0.5
            }
            if isReordering { NSCursor.closedHand.set(); owner.updateReorder(item.id, at: lastPoint) }
        }
    }
}

final class SelectionToolbar: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let itemGap: CGFloat = 2
    var rows: [[NSView]] = [] { didSet { metrics.apply(to: rows.flatMap { $0 }) } }
    private(set) var metrics = ToolbarMetrics.compact
    private var metricsUpdateQueued = false
    /// The owner relays this to its full layout, so a detached HUD also resizes.
    var onDisplayMetricsChanged: (() -> Void)?
    @discardableResult func configure(forBackingScaleFactor factor: CGFloat) -> Bool {
        let next = ToolbarMetrics.forBackingScaleFactor(factor)
        guard next != metrics else { return false }
        metrics = next; metrics.apply(to: rows.flatMap { $0 })
        needsLayout = true
        return true
    }
    func prepareItems(_ items: [NSView]) { metrics.apply(to: items) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshDisplayMetrics()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshDisplayMetrics()
    }
    private func refreshDisplayMetrics() {
        guard let window else { return }
        if configure(forBackingScaleFactor: window.backingScaleFactor), !metricsUpdateQueued {
            // A window can change displays while its owner is placing the HUD.
            // Re-enter the owner's complete layout after that placement finishes.
            metricsUpdateQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.metricsUpdateQueued = false
                if self.window != nil { self.onDisplayMetricsChanged?() }
            }
        }
        needsDisplay = true
    }
    /// Reserve the upper-right corner for final actions while other tools wrap below.
    var trailingActions: [NSView] = []
    private var installedItems: [NSView] = []
    private var surfaces: [ToolbarRowSurface] = []
    private var rowRules: [ToolbarRowRule] = []
    private let blendingMode: NSVisualEffectView.BlendingMode

    init(blendingMode: NSVisualEffectView.BlendingMode = .withinWindow) {
        self.blendingMode = blendingMode
        super.init(frame: .zero)
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
        if let window { configure(forBackingScaleFactor: window.backingScaleFactor) }
        metrics.apply(to: rows.flatMap { $0 })
        let visible = rows.flatMap { $0 }
        installedItems.filter { child in !visible.contains(where: { $0 === child }) }.forEach { $0.removeFromSuperview() }
        installedItems = visible
        let widthLimit = max(metrics.buttonWidth + Self.horizontalInset * 2, maxWidth)
        let horizontalInset = Self.horizontalInset
        let itemGap = Self.itemGap
        var placements: [(NSView, CGRect)] = []
        var rowFrames: [CGRect] = []
        var top: CGFloat = 0
        var widest: CGFloat = 0
        var height: CGFloat = 0
        // Keep normal spacing when it fits. In a short display area, tighten
        // only the row padding and gaps; native button targets retain their size.
        let buttonHeight = metrics.buttonHeight
        for spacing in [(padding: CGFloat(6), row: CGFloat(4), line: buttonHeight + 4),
                        (padding: CGFloat(4), row: CGFloat(2), line: buttonHeight + 2)] {
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
                    placements.append((item, CGRect(x: x, y: lineTop, width: width, height: buttonHeight)))
                    x += width + itemGap
                    rowWidth = max(rowWidth, x - itemGap + horizontalInset)
                }
                if pinsActions {
                    var actionX = rowLimit - horizontalInset - groupWidth
                    for action in trailingActions {
                        let width = itemWidth(action, limit: widthLimit)
                        placements.append((action, CGRect(x: actionX, y: firstLine, width: width, height: buttonHeight)))
                        actionX += width + itemGap
                    }
                }
                let rowHeight = lineTop + buttonHeight + spacing.padding - top
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
            let height = item is NSTextField ? min(buttonHeight, max(14, item.fittingSize.height)) : rect.height
            item.frame = CGRect(x: rect.minX, y: size.height - rect.maxY + (rect.height - height) / 2,
                                width: rect.width, height: height)
            if item.superview !== self { addSubview(item) }
        }
        return size
    }

    private func itemWidth(_ item: NSView, limit: CGFloat) -> CGFloat {
        min(limit - Self.horizontalInset * 2, Self.idealItemWidth(item))
    }

    /// The same widths and spacing used during placement, before any wrapping.
    static func singleLineWidth(_ items: [NSView], metrics: ToolbarMetrics? = nil) -> CGFloat {
        metrics?.apply(to: items)
        return horizontalInset * 2 + items.reduce(CGFloat(0)) { $0 + idealItemWidth($1) }
            + CGFloat(max(0, items.count - 1)) * itemGap
    }

    private static func idealItemWidth(_ item: NSView) -> CGFloat {
        if item is ToolbarSeparator { return 8 }
        return max(item is NSTextField ? 22 : 30, item.fittingSize.width)
    }
}
