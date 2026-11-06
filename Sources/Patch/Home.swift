// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

enum HomeWindowPalette {
    static let ink = AppTheme.color(NSColor(srgbRed: 0.21, green: 0.28, blue: 0.25, alpha: 1), NSColor(srgbRed: 0.94, green: 0.92, blue: 0.88, alpha: 1))
    static let muted = AppTheme.color(NSColor(srgbRed: 0.40, green: 0.46, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.73, green: 0.70, blue: 0.66, alpha: 1))
    static let wood = AppTheme.color(NSColor(srgbRed: 0.97, green: 0.98, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.235, green: 0.225, blue: 0.210, alpha: 1))
    static let edge = AppTheme.color(NSColor(srgbRed: 0.58, green: 0.64, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.66, green: 0.62, blue: 0.55, alpha: 1))
    static let shade = AppTheme.color(NSColor(srgbRed: 0.86, green: 0.89, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1))
    static let background = WindowAmbientBackground.color
    static let glass = AppTheme.color(.white, NSColor(srgbRed: 0.14, green: 0.14, blue: 0.14, alpha: 1))
    static let highlight = AppTheme.color(.white, NSColor(srgbRed: 0.93, green: 0.86, blue: 0.72, alpha: 1))
    static func arch(_ rect: CGRect, rise: CGFloat) -> CGPath {
        let p = CGMutablePath(), x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        p.move(to: CGPoint(x: x, y: y + h)); p.addLine(to: CGPoint(x: x, y: y + rise))
        p.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x, y: y + rise * 0.448), control2: CGPoint(x: x + w * 0.224, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + rise), control1: CGPoint(x: x + w * 0.776, y: y), control2: CGPoint(x: x + w, y: y + rise * 0.448))
        p.addLine(to: CGPoint(x: x + w, y: y + h)); p.closeSubpath()
        return p
    }
}

@MainActor
private class HomeFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor private final class HomeUtilityView: HomeFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor private final class HomeApertureView: HomeFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard HomeWindowPalette.arch(bounds, rise: 87).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Animate the glass independently; native controls stay flat for crisp text and stable hit targets.
@MainActor
final class HomeFeatureTile: NSView {
    let launchButton: NSButton
    let shortcutButton: NSButton
    var shortcutButtons: [NSButton] { [keycap, alternateKeycap] }
    var removeShortcutButtons: [NSButton] { removeButtons }
    let addShortcutButton = NSButton(title: "+", target: nil, action: nil)
    var shortcutControls: [NSView] { shortcutButtons + removeShortcutButtons + [addShortcutButton] }
    let surface = CALayer()
    let fixedFrame = CALayer()
    private let glassStage = HomeFlippedView()
    private let moving = HomeFlippedView()
    private let polish = CAGradientLayer()
    private let fogMask = CALayer()
    private let latch = CALayer()
    private var pointerOverShortcut = false
    private var shortcutIssues: [String?] = []
    private var shortcutTitles: [String] = []
    private var shortcutEditing = false
    private var recordedSlot: Int?
    private var hoveredShortcut: NSButton?
    private(set) var isShortcutHovered = false
    private(set) var isLaunchHovered = false
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var polishCount = 0
    private(set) var openingCount = 0
    var isEditingShortcut = false { didSet { updateSurface() } }
    var topInset: CGFloat = 0 { didSet { needsLayout = true } }
    var onLaunch: (() -> Void)?
    var onEdit: (() -> Void)?
    var onEditShortcut: ((Int) -> Void)?
    var onAddShortcut: (() -> Void)?
    var onRemoveShortcut: ((Int) -> Void)?
    private let launch: HomeActionButton
    private let keycap: HomeActionButton
    private let alternateKeycap = HomeActionButton(frame: .zero)
    private let removeButtons = [NSButton(title: "×", target: nil, action: nil), NSButton(title: "×", target: nil, action: nil)]
    private var allowsShortcutEditing = true
    private let reducedTransparency: () -> Bool

