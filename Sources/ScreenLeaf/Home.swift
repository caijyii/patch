// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

private enum HomeWindowPalette {
    static let ink = NSColor(srgbRed: 0.21, green: 0.28, blue: 0.25, alpha: 1)
    static let muted = NSColor(srgbRed: 0.40, green: 0.46, blue: 0.42, alpha: 1)
    static let wood = NSColor(srgbRed: 0.97, green: 0.98, blue: 0.97, alpha: 1)
    static let edge = NSColor(srgbRed: 0.58, green: 0.64, blue: 0.60, alpha: 1)
    static let shade = NSColor(srgbRed: 0.86, green: 0.89, blue: 0.87, alpha: 1)
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
private class HomeFlippedView: NSView { override var isFlipped: Bool { true } }

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
    let surface = CALayer()
    let fixedFrame = CALayer()
    private let glassStage = HomeFlippedView()
    private let moving = HomeFlippedView()
    private let polish = CAGradientLayer()
    private let fogMask = CALayer()
    private let latch = CALayer()
    private let shortcutFill = CALayer()
    private var pointerOverShortcut = false
    private var shortcutHasError = false
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
    private let launch: HomeActionButton
    private let keycap: HomeActionButton

    init(action: ShortcutAction? = nil) {
        let symbols: [ShortcutAction: String] = [.screenshot: "viewfinder", .scroll: "arrow.down.document", .text: "text.viewfinder", .pin: "pin", .record: "video", .subject: "person.crop.rectangle", .togglePins: "rectangle.on.rectangle"]
        launch = HomeActionButton(frame: .zero)
        keycap = HomeActionButton(frame: .zero)
        launch.cell = HomeLaunchCell()
        launch.target = launch; launch.action = #selector(HomeActionButton.invoke)
        launch.title = action?.title ?? "退出"
        launchButton = launch; shortcutButton = keycap
        super.init(frame: .zero)
        wantsLayer = true; glassStage.wantsLayer = true; moving.wantsLayer = true
        addSubview(glassStage); glassStage.addSubview(moving)
        glassStage.layer?.masksToBounds = true
        // The stationary frame stays above the sash; no projected glass or shadow can cover it.
        layer?.masksToBounds = true
        fixedFrame.borderColor = HomeWindowPalette.edge.withAlphaComponent(0.6).cgColor
        fixedFrame.borderWidth = 1; fixedFrame.zPosition = 200
        layer?.addSublayer(fixedFrame)
        surface.borderColor = HomeWindowPalette.edge.withAlphaComponent(0.25).cgColor
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
        shortcutFill.backgroundColor = NSColor(srgbRed: 0.80, green: 0.86, blue: 0.82, alpha: 0.65).cgColor
        shortcutFill.cornerRadius = 6; shortcutFill.opacity = 0
        shortcutFill.zPosition = 99
        layer?.addSublayer(shortcutFill)
        addSubview(launch); addSubview(keycap)
        // Keep controls in a separate, frontmost plane, beyond the sash's positive-Z lift.
        for button in [launch, keycap] { button.wantsLayer = true; button.layer?.zPosition = 100 }
        launch.image = NSImage(systemSymbolName: action.flatMap { symbols[$0] } ?? "power", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        launch.imagePosition = .imageAbove
        launch.font = .systemFont(ofSize: 14, weight: .medium)
        launch.contentTintColor = HomeWindowPalette.ink
        keycap.font = .systemFont(ofSize: 12, weight: .medium)
        keycap.contentTintColor = HomeWindowPalette.muted
        keycap.lineBreakMode = .byTruncatingTail
        for button in [launch, keycap] { button.isBordered = false; button.bezelStyle = .regularSquare }
        launch.identifier = NSUserInterfaceItemIdentifier("home.launch.\(action?.rawValue ?? "quit")")
        keycap.identifier = NSUserInterfaceItemIdentifier("home.shortcut.\(action?.rawValue ?? "quit")")
        if action == .pin { launch.toolTip = "贴出剪贴板中的图片或文字" }
        launch.setAccessibilityLabel(launch.title)
        keycap.setAccessibilityLabel(action == nil ? "退出快捷键，固定为 ⌘Q" : "修改\(launch.title)快捷键")
        launch.onPress = { [weak self] in self?.updateSurface() }
        launch.onClick = { [weak self] in self?.openSash(); self?.onLaunch?() }
        keycap.onClick = { [weak self] in self?.onEdit?() }
        keycap.toolTip = action == nil ? "退出当前应用（⌘Q）" : "修改快捷键"
        keycap.isEnabled = action != nil
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
        (launch.cell as? HomeLaunchCell)?.contentRect = backingAlignedRect(CGRect(x: 8, y: center - 47, width: bounds.width - 16, height: 73), options: .alignAllEdgesNearest)
        let keyWidth = min(bounds.width - 20, max(40, keycap.intrinsicContentSize.width + 16))
        keycap.frame = backingAlignedRect(CGRect(x: (bounds.width - keyWidth) / 2, y: center + 28, width: keyWidth, height: 28), options: .alignAllEdgesNearest)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shortcutFill.frame = keycap.frame
        CATransaction.commit()
    }
    func configure(shortcut: String, editing: Bool, launchesEnabled: Bool, hasError: Bool) {
        keycap.title = shortcut; keycap.toolTip = shortcut
        shortcutHasError = hasError
        needsLayout = true
        launch.isEnabled = launchesEnabled; isEditingShortcut = editing
        keycap.setAccessibilityValue(editing ? "\(shortcut)，正在编辑" : shortcut)
        updateSurface()
    }
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
        pointerOverShortcut = keycap.frame.contains(convert(event.locationInWindow, from: nil))
        updateSurface()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false; pointerOverShortcut = false; updateSurface() }
    func resetInteraction() { isHovered = false; pointerOverShortcut = false; launch.highlight(false); keycap.highlight(false); moving.layer?.removeAnimation(forKey: "open"); updateSurface() }
    func stopFeedback() { fogMask.removeAllAnimations(); polish.removeAllAnimations() }
    private func updateSurface() {
        isShortcutHovered = isHovered && pointerOverShortcut && keycap.isEnabled
        isLaunchHovered = isHovered && !pointerOverShortcut && launch.isEnabled
        let emphasized = isEditingShortcut || isHovered || launch.isHighlighted
        launch.font = .systemFont(ofSize: 14, weight: .medium)
        launch.contentTintColor = isLaunchHovered ? NSColor(srgbRed: 0.12, green: 0.21, blue: 0.17, alpha: 1) : HomeWindowPalette.ink
        keycap.contentTintColor = shortcutHasError ? .systemOrange : isShortcutHovered ? HomeWindowPalette.ink : HomeWindowPalette.muted
        let fillOpacity: Float = isShortcutHovered ? 1 : 0
        if shortcutFill.opacity != fillOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shortcutFill.presentation()?.opacity ?? shortcutFill.opacity
            fade.toValue = fillOpacity
            fade.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            shortcutFill.add(fade, forKey: "hover")
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shortcutFill.opacity = fillOpacity
        surface.backgroundColor = NSColor.white.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : emphasized ? 0.48 : 0.64).cgColor
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
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
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
        let width = (bounds.width - 33) / 4
        let vertical = (1...3).map { CGRect(x: CGFloat($0) * width + CGFloat($0 - 1) * 11, y: 0, width: 11, height: bounds.height) }
        for rect in vertical + [CGRect(x: 0, y: 205, width: bounds.width, height: 11)] {
            HomeWindowPalette.wood.setFill(); rect.fill()
            HomeWindowPalette.edge.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            NSColor.white.setFill(); CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width > 11 ? rect.width - 2 : 2, height: rect.height > 11 ? rect.height - 2 : 2).fill()
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
        let sill = CGRect(x: 1, y: 402, width: bounds.width - 2, height: 13)
        HomeWindowPalette.wood.setFill(); sill.fill()
        HomeWindowPalette.edge.setStroke(); NSBezierPath(roundedRect: sill, xRadius: 2, yRadius: 2).stroke()
        HomeWindowPalette.shade.setFill(); CGRect(x: 2, y: 411, width: bounds.width - 4, height: 3).fill()
    }
}

@MainActor private final class HomeContentView: HomeFlippedView {
    var onLayout: (() -> Void)?
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.white.setFill(); bounds.fill() }
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
final class HomeWindowController: NSWindowController, NSWindowDelegate {
    let editor: ShortcutEditorSession
    private let store: PreferencesStore
    private(set) var tiles: [ShortcutAction: HomeFeatureTile] = [:]
    private(set) var isEditing = false
    private var editingAction: ShortcutAction?
    private let onLaunch: (ShortcutAction) -> Void
    private let content = HomeContentView()
    private let arch = HomeArchView()
    private let footer = HomeFlippedView()
    private let feedback = NSTextField(labelWithString: "")
    private let defaults = NSButton(title: "恢复默认", target: nil, action: nil)
    private let done = NSButton(title: "保存", target: nil, action: nil)
    private let cancelEdit = NSButton(title: "取消", target: nil, action: nil)
    private let closeHome = NSButton(title: "关闭", target: nil, action: nil)
    private var isRefreshing = false
    let quitTile = HomeFeatureTile()
    var allTiles: [HomeFeatureTile] { ShortcutAction.settingsOrder.compactMap { tiles[$0] } + [quitTile] }
    private let pinState: () -> (hasPins: Bool, hidden: Bool)
    private let onQuit: () -> Void