    init(action: ShortcutAction? = nil, reducedTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.reducedTransparency = reducedTransparency
        let symbols: [ShortcutAction: String] = [.screenshot: "viewfinder", .scroll: "arrow.down.document", .text: "text.viewfinder", .pin: "pin", .record: "video", .subject: "person.crop.rectangle", .togglePins: "rectangle.on.rectangle"]
        launch = HomeActionButton(frame: .zero)
        keycap = HomeActionButton(frame: .zero)
        launch.cell = HomeLaunchCell()
        launch.target = launch; launch.action = #selector(HomeActionButton.invoke)
        launch.title = action?.title ?? L("退出")
        launchButton = launch; shortcutButton = keycap
        allowsShortcutEditing = action != nil
        super.init(frame: .zero)
        wantsLayer = true; glassStage.wantsLayer = true; moving.wantsLayer = true
        addSubview(glassStage); glassStage.addSubview(moving)
        glassStage.layer?.masksToBounds = true
        // The stationary frame stays above the sash; no projected glass or shadow can cover it.
        layer?.masksToBounds = true
        fixedFrame.borderColor = HomeWindowPalette.edge.withAlphaComponent(0.6).cgColor
        fixedFrame.borderWidth = 1; fixedFrame.zPosition = 200
        layer?.addSublayer(fixedFrame)
        surface.borderColor = AppTheme.color(HomeWindowPalette.edge.withAlphaComponent(0.25), HomeWindowPalette.highlight.withAlphaComponent(0.32)).cgColor
        surface.borderWidth = 0.5
        moving.layer?.shadowColor = HomeWindowPalette.ink.cgColor
        moving.layer?.shadowRadius = 3
        moving.layer?.shadowOffset = CGSize(width: 2, height: 2)
        moving.layer?.shadowOpacity = 0
        fogMask.backgroundColor = NSColor.black.cgColor
        surface.mask = fogMask
        moving.layer?.addSublayer(surface)
        polish.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.clear.cgColor]
        polish.startPoint = CGPoint(x: 0, y: 0.35); polish.endPoint = CGPoint(x: 1, y: 0.65)
        polish.opacity = 0; moving.layer?.addSublayer(polish)
        latch.backgroundColor = NSColor.white.cgColor; latch.borderColor = HomeWindowPalette.edge.cgColor
        latch.borderWidth = 1; latch.cornerRadius = 2; moving.layer?.addSublayer(latch)
        addSubview(launch)
        shortcutControls.forEach { addSubview($0) }
        // Keep controls in a separate, frontmost plane, beyond the sash's positive-Z lift.
        for button in [launch] + shortcutButtons + removeShortcutButtons + [addShortcutButton] {
            button.wantsLayer = true; button.layer?.zPosition = 100
        }
        launch.image = NSImage(systemSymbolName: action.flatMap { symbols[$0] } ?? "power", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        if action == .recentContent { launch.image = WindowGlyph.image(.records) }
        if action == .pinRecent { launch.image = WindowGlyph.image(.batch) }
        if action == .recentContent || action == .pinRecent { launch.image?.size = NSSize(width: 28, height: 28) }
        launch.imagePosition = .imageAbove
        launch.cell?.wraps = true; launch.cell?.usesSingleLineMode = false
        launch.cell?.lineBreakMode = .byWordWrapping
        launch.font = .systemFont(ofSize: 14, weight: .medium)
        launch.contentTintColor = HomeWindowPalette.ink
        keycap.font = .systemFont(ofSize: 12, weight: .medium)
        keycap.contentTintColor = HomeWindowPalette.muted
        keycap.lineBreakMode = .byTruncatingTail
        for button in [launch, keycap] { button.isBordered = false; button.bezelStyle = .regularSquare }
        launch.identifier = NSUserInterfaceItemIdentifier("home.launch.\(action?.rawValue ?? "quit")")
        keycap.identifier = NSUserInterfaceItemIdentifier("home.shortcut.\(action?.rawValue ?? "quit")")
        if action == .pin { launch.toolTip = L("贴出剪贴板中的图片或文字") }
        launch.setAccessibilityLabel(launch.title)
        keycap.setAccessibilityLabel(action == nil ? L("退出快捷键，固定为 ⌘Q") : LF("修改%@快捷键", launch.title))
        launch.onPress = { [weak self] in self?.updateSurface() }
        launch.onClick = { [weak self] in self?.openSash(); self?.onLaunch?() }
        keycap.onClick = { [weak self] in self?.onEdit?() }
        keycap.toolTip = action == nil ? L("退出当前应用（⌘Q）") : L("修改快捷键")
        keycap.isEnabled = action != nil
        alternateKeycap.isHidden = true
        for (index, button) in shortcutButtons.enumerated() {
            button.isBordered = false; button.bezelStyle = .regularSquare
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.cell?.wraps = false; button.cell?.usesSingleLineMode = true
            button.lineBreakMode = .byTruncatingMiddle
            button.isEnabled = allowsShortcutEditing
            // One rounded surface owns both hover fill and focus outline.
            button.focusRingType = .none
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.layer?.cornerRadius = 6
            (button as? HomeActionButton)?.onFocusChange = { [weak self] in self?.updateSurface() }
            if index > 0 { button.identifier = NSUserInterfaceItemIdentifier("home.shortcut.\(action?.rawValue ?? "quit").\(index)") }
            button.setAccessibilityLabel(action == nil ? L("退出快捷键，固定为 ⌘Q") : LF("修改%@快捷键", launch.title))
        }
        keycap.onClick = { [weak self] in self?.editShortcut(at: 0) }
        alternateKeycap.onClick = { [weak self] in self?.editShortcut(at: 1) }
        for (index, button) in removeButtons.enumerated() {
            button.tag = index; button.target = self; button.action = #selector(removeShortcut(_:))
            button.identifier = NSUserInterfaceItemIdentifier("home.shortcut-remove.\(action?.rawValue ?? "quit").\(index)")
            button.toolTip = L("移除这组快捷键"); button.setAccessibilityLabel(L("移除这组快捷键"))
        }
        addShortcutButton.target = self; addShortcutButton.action = #selector(addShortcut)
        addShortcutButton.identifier = NSUserInterfaceItemIdentifier("home.shortcut-add.\(action?.rawValue ?? "quit")")
        addShortcutButton.toolTip = L("添加快捷键（最多 2 组）")
        addShortcutButton.setAccessibilityLabel(L("添加快捷键（最多 2 组）"))
        for button in removeButtons + [addShortcutButton] {
            button.isBordered = false; button.bezelStyle = .regularSquare
            button.font = .systemFont(ofSize: 12); button.contentTintColor = HomeWindowPalette.muted
            button.isHidden = true
        }
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glassStage.frame = bounds
        moving.frame = bounds; moving.layer?.anchorPoint = CGPoint(x: 0, y: 0.5)
        moving.layer?.position = CGPoint(x: 0, y: bounds.midY)
        fixedFrame.frame = bounds
        let glass = bounds.insetBy(dx: 3, dy: 3)
        surface.frame = glass; fogMask.frame = surface.bounds
        // Cast from the rim only: a filled shadow would tint the whole translucent pane.
        moving.layer?.shadowPath = CGPath(rect: glass, transform: nil).copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 2)
        polish.frame = glass; latch.frame = CGRect(x: glass.maxX - 6, y: bounds.midY - 6, width: 4, height: 12)
        CATransaction.commit()
        let center = topInset + (bounds.height - topInset) * 0.48
        launch.frame = bounds
        (launch.cell as? HomeLaunchCell)?.contentRect = backingAlignedRect(CGRect(x: 12, y: center - 47, width: bounds.width - 24, height: 73), options: .alignAllEdgesNearest)
        layoutShortcuts(y: center + 28)
    }
    func configure(shortcut: String, editing: Bool, launchesEnabled: Bool, hasError: Bool) {
        configure(shortcuts: [shortcut], editing: editing, recordingIndex: nil, launchesEnabled: launchesEnabled,
                  issues: [hasError ? L("快捷键暂时不可用") : nil])
    }
    func configure(shortcuts: [String], editing: Bool, recordingIndex: Int?, launchesEnabled: Bool, issues: [String?]) {
        shortcutTitles = Array(shortcuts.prefix(2)); shortcutIssues = Array(issues.prefix(2))
        shortcutEditing = editing && allowsShortcutEditing; recordedSlot = recordingIndex
        let count = min(2, max(1, max(shortcutTitles.count, (recordingIndex ?? -1) + 1)))
        for (index, button) in shortcutButtons.enumerated() {
            button.isHidden = index >= count
            let full = index < shortcutTitles.count ? shortcutTitles[index] : recordingIndex == index ? L("按组合键") : L("未设置")
            button.title = Self.compactShortcut(full)
            let issue = index < shortcutIssues.count ? shortcutIssues[index] : nil
            button.toolTip = issue.map { full + "\n" + $0 } ?? full
            button.setAccessibilityValue(recordingIndex == index ? LF("%@，正在编辑", full) : full)
            removeButtons[index].isHidden = !shortcutEditing || index >= shortcutTitles.count
        }
        addShortcutButton.isHidden = !shortcutEditing || count >= 2
            || (recordingIndex.map { $0 >= shortcutTitles.count } ?? false)
        needsLayout = true
        launch.isEnabled = launchesEnabled; isEditingShortcut = editing
        updateSurface()
    }
    private static func compactShortcut(_ value: String) -> String {
        value.replacingOccurrences(of: "Page Down", with: "⇟").replacingOccurrences(of: "Page Up", with: "⇞")
            .replacingOccurrences(of: "Home", with: "↖").replacingOccurrences(of: "End", with: "↘")
            .replacingOccurrences(of: "空格", with: "␣").replacingOccurrences(of: "Space", with: "␣")
    }
    private func layoutShortcuts(y: CGFloat) {
        let keys = shortcutButtons.filter { !$0.isHidden }
        let gap: CGFloat = keys.count > 1 ? 4 : 0
        let actionWidth: CGFloat = 14
        let addWidth: CGFloat = addShortcutButton.isHidden ? 0 : 18
        let addGap: CGFloat = addWidth > 0 ? 4 : 0
        let available = max(1, bounds.width - 20 - addWidth - addGap - gap)
        let maximum = available / CGFloat(max(1, keys.count))
        var widths: [CGFloat] = []
        for (index, button) in keys.enumerated() {
            let removeWidth: CGFloat = removeButtons[index].isHidden ? 0 : actionWidth
            let normal = NSFont.systemFont(ofSize: 12, weight: .medium)
            let measured = (button.title as NSString).size(withAttributes: [.font: normal]).width + 8
            button.font = .systemFont(ofSize: measured + removeWidth > maximum ? 11 : 12, weight: .medium)
            let natural = (button.title as NSString).size(withAttributes: [.font: button.font!]).width + 8
            widths.append(min(maximum, max(keys.count == 1 ? 40 : 24, natural) + removeWidth))
        }
        let total = widths.reduce(0, +) + gap + addGap + addWidth
        var x = (bounds.width - total) / 2
        for (index, button) in keys.enumerated() {
            let removeWidth: CGFloat = removeButtons[index].isHidden ? 0 : actionWidth
            // Frames include the editing affordances; long chords stay single-line
            // with the complete combination available in the tooltip/accessibility value.
            button.frame = backingAlignedRect(CGRect(x: x, y: y, width: max(1, widths[index] - removeWidth), height: 28), options: .alignAllEdgesNearest)
            removeButtons[index].frame = backingAlignedRect(CGRect(x: x + widths[index] - removeWidth, y: y, width: removeWidth, height: 28), options: .alignAllEdgesNearest)
            x += widths[index] + gap
        }
        addShortcutButton.frame = backingAlignedRect(CGRect(x: (bounds.width + total) / 2 - addWidth, y: y, width: addWidth, height: 28), options: .alignAllEdgesNearest)
    }
    private func editShortcut(at index: Int) { if let onEditShortcut { onEditShortcut(index) } else { onEdit?() } }
    @objc private func addShortcut() { onAddShortcut?() }
    @objc private func removeShortcut(_ sender: NSButton) { onRemoveShortcut?(sender.tag) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(with: event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(with: event) }
    private func updatePointer(with event: NSEvent) {
        isHovered = true
        // Use the stationary pane coordinates so opening the sash cannot shift hover targets.
        let point = convert(event.locationInWindow, from: nil)
        hoveredShortcut = shortcutButtons.first { !$0.isHidden && $0.frame.contains(point) }
        pointerOverShortcut = shortcutControls.contains { !$0.isHidden && $0.frame.contains(point) }
        updateSurface()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false; pointerOverShortcut = false; hoveredShortcut = nil; updateSurface() }
    func resetInteraction() { isHovered = false; pointerOverShortcut = false; hoveredShortcut = nil; launch.highlight(false); shortcutButtons.forEach { $0.highlight(false) }; moving.layer?.removeAnimation(forKey: "open"); updateSurface() }
    func stopFeedback() { fogMask.removeAllAnimations(); polish.removeAllAnimations() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); updateSurface()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateSurface() }
    private func updateSurface() {
        effectiveAppearance.performAsCurrentDrawingAppearance { updateSurfaceColors() }
    }
    private func updateSurfaceColors() {
        surface.borderColor = AppTheme.color(HomeWindowPalette.edge.withAlphaComponent(0.25), HomeWindowPalette.highlight.withAlphaComponent(0.32)).cgColor
        latch.backgroundColor = HomeWindowPalette.wood.cgColor
        latch.borderColor = HomeWindowPalette.edge.cgColor
        isShortcutHovered = isHovered && pointerOverShortcut && keycap.isEnabled
        isLaunchHovered = isHovered && !pointerOverShortcut && launch.isEnabled
        let emphasized = isEditingShortcut || isHovered || launch.isHighlighted
        launch.font = .systemFont(ofSize: 14, weight: .medium)
        launch.contentTintColor = HomeWindowPalette.ink
        for (index, button) in shortcutButtons.enumerated() {
            let hasIssue = index < shortcutIssues.count && shortcutIssues[index] != nil
            let selected = (shortcutEditing && recordedSlot == index) || (button.isEnabled && (button as? HomeActionButton)?.hasKeyboardFocus == true)
            let hovered = isShortcutHovered && button === hoveredShortcut
            button.contentTintColor = hasIssue ? .systemOrange : selected || hovered ? HomeWindowPalette.ink : HomeWindowPalette.muted
            CATransaction.begin(); CATransaction.setDisableActions(true)
            button.layer?.backgroundColor = HomeWindowPalette.edge.withAlphaComponent(selected || hovered ? 0.25 : 0).cgColor
            button.layer?.borderColor = (hasIssue ? NSColor.systemOrange : HomeWindowPalette.edge).cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            CATransaction.commit()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        surface.backgroundColor = HomeWindowPalette.glass.withAlphaComponent(reducedTransparency() ? 1 : emphasized ? 0.48 : 0.64).cgColor
        fixedFrame.borderColor = HomeWindowPalette.edge.withAlphaComponent(emphasized ? 0.95 : 0.6).cgColor
        CATransaction.commit()
        updateSash()
    }
    private func updateSash() {
        guard let layer = moving.layer else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let opened = isHovered && launch.isEnabled && !reduceMotion
        let target = opened ? sashTransform(angle: -.pi / 30) : CATransform3DIdentity
        guard !CATransform3DEqualToTransform(layer.transform, target) else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        let previousShadow = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        let targetShadow: Float = opened ? 0.14 : 0
        layer.removeAnimation(forKey: "open")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = target
        layer.shadowOpacity = targetShadow
        CATransaction.commit()
        if !reduceMotion {
            let transition = CABasicAnimation(keyPath: "transform")
            transition.fromValue = NSValue(caTransform3D: from)
            transition.toValue = NSValue(caTransform3D: target)
            transition.duration = 0.2
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "hoverOpen")
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = previousShadow; shadow.toValue = targetShadow
            shadow.duration = transition.duration; shadow.timingFunction = transition.timingFunction
            layer.add(shadow, forKey: "sashShadow")
        } else {
            layer.removeAnimation(forKey: "hoverOpen")
            layer.removeAnimation(forKey: "sashShadow")
        }
    }
    private func sashTransform(angle: CGFloat) -> CATransform3D {
        // Negative Y rotation puts the free edge at positive Z, toward the viewer.
        // A slightly nearer perspective makes that lift visible without crossing the fixed rim.
        var perspective = CATransform3DIdentity; perspective.m34 = -1 / 700
        return CATransform3DRotate(perspective, angle, 0, 1, 0)
    }
    private func openSash() {
        openingCount += 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let resting = moving.layer?.transform ?? CATransform3DIdentity
        let from = moving.layer?.presentation()?.transform ?? resting
        let open = sashTransform(angle: -.pi * 7 / 180)
        moving.layer?.removeAnimation(forKey: "hoverOpen")
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [NSValue(caTransform3D: from), NSValue(caTransform3D: open), NSValue(caTransform3D: open), NSValue(caTransform3D: resting)]
        animation.keyTimes = [0, 0.42, 0.65, 1]; animation.duration = 0.58
        moving.layer?.add(animation, forKey: "open")
        // Dispatch the feature immediately; a hidden Home never delays capture for decoration.
    }
    func polishGlass() {
        polishCount += 1; stopFeedback()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !reducedTransparency() else { return }
        // Keep the glass mask in place: uncovering the scenery makes a "wipe" look darker.
        let shine = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shine.values = [-bounds.width, bounds.width]; shine.duration = 0.72
        let alpha = CAKeyframeAnimation(keyPath: "opacity")
        alpha.values = [0, 0.6, 0.6, 0]; alpha.keyTimes = [0, 0.12, 0.82, 1]; alpha.duration = 0.72
        let group = CAAnimationGroup(); group.animations = [shine, alpha]; group.duration = 0.72
        polish.add(group, forKey: "polish")
    }
}