    init(hotKeys: HotKeys, store: PreferencesStore, onSave: @escaping () -> Void, onLaunch: @escaping (ShortcutAction) -> Void,
         pinState: @escaping () -> (hasPins: Bool, hidden: Bool) = { (false, false) },
         onQuit: @escaping () -> Void = {}) {
        editor = ShortcutEditorSession(hotKeys: hotKeys, store: store, keepsRecordingUntilFinished: true, onSave: onSave)
        self.store = store; self.onLaunch = onLaunch; self.pinState = pinState; self.onQuit = onQuit
        let window = ShortcutSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 648, height: 536), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("patch.home")
        window.title = "Patch"; window.titlebarAppearsTransparent = true
        window.level = .normal; window.isReleasedWhenClosed = false; window.isOpaque = true
        window.backgroundColor = .white; window.appearance = NSAppearance(named: .aqua)
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
        content.addSubview(arch)
        for action in ShortcutAction.settingsOrder {
            let tile = HomeFeatureTile(action: action)
            tile.onLaunch = { [weak self] in
                guard let self, !self.isEditing else { return }
                self.editor.stopRecording(); self.onLaunch(action); self.refreshShortcuts()
            }
            tile.onEdit = { [weak self] in self?.beginEditing(action) }
            tiles[action] = tile
        }
        quitTile.onLaunch = { [weak self] in self?.quitClicked() }
        arch.addTiles(allTiles)
        content.addSubview(footer)
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = HomeWindowPalette.muted
        feedback.isSelectable = true
        feedback.identifier = NSUserInterfaceItemIdentifier("home.shortcut-status")
        footer.addSubview(feedback)
        for button in [defaults, done, cancelEdit, closeHome] {
            button.bezelStyle = .rounded; button.imagePosition = .imageLeading; button.target = self
            button.font = .systemFont(ofSize: 12); button.contentTintColor = HomeWindowPalette.ink
            footer.addSubview(button)
        }
        defaults.image = Self.handleImage(reset: true); done.image = Self.handleImage(reset: false)
        cancelEdit.image = Self.dismissImage(closing: false); closeHome.image = Self.dismissImage(closing: true)
        defaults.action = #selector(defaultsClicked); done.action = #selector(doneClicked)
        cancelEdit.action = #selector(cancelClicked); closeHome.action = #selector(closeClicked)
        content.onLayout = { [weak self] in self?.layoutContent() }
        editor.onUpdate = { [weak self] in self?.refreshShortcuts() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshShortcuts(); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true && !isEditing { editor.reset() }
        allTiles.forEach { $0.resetInteraction() }
        window?.deminiaturize(nil); super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        arch.scenery.setMotionActive(true)
    }
    func beginEditing(_ action: ShortcutAction? = nil) {
        if !isEditing { isEditing = true; editor.reset() }
        tiles.values.forEach { $0.stopFeedback() }
        if let action {
            editingAction = action; editor.startRecording(action)
            window?.makeFirstResponder(tiles[action]?.shortcutButton)
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
        let previousFeedback = feedback.stringValue
        for action in ShortcutAction.settingsOrder {
            let recording = editor.recordingAction == action
            let title = recording && editor.recordingTitle(action).contains("录入中") ? "按组合键" : editor.recordingTitle(action)
            tiles[action]?.configure(shortcut: title, editing: isEditing && editingAction == action, launchesEnabled: !isEditing, hasError: editor.hasIssue(action))
        }
        let state = pinState()
        tiles[.togglePins]?.launchButton.title = state.hidden ? "显示全部贴图" : "隐藏全部贴图"
        tiles[.togglePins]?.launchButton.isEnabled = state.hasPins && !isEditing
        quitTile.configure(shortcut: "⌘Q", editing: false, launchesEnabled: !isEditing, hasError: false)
        let issues = ShortcutAction.settingsOrder.filter { editor.hasIssue($0) }
        let issue = editingAction.flatMap { issues.contains($0) ? $0 : nil } ?? issues.first
        if let issue { feedback.stringValue = editor.conciseMessage(issue); feedback.textColor = .systemOrange }
        else {
            feedback.stringValue = ""
            feedback.textColor = HomeWindowPalette.muted
        }
        footer.isHidden = false
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
        arch.frame = CGRect(x: (content.bounds.width - 562) / 2, y: 54, width: 562, height: 420)
        arch.layoutSubtreeIfNeeded()
        let width = (arch.aperture.bounds.width - 33) / 4
        for (index, tile) in allTiles.enumerated() {
            tile.topInset = index < 4 ? 55 : 0
            tile.frame = CGRect(x: CGFloat(index % 4) * (width + 11), y: index < 4 ? 0 : 216, width: width, height: index < 4 ? 205 : 156)
        }
        footer.frame = CGRect(x: 24, y: 484, width: content.bounds.width - 48, height: 44)
        defaults.frame = CGRect(x: 0, y: 3, width: 124, height: 34)
        done.frame = CGRect(x: footer.bounds.width - 84, y: 3, width: 84, height: 34)
        closeHome.frame = done.frame
        cancelEdit.frame = CGRect(x: done.frame.minX - 92, y: 3, width: 84, height: 34)
        feedback.frame = CGRect(x: 140, y: 0, width: footer.bounds.width - 332, height: ceil(feedback.fittingSize.height))
        // Rounded NSButton's reported baseline omits its bezel offset. Use the actual
        // title-cell rect; both captions share the same font and native text height.
        if let titleRect = defaults.cell?.titleRect(forBounds: defaults.bounds) {
            let caption = defaults.convert(titleRect, to: footer)
            feedback.frame.origin.y = caption.midY - feedback.bounds.height / 2
        }
    }
    private func cancelRequest() { if isEditing { cancelEditing() } else { window?.close() } }
    @discardableResult
    func finishEditing(resumingInput: Bool = true) -> Bool {
        guard isEditing else { return true }
        if editor.draft == store.shortcuts && !ShortcutAction.allCases.contains(where: { editor.hasIssue($0) }) {
            cancelEditing(); return true
        }
        let previous = store.shortcuts
        let saved = editor.save()
        let changed = ShortcutAction.settingsOrder.filter { previous[$0] != store.shortcuts[$0] }
        if saved { isEditing = false; editingAction = nil; clearEditingFocus(); refreshShortcuts() }
        else if resumingInput { resumeEditingInput() }
        changed.forEach { tiles[$0]?.polishGlass() }
        return saved
    }
    private func resumeEditingInput() {
        if isEditing, editor.recordingAction == nil,
           let action = editingAction {
            editor.startRecording(action)
            window?.makeFirstResponder(tiles[action]?.shortcutButton)
        }
    }
    @objc private func doneClicked() { _ = finishEditing() }
    @objc private func cancelClicked() { cancelEditing() }
    @objc private func closeClicked() { window?.performClose(nil) }
    private func finishEditingForClick(_ event: NSEvent) -> Bool {
        guard isEditing, window != nil else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        let hit = content.hitTest(content.convert(point, to: content.superview))
        let editors: [NSView] = tiles.values.map { $0.shortcutButton } + [defaults, done, cancelEdit, closeHome, feedback]
        if let hit, editors.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return false }
        // Failed validation keeps the draft and consumes this click, avoiding an accidental launch.
        return !finishEditing()
    }
    @objc private func quitClicked() { if finishEditing() { onQuit() } }
    @objc private func defaultsClicked() {
        let previous = store.shortcuts
        allTiles.forEach { $0.stopFeedback() }
        let saved = editor.restoreDefaultsImmediately()
        if saved { isEditing = false; editingAction = nil; clearEditingFocus(); refreshShortcuts() }
        // Registration cleanup can warn after the defaults were successfully committed.
        if editor.defaultsWereCommitted {
            ShortcutAction.settingsOrder.filter { previous[$0] != store.shortcuts[$0] }
                .forEach { tiles[$0]?.polishGlass() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finishEditing() }
    func windowWillClose(_ notification: Notification) { cancelEditing(); arch.scenery.setMotionActive(false) }
    func windowDidResignKey(_ notification: Notification) { _ = finishEditing(resumingInput: false); allTiles.forEach { $0.resetInteraction() }; arch.scenery.setMotionActive(false) }
    func windowDidBecomeKey(_ notification: Notification) { refreshShortcuts(); resumeEditingInput(); arch.scenery.setMotionActive(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) { arch.scenery.setMotionActive(window?.isKeyWindow == true) }
    @objc private func accessibilityChanged() {
        allTiles.forEach { $0.resetInteraction(); $0.stopFeedback() }
        refreshShortcuts()
    }
    private static func handleImage(reset: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            HomeWindowPalette.muted.setStroke(); HomeWindowPalette.wood.setFill()
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
            HomeWindowPalette.muted.setStroke(); HomeWindowPalette.wood.setFill()
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