@MainActor private final class HomeActionButton: NSButton {
    var onClick: (() -> Void)?
    var onPress: (() -> Void)?
    var onFocusChange: (() -> Void)?
    private(set) var hasKeyboardFocus = false
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasKeyboardFocus = true; onFocusChange?() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { hasKeyboardFocus = false; onFocusChange?() }
        return accepted
    }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(invoke) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc func invoke() { onClick?() }
    override func highlight(_ flag: Bool) { super.highlight(flag); onPress?() }
    override var isEnabled: Bool { didSet { onPress?() } }
}

/// Keep the whole pane clickable while standard AppKit cells lay out its icon and text.
@MainActor private final class HomeLaunchCell: NSButtonCell {
    var contentRect = NSRect.zero
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: contentRect.isEmpty ? cellFrame : contentRect, in: controlView)
    }
}

@MainActor private final class HomeMullions: HomeFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let width = (bounds.width - 44) / 5
        let vertical = (1...4).map { CGRect(x: CGFloat($0) * width + CGFloat($0 - 1) * 11, y: 0, width: 11, height: bounds.height) }
        for rect in vertical + [CGRect(x: 0, y: 205, width: bounds.width, height: 11)] {
            HomeWindowPalette.wood.setFill(); rect.fill()
            HomeWindowPalette.edge.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            AppTheme.color(.white, HomeWindowPalette.highlight.withAlphaComponent(0.45)).setFill(); CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width > 11 ? rect.width - 2 : 2, height: rect.height > 11 ? rect.height - 2 : 2).fill()
        }
    }
}

@MainActor private final class HomeArchView: HomeFlippedView {
    let aperture = HomeApertureView()
    let scenery = HomeSceneryView()
    private let bars = HomeMullions()
    private let mask = CAShapeLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        aperture.wantsLayer = true; aperture.layer?.mask = mask; addSubview(aperture)
        aperture.addSubview(scenery)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func addTiles(_ tiles: [HomeFeatureTile]) { tiles.forEach { aperture.addSubview($0) }; aperture.addSubview(bars) }
    override func layout() {
        super.layout()
        aperture.frame = CGRect(x: 25, y: 14, width: bounds.width - 50, height: 372)
        scenery.frame = aperture.bounds; bars.frame = aperture.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = aperture.bounds; mask.path = HomeWindowPalette.arch(aperture.bounds, rise: 87)
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.addPath(HomeWindowPalette.arch(CGRect(x: 16, y: 6, width: bounds.width - 22, height: 402), rise: 100))
        c.setFillColor(HomeWindowPalette.shade.withAlphaComponent(0.4).cgColor); c.fillPath()
        c.addPath(HomeWindowPalette.arch(CGRect(x: 11, y: 0, width: bounds.width - 22, height: 402), rise: 100))
        c.setFillColor(HomeWindowPalette.wood.cgColor); c.setStrokeColor(HomeWindowPalette.edge.cgColor); c.setLineWidth(1.5); c.drawPath(using: .fillStroke)
        if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            c.saveGState()
            c.setShadow(offset: .zero, blur: 4, color: HomeWindowPalette.highlight.withAlphaComponent(0.18).cgColor)
            c.addPath(HomeWindowPalette.arch(CGRect(x: 12, y: 1, width: bounds.width - 24, height: 400), rise: 99))
            c.setStrokeColor(HomeWindowPalette.highlight.withAlphaComponent(0.35).cgColor); c.setLineWidth(0.7); c.strokePath()
            c.restoreGState()
        }
        let sill = CGRect(x: 1, y: 402, width: bounds.width - 2, height: 13)
        HomeWindowPalette.wood.setFill(); sill.fill()
        HomeWindowPalette.edge.setStroke(); NSBezierPath(roundedRect: sill, xRadius: 2, yRadius: 2).stroke()
        HomeWindowPalette.shade.setFill(); CGRect(x: 2, y: 411, width: bounds.width - 4, height: 3).fill()
    }
}

@MainActor private final class HomeContentView: HomeFlippedView {
    var onLayout: (() -> Void)?
    var season: HomeSeason = .current() { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { WindowAmbientBackground.draw(in: self, season: season) }
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    let editor: ShortcutEditorSession
    private let store: PreferencesStore
    private(set) var tiles: [ShortcutAction: HomeFeatureTile] = [:]
    private(set) var isEditing = false
    private var editingAction: ShortcutAction?
    private var editingIndex = 0
    private let onLaunch: (ShortcutAction) -> Void
    private let content = HomeContentView()
    private let arch = HomeArchView()
    private let footer = HomeFlippedView()
    private let feedback = NSTextField(labelWithString: "")
    private let defaults = NSButton(title: L("恢复默认"), target: nil, action: nil)
    private let done = NSButton(title: L("保存"), target: nil, action: nil)
    private let cancelEdit = NSButton(title: L("取消"), target: nil, action: nil)
    private let closeHome = NSButton(title: L("关闭"), target: nil, action: nil)
    private let optionsButton = NSButton(title: L("更多设置"), target: nil, action: nil)
    private let screenPermission: () -> Bool
    private let onRequestScreenPermission: () -> Void
    private let onOptionsChanged: () -> Void
    private let permissionBanner = HomeFlippedView()
    private let permissionLabel = NSTextField(wrappingLabelWithString: L("需要屏幕录制权限"))
    private let permissionButton = NSButton(title: L("去授权"), target: nil, action: nil)
    private var optionsPage: AppOptionsView!
    private(set) var isShowingOptions = false
    private var isRefreshing = false
    let quitTile = HomeFeatureTile()
    var allTiles: [HomeFeatureTile] { ShortcutAction.settingsOrder.compactMap { tiles[$0] } + [quitTile] }
    private let pinState: () -> (hasPins: Bool, hidden: Bool)
    private let hasRecentContent: () -> Bool
    private let onQuit: () -> Void

    init(hotKeys: HotKeys, store: PreferencesStore, onSave: @escaping () -> Void, onLaunch: @escaping (ShortcutAction) -> Void,
         pinState: @escaping () -> (hasPins: Bool, hidden: Bool) = { (false, false) },
         onQuit: @escaping () -> Void = {}, onRecentContent: @escaping () -> Void = {},
         onOptions: @escaping () -> Void = {},
         screenPermission: @escaping () -> Bool = { true },
         onRequestScreenPermission: @escaping () -> Void = {},
         onOptionsChanged: @escaping () -> Void = {},
         hasRecentContent: @escaping () -> Bool = { true }) {
        self.hasRecentContent = hasRecentContent
        self.screenPermission = screenPermission; self.onRequestScreenPermission = onRequestScreenPermission
        self.onOptionsChanged = onOptionsChanged
        editor = ShortcutEditorSession(hotKeys: hotKeys, store: store, keepsRecordingUntilFinished: true, onSave: onSave)
        self.store = store; self.onLaunch = onLaunch; self.pinState = pinState; self.onQuit = onQuit
        let window = ShortcutSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 536), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("patch.home")
        PatchWindowTitle.apply(to: window, title: L("Patch · 设置")); window.titlebarAppearsTransparent = true
        window.level = .normal; window.isReleasedWhenClosed = false; window.isOpaque = true
        window.backgroundColor = HomeWindowPalette.background
        window.contentView = content
        super.init(window: window); window.delegate = self
        window.onRecordingKey = { [weak self] event in
            guard let self else { return false }
            if self.isEditing, event.type == .keyDown, event.keyCode == 53 { self.cancelEditing(); return true }
            return self.editor.capture(event)
        }
        window.onRecordingModifiers = { [weak self] in self?.editor.reflectModifiers($0) }
        window.onCancelRequest = { [weak self] in self?.cancelRequest() }
        window.onPointerDown = { [weak self] in self?.finishEditingForClick($0) ?? false }
        content.season = arch.scenery.season
        arch.scenery.onSeasonChanged = { [weak self] season in self?.content.season = season }
        content.addSubview(arch)
        footer.addSubview(permissionBanner)
        permissionBanner.addSubview(permissionLabel); permissionBanner.addSubview(permissionButton)
        permissionLabel.alignment = .left
        permissionLabel.identifier = NSUserInterfaceItemIdentifier("home.permission-status")
        permissionLabel.font = .systemFont(ofSize: 12); permissionLabel.textColor = .systemOrange
        permissionButton.bezelStyle = .rounded; permissionButton.font = .systemFont(ofSize: 12)
        permissionButton.image = WindowGlyph.image(.authorize); permissionButton.imagePosition = .imageLeading
        permissionButton.contentTintColor = HomeWindowPalette.ink
        permissionButton.target = self; permissionButton.action = #selector(requestPermission)
        permissionButton.identifier = NSUserInterfaceItemIdentifier("home.authorize")
        optionsPage = AppOptionsView(preferences: store, onBack: { [weak self] in self?.showHomePage() },
            onChange: { [weak self] in
                guard let self else { return }
                self.onOptionsChanged()
                self.window?.appearance = self.store.appearancePreference.appearance
                self.content.needsDisplay = true
                self.refreshShortcuts()
            },
            onRequestPermission: { [weak self] in self?.requestPermission() })
        content.addSubview(optionsPage); optionsPage.isHidden = true
        for action in ShortcutAction.settingsOrder {
            let tile = HomeFeatureTile(action: action)
            tile.onLaunch = { [weak self] in
                guard let self, !self.isEditing else { return }
                self.editor.stopRecording(); self.onLaunch(action); self.refreshShortcuts()
            }
            tile.onEdit = { [weak self] in self?.beginEditing(action) }
            tile.onEditShortcut = { [weak self] index in self?.beginEditing(action, index: index) }
            tile.onAddShortcut = { [weak self] in
                guard let self else { return }
                self.beginEditing(action, index: self.editor.bindingDraft[action]?.count ?? 0)
            }
            tile.onRemoveShortcut = { [weak self] index in
                guard let self else { return }
                if !self.isEditing { self.isEditing = true; self.editor.reset() }
                self.editingAction = action; self.editingIndex = max(0, index - 1)
                self.editor.removeShortcut(action, index: index)
                self.refreshShortcuts()
            }
            tiles[action] = tile
        }
        quitTile.onLaunch = { [weak self] in self?.quitClicked() }
        arch.addTiles(allTiles)
        content.addSubview(footer)
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = HomeWindowPalette.muted
        feedback.usesSingleLineMode = true; feedback.lineBreakMode = .byTruncatingTail
        feedback.isSelectable = true
        feedback.identifier = NSUserInterfaceItemIdentifier("home.shortcut-status")
        footer.addSubview(feedback)
        for button in [defaults, done, cancelEdit, closeHome, optionsButton] {
            button.bezelStyle = .rounded; button.imagePosition = .imageLeading; button.target = self
            button.font = .systemFont(ofSize: 12); button.contentTintColor = HomeWindowPalette.ink
            footer.addSubview(button)
        }
        defaults.image = Self.handleImage(reset: true); done.image = Self.handleImage(reset: false)
        cancelEdit.image = Self.dismissImage(closing: false); closeHome.image = Self.dismissImage(closing: true)
        optionsButton.image = WindowGlyph.image(.settings)
        optionsButton.target = self; optionsButton.action = #selector(optionsClicked)
        defaults.action = #selector(defaultsClicked); done.action = #selector(doneClicked)
        cancelEdit.action = #selector(cancelClicked); closeHome.action = #selector(closeClicked)
        content.onLayout = { [weak self] in self?.layoutContent() }
        editor.onUpdate = { [weak self] in self?.refreshShortcuts() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshShortcuts(); refreshPermissions(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func showWindow(_ sender: Any?) {
        if let window { WindowActivationCoordinator.shared.register(window) }
        if window?.isVisible != true && !isEditing { editor.reset() }
        if !isEditing { editor.retryUnavailableBindings() }
        allTiles.forEach { $0.resetInteraction() }
        window?.deminiaturize(nil); super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshPermissions()
        arch.scenery.setMotionActive(!isShowingOptions)
    }
    func showOptions() {
        guard finishEditing() else { return }
        isShowingOptions = true
        if let window { PatchWindowTitle.apply(to: window, title: L("Patch · 更多设置")) }
        arch.isHidden = true; footer.isHidden = true; permissionBanner.isHidden = true
        optionsPage.isHidden = false; optionsPage.refreshAppearanceSelection()
        resizePage(height: 48 + AppOptionsView.preferredContentHeight)
        refreshPermissions(); layoutContent()
        arch.scenery.setMotionActive(false)
        window?.makeFirstResponder(nil)
    }
    func showHomePage() {
        isShowingOptions = false
        if let window { PatchWindowTitle.apply(to: window, title: L("Patch · 设置")) }
        optionsPage.isHidden = true; arch.isHidden = false; footer.isHidden = false
        resizePage(height: 536)
        refreshShortcuts(); refreshPermissions()
        window?.makeFirstResponder(nil)
        arch.scenery.setMotionActive(window?.isVisible == true)
    }
    func refreshPermissions() {
        let granted = screenPermission()
        permissionBanner.isHidden = granted || isShowingOptions || isEditing || !feedback.stringValue.isEmpty
        optionsPage?.refreshPermissions(granted: granted)
        permissionButton.toolTip = L("允许小贴截图、识别屏幕文字和录屏")
    }
    @objc private func requestPermission() {
        onRequestScreenPermission(); refreshPermissions()
    }
    private func resizePage(height: CGFloat) {
        guard let window else { return }
        let original = window.frame
        let frameHeight = original.height + height - content.bounds.height
        window.setFrame(NSRect(x: original.minX, y: original.maxY - frameHeight,
                               width: original.width, height: frameHeight), display: true)
    }
    func beginEditing(_ action: ShortcutAction? = nil, index: Int = 0) {
        if isShowingOptions { showHomePage() }
        if !isEditing { isEditing = true; editor.reset() }
        tiles.values.forEach { $0.stopFeedback() }
        if let action {
            editingAction = action; editingIndex = min(1, max(0, index))
            editor.startRecording(action, index: editingIndex)
            window?.makeFirstResponder(tiles[action]?.shortcutButtons[editingIndex])
        }
        refreshShortcuts()
    }
    func cancelEditing() {
        isEditing = false; editingAction = nil; editor.reset()
        clearEditingFocus(); refreshShortcuts()
    }
    private func clearEditingFocus() {
        window?.makeFirstResponder(nil)
        allTiles.forEach { $0.resetInteraction() }
    }
    func refreshShortcuts() {
        guard !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        editor.refreshAvailability()
        let previousFeedback = feedback.stringValue
        for action in ShortcutAction.settingsOrder {
            let recording = editor.recordingAction == action
            let count = editor.bindingDraft[action]?.count ?? 0
            let titles = (0..<count).map { index in editor.recordingTitle(action, index: index) }
            let issues: [String?] = (0..<max(count, (recording ? (editor.recordingIndex ?? -1) : -1) + 1)).map { index in
                editor.hasIssue(action, index: index) ? editor.message(action, index: index) : nil
            }
            tiles[action]?.configure(shortcuts: titles, editing: isEditing,
                recordingIndex: recording ? editor.recordingIndex : nil,
                launchesEnabled: !isEditing, issues: issues)
        }
        let state = pinState()
        tiles[.togglePins]?.launchButton.title = state.hidden ? L("显示全部贴图") : L("隐藏全部贴图")
        tiles[.togglePins]?.launchButton.isEnabled = state.hasPins && !isEditing
        let recentTitle = store.pinRecentTitle
        tiles[.pinRecent]?.launchButton.title = recentTitle
        tiles[.pinRecent]?.launchButton.setAccessibilityLabel(recentTitle)
        tiles[.pinRecent]?.launchButton.isEnabled = hasRecentContent() && !isEditing
        quitTile.configure(shortcut: "⌘Q", editing: false, launchesEnabled: !isEditing, hasError: false)
        let issues = ShortcutAction.settingsOrder.filter { editor.hasIssue($0) }
        let issue = editingAction.flatMap { issues.contains($0) ? $0 : nil } ?? issues.first
        if let issue { feedback.stringValue = editor.conciseMessage(issue); feedback.textColor = .systemOrange }
        else {
            feedback.stringValue = isEditing ? L("每项最多 2 组 · Esc 取消编辑") : ""
            feedback.textColor = HomeWindowPalette.muted
        }
        feedback.toolTip = feedback.stringValue.isEmpty ? nil : feedback.stringValue
        optionsButton.isHidden = isEditing
        refreshPermissions()
        footer.isHidden = isShowingOptions
        feedback.isHidden = feedback.stringValue.isEmpty
        defaults.isHidden = false; done.isHidden = !isEditing
        cancelEdit.isHidden = !isEditing; closeHome.isHidden = isEditing
        // Conflicting drafts need correction; operational failures can be retried.
        done.isEnabled = isEditing && !editor.hasBlockingShortcutIssues
        layoutContent()
        if previousFeedback != feedback.stringValue {
            NSAccessibility.post(element: feedback, notification: .valueChanged)
        }
    }
    private func layoutContent() {
        optionsPage.frame = CGRect(x: HomeFooterLayout.horizontalInset, y: 48,
            width: content.bounds.width - HomeFooterLayout.horizontalInset * 2, height: content.bounds.height - 48)
        arch.frame = CGRect(x: 42, y: 54, width: content.bounds.width - 84, height: 420)
        arch.layoutSubtreeIfNeeded()
        let width = (arch.aperture.bounds.width - 44) / 5
        for (index, tile) in allTiles.enumerated() {
            tile.topInset = index < 5 ? 55 : 0
            tile.frame = CGRect(x: CGFloat(index % 5) * (width + 11), y: index < 5 ? 0 : 216, width: width, height: index < 5 ? 205 : 156)
        }
        let buttonHeight = HomeFooterLayout.buttonHeight
        footer.frame = CGRect(x: HomeFooterLayout.horizontalInset, y: HomeFooterLayout.buttonY(in: content.bounds) - 3,
            width: content.bounds.width - HomeFooterLayout.horizontalInset * 2, height: 44)
        let trailingWidth = max(84, max(done.fittingSize.width, closeHome.fittingSize.width))
        done.frame = CGRect(x: footer.bounds.width - trailingWidth, y: 3, width: trailingWidth, height: buttonHeight)
        closeHome.frame = done.frame
        let cancelWidth = max(84, cancelEdit.fittingSize.width)
        cancelEdit.frame = CGRect(x: done.frame.minX - 8 - cancelWidth, y: 3, width: cancelWidth, height: buttonHeight)
        let restoreWidth = max(124, defaults.fittingSize.width)
        defaults.frame = CGRect(x: (isEditing ? cancelEdit.frame.minX : closeHome.frame.minX) - 12 - restoreWidth,
                                y: 3, width: restoreWidth, height: buttonHeight)
        optionsButton.frame = CGRect(x: 0, y: 3, width: max(110, optionsButton.fittingSize.width), height: buttonHeight)
        let contentStart = isEditing ? 0 : optionsButton.frame.maxX + 16
        let availableWidth = max(0, defaults.frame.minX - 16 - contentStart)
        feedback.frame = CGRect(x: contentStart, y: 0, width: availableWidth, height: ceil(feedback.fittingSize.height))
        permissionBanner.frame = CGRect(x: contentStart, y: 3, width: availableWidth, height: buttonHeight)
        let permissionWidth = max(106, permissionButton.fittingSize.width)
        permissionButton.frame = CGRect(x: 0, y: 0, width: permissionWidth, height: buttonHeight)
        permissionLabel.frame = CGRect(x: permissionWidth + 8, y: 1,
                                       width: max(0, availableWidth - permissionWidth - 8), height: 32)
        let permissionHeight = ceil(permissionLabel.cell?.cellSize(forBounds: CGRect(x: 0, y: 0,
            width: permissionLabel.bounds.width, height: 1000)).height ?? 18)
        permissionLabel.frame.size.height = permissionHeight
        if let caption = permissionButton.cell?.titleRect(forBounds: permissionButton.bounds) {
            permissionLabel.frame.origin.y = caption.midY - permissionHeight / 2
        }
        // Rounded NSButton's reported baseline omits its bezel offset. Use the actual
        // title-cell rect; both captions share the same font and native text height.
        if let titleRect = defaults.cell?.titleRect(forBounds: defaults.bounds) {
            let caption = defaults.convert(titleRect, to: footer)
            feedback.frame.origin.y = caption.midY - feedback.bounds.height / 2
        }
    }
    private func cancelRequest() { if isShowingOptions { showHomePage() } else if isEditing { cancelEditing() } else { window?.close() } }
    @discardableResult
    func finishEditing(resumingInput: Bool = true) -> Bool {
        guard isEditing else { return true }
        if editor.bindingDraft == store.shortcutBindings && !ShortcutAction.allCases.contains(where: { editor.hasIssue($0) }) {
            cancelEditing(); return true
        }
        let previous = store.shortcutBindings
        let saved = editor.save()
        let changed = ShortcutAction.settingsOrder.filter { previous[$0] != store.shortcutBindings[$0] }
        if saved { isEditing = false; editingAction = nil; clearEditingFocus(); refreshShortcuts() }
        else if resumingInput { resumeEditingInput() }
        changed.forEach { tiles[$0]?.polishGlass() }
        return saved
    }
    private func resumeEditingInput() {
        if isEditing, editor.recordingAction == nil,
           let action = editingAction {
            editingIndex = min(editingIndex, editor.bindingDraft[action]?.count ?? 0)
            editor.startRecording(action, index: editingIndex)
            window?.makeFirstResponder(tiles[action]?.shortcutButtons[editingIndex])
        }
    }
    @objc private func optionsClicked() { showOptions() }
    @objc private func doneClicked() { _ = finishEditing() }
    @objc private func cancelClicked() { cancelEditing() }
    @objc private func closeClicked() { window?.performClose(nil) }
    private func finishEditingForClick(_ event: NSEvent) -> Bool {
        guard isEditing, window != nil else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        let hit = content.hitTest(content.convert(point, to: content.superview))
        let editors: [NSView] = tiles.values.flatMap { $0.shortcutControls } + [defaults, done, cancelEdit, closeHome, feedback]
        if let hit, editors.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return false }
        // Failed validation keeps the draft and consumes this click, avoiding an accidental launch.
        return !finishEditing()
    }
    @objc private func quitClicked() { if finishEditing() { onQuit() } }
    @objc private func defaultsClicked() {
        let previous = store.shortcutBindings
        allTiles.forEach { $0.stopFeedback() }
        let saved = editor.restoreDefaultsImmediately()
        if saved { isEditing = false; editingAction = nil; clearEditingFocus(); refreshShortcuts() }
        // Registration cleanup can warn after the defaults were successfully committed.
        if editor.defaultsWereCommitted {
            ShortcutAction.settingsOrder.filter { previous[$0] != store.shortcutBindings[$0] }
                .forEach { tiles[$0]?.polishGlass() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finishEditing() }
    func windowWillClose(_ notification: Notification) { cancelEditing(); arch.scenery.setMotionActive(false) }
    func windowDidResignKey(_ notification: Notification) { _ = finishEditing(resumingInput: false); allTiles.forEach { $0.resetInteraction() }; arch.scenery.setMotionActive(false) }
    func windowDidBecomeKey(_ notification: Notification) { refreshShortcuts(); refreshPermissions(); resumeEditingInput(); arch.scenery.setMotionActive(!isShowingOptions) }
    func windowDidChangeOcclusionState(_ notification: Notification) { arch.scenery.setMotionActive(window?.isKeyWindow == true && !isShowingOptions) }
    @objc private func accessibilityChanged() {
        allTiles.forEach { $0.resetInteraction(); $0.stopFeedback() }
        refreshShortcuts()
    }
    private static func handleImage(reset: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            HomeWindowPalette.ink.setStroke(); HomeWindowPalette.wood.setFill()
            let plate = NSBezierPath(roundedRect: CGRect(x: 8, y: 2, width: 5, height: 15), xRadius: 2, yRadius: 2)
            plate.lineWidth = 1.2; plate.fill(); plate.stroke()
            let lever = NSBezierPath(roundedRect: reset ? CGRect(x: 3, y: 7, width: 10, height: 3) : CGRect(x: 10, y: 7, width: 3, height: 11), xRadius: 1.3, yRadius: 1.3)
            lever.fill(); lever.stroke()
            if reset {
                let arrow = NSBezierPath(); arrow.move(to: CGPoint(x: 5, y: 2)); arrow.curve(to: CGPoint(x: 4, y: 17), controlPoint1: CGPoint(x: -1, y: 3), controlPoint2: CGPoint(x: -1, y: 14)); arrow.lineWidth = 1; arrow.stroke()
            }
            return true
        }
    }

    private static func dismissImage(closing: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            HomeWindowPalette.ink.setStroke(); HomeWindowPalette.wood.setFill()
            let path = NSBezierPath(); path.lineWidth = 1.2
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            if closing {
                // A closed pair of wooden sashes echoes the arched Home window.
                let frame = NSBezierPath()
                frame.move(to: CGPoint(x: 3, y: 17))
                frame.line(to: CGPoint(x: 3, y: 8))
                frame.curve(to: CGPoint(x: 17, y: 8), controlPoint1: CGPoint(x: 3, y: 0), controlPoint2: CGPoint(x: 17, y: 0))
                frame.line(to: CGPoint(x: 17, y: 17)); frame.close()
                frame.lineWidth = 1.2; frame.lineJoinStyle = .round
                frame.fill(); frame.stroke()
                path.move(to: CGPoint(x: 10, y: 2)); path.line(to: CGPoint(x: 10, y: 17))
                path.move(to: CGPoint(x: 3, y: 9)); path.line(to: CGPoint(x: 17, y: 9))
                // Short central latch, without a generic close cross.
                path.move(to: CGPoint(x: 8, y: 12)); path.line(to: CGPoint(x: 8, y: 14))
                path.move(to: CGPoint(x: 12, y: 12)); path.line(to: CGPoint(x: 12, y: 14))
            } else {
                // Same backplate and wooden lever as Done; the small return arc
                // distinguishes discarding a draft from restoring all defaults.
                let plate = NSBezierPath(roundedRect: CGRect(x: 11, y: 2, width: 5, height: 15), xRadius: 2, yRadius: 2)
                plate.lineWidth = 1.2; plate.fill(); plate.stroke()
                let lever = NSBezierPath(roundedRect: CGRect(x: 7, y: 7, width: 8, height: 3), xRadius: 1.3, yRadius: 1.3)
                lever.lineWidth = 1.2; lever.fill(); lever.stroke()
                path.move(to: CGPoint(x: 7, y: 16))
                path.curve(to: CGPoint(x: 4, y: 4), controlPoint1: CGPoint(x: 1, y: 15), controlPoint2: CGPoint(x: 0, y: 8))
                path.line(to: CGPoint(x: 4, y: 7))
                path.move(to: CGPoint(x: 4, y: 4)); path.line(to: CGPoint(x: 1, y: 4))
            }
            path.stroke(); return true
        }
    }
}
