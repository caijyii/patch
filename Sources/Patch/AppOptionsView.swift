// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

enum HomeFooterLayout {
    static let buttonHeight: CGFloat = 34
    static let bottomInset: CGFloat = 15
    static let horizontalInset: CGFloat = 24
    static func buttonY(in bounds: CGRect) -> CGFloat { bounds.maxY - bottomInset - buttonHeight }
}

/// Uses native button tracking, keyboard and accessibility toggle semantics.
@MainActor
final class SettingsToggle: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.switch)
        title = ""; isBordered = false; focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { CGSize(width: 38, height: 24) }
    override func sizeToFit() { setFrameSize(intrinsicContentSize) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: SettingsControlSurface.cornerRadius, yRadius: SettingsControlSurface.cornerRadius).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: 2)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let on = AppTheme.color(NSColor(srgbRed: 0.39, green: 0.51, blue: 0.43, alpha: 1),
                                NSColor(srgbRed: 0.46, green: 0.59, blue: 0.49, alpha: 1))
        SettingsControlSurface.fill(in: effectiveAppearance, pressed: isHighlighted).withAlphaComponent(
            (isHighlighted ? 0.16 : 0.08) * alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: SettingsControlSurface.cornerRadius,
                     yRadius: SettingsControlSurface.cornerRadius).fill()
        let diameter = track.height - 4
        let x = state == .on ? track.maxX - diameter - 2 : track.minX + 2
        let thumbRect = CGRect(x: x, y: track.minY + 2, width: diameter, height: diameter)
        let thumb = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
        (state == .on ? on : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).withAlphaComponent(
            (state == .on ? 1 : 0.45) * alpha).setFill()
        thumb.fill()
        if state == .on {
            NSColor.white.withAlphaComponent(alpha).setStroke()
            let check = NSBezierPath(); check.lineWidth = 1.4; check.lineCapStyle = .round; check.lineJoinStyle = .round
            check.move(to: CGPoint(x: thumbRect.minX + 4, y: thumbRect.midY))
            check.line(to: CGPoint(x: thumbRect.minX + 7, y: isFlipped ? thumbRect.maxY - 4 : thumbRect.minY + 4))
            check.line(to: CGPoint(x: thumbRect.maxX - 3, y: isFlipped ? thumbRect.minY + 4 : thumbRect.maxY - 4)); check.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// The secondary page lives in the Home window; it never creates another settings window.
@MainActor
final class AppOptionsView: NSView {
    /// Excludes the Home window's titlebar/top inset; the parent sizes this page on entry.
    static let preferredContentHeight: CGFloat = 460
    let appearanceControl = SettingsSelector(frame: .zero, pullsDown: true)
    let languageControl = SettingsSelector(frame: .zero, pullsDown: true)
    let countControl = SettingsSelector(frame: .zero, pullsDown: true)
    let capturePagesControl = SettingsSelector(frame: .zero, pullsDown: true)
    private let capturePagesLabel = NSTextField(labelWithString: L("截图时隐藏 patch 页面"))
    let hideRecordingPinsControl = SettingsToggle(frame: .zero)
    private let hideRecordingPinsLabel = NSTextField(labelWithString: L("录屏时隐藏桌面贴图"))
    let hidePinsControl = SettingsToggle(frame: .zero)
    private let hidePinsLabel = NSTextField(labelWithString: L("截图时隐藏桌面贴图"))
    private let preferences: PreferencesStore
    private let onBack: () -> Void
    private let onChange: () -> Void
    private let onRequestPermission: () -> Void
    private let back = NSButton(title: L("返回首页"), target: nil, action: nil)
    private let close = NSButton(title: L("关闭"), target: nil, action: nil)
    private let general = NSTextField(labelWithString: L("通用"))
    private let appearanceLabel = NSTextField(labelWithString: L("外观"))
    private let languageLabel = NSTextField(labelWithString: L("语言"))
    private let countLabel = NSTextField(labelWithString: L("批量贴出数量"))
    private let languageHint = NSTextField(labelWithString: L("重启后生效"))
    private let permissions = NSTextField(labelWithString: L("权限"))
    private let permissionLabel = NSTextField(labelWithString: L("屏幕录制"))
    private let permissionState = NSTextField(labelWithString: "")
    private let authorize = NSButton(title: L("去授权"), target: nil, action: nil)
    private let permissionHint = NSTextField(wrappingLabelWithString: L("用于截图、提取屏幕文字和录屏。"))

    override var isFlipped: Bool { true }
    init(preferences: PreferencesStore, onBack: @escaping () -> Void,
         onChange: @escaping () -> Void, onRequestPermission: @escaping () -> Void) {
        self.preferences = preferences; self.onBack = onBack; self.onChange = onChange
        self.onRequestPermission = onRequestPermission
        super.init(frame: .zero)
        for control in [back, close, authorize] {
            control.bezelStyle = .rounded; control.font = .systemFont(ofSize: 12)
            control.imagePosition = .imageLeading; control.contentTintColor = HomeWindowPalette.ink
            control.target = self
        }
        back.image = WindowGlyph.image(.back); back.action = #selector(goBack)
        close.image = WindowGlyph.image(.close); close.action = #selector(closePage)
        close.identifier = NSUserInterfaceItemIdentifier("options.close")
        authorize.image = nil; authorize.imagePosition = .noImage; authorize.action = #selector(requestPermission)
        authorize.identifier = NSUserInterfaceItemIdentifier("options.authorize")
        for control in [appearanceControl, languageControl, countControl, capturePagesControl] {
            // A pull-down anchors its menu to the edge; a pop-up aligns the selected
            // item over the button. AppKit still handles keyboard input and screen fit.
            control.pullsDown = true
            control.usesItemFromMenu = false
            control.preferredEdge = control.isFlipped ? .maxY : .minY
        }
        appearanceControl.addItems(withTitles: AppAppearancePreference.allCases.map(\.title))
        appearanceControl.target = self; appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.identifier = NSUserInterfaceItemIdentifier("options.appearance")
        languageControl.addItems(withTitles: AppLanguagePreference.allCases.map(\.title))
        languageControl.target = self; languageControl.action = #selector(languageChanged)
        languageControl.identifier = NSUserInterfaceItemIdentifier("options.language")
        countControl.addItems(withTitles: (1...20).map { $0 == 1 ? L("1 条") : LF("%d 条", $0) })
        countControl.target = self; countControl.action = #selector(countChanged)
        countControl.identifier = NSUserInterfaceItemIdentifier("options.pin-recent-count")
        capturePagesControl.addItems(withTitles: CapturePageVisibilityPreference.allCases.map(\.title))
        capturePagesControl.target = self; capturePagesControl.action = #selector(capturePagesChanged)
        capturePagesControl.identifier = NSUserInterfaceItemIdentifier("options.capture-pages")
        capturePagesLabel.identifier = NSUserInterfaceItemIdentifier("options.capture-pages-label")
        capturePagesControl.setAccessibilityLabel(capturePagesLabel.stringValue)
        capturePagesControl.toolTip = L("截图结束后自动恢复页面；桌面贴图由独立开关控制。")
        hideRecordingPinsControl.target = self; hideRecordingPinsControl.action = #selector(hideRecordingPinsChanged)
        hideRecordingPinsControl.identifier = NSUserInterfaceItemIdentifier("options.hide-recording-pins")
        hideRecordingPinsLabel.identifier = NSUserInterfaceItemIdentifier("options.hide-recording-pins-label")
        hideRecordingPinsControl.setAccessibilityLabel(hideRecordingPinsLabel.stringValue)
        hidePinsControl.target = self; hidePinsControl.action = #selector(hidePinsChanged)
        hidePinsControl.identifier = NSUserInterfaceItemIdentifier("options.hide-pins")
        hidePinsLabel.identifier = NSUserInterfaceItemIdentifier("options.hide-pins-label")
        hidePinsControl.setAccessibilityLabel(hidePinsLabel.stringValue)
        appearanceControl.setAccessibilityLabel(appearanceLabel.stringValue)
        languageControl.setAccessibilityLabel(languageLabel.stringValue)
        countControl.setAccessibilityLabel(countLabel.stringValue)
        appearanceLabel.identifier = NSUserInterfaceItemIdentifier("options.appearance-label")
        languageLabel.identifier = NSUserInterfaceItemIdentifier("options.language-label")
        countLabel.identifier = NSUserInterfaceItemIdentifier("options.count-label")
        for label in [general, permissions] {
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.textColor = HomeWindowPalette.muted
        }
        for label in [appearanceLabel, languageLabel, countLabel, capturePagesLabel, hidePinsLabel, hideRecordingPinsLabel, permissionLabel, permissionState] { label.font = .systemFont(ofSize: 13) }
        permissionState.textColor = HomeWindowPalette.muted
        permissionState.alignment = .left
        permissionLabel.identifier = NSUserInterfaceItemIdentifier("options.permission-label")
        permissionState.identifier = NSUserInterfaceItemIdentifier("options.permission-state")
        permissionHint.identifier = NSUserInterfaceItemIdentifier("options.permission-hint")
        for label in [permissionHint, languageHint, permissionState] {
            label.font = .systemFont(ofSize: 12); label.textColor = HomeWindowPalette.muted
        }
        languageHint.identifier = NSUserInterfaceItemIdentifier("options.language-restart-hint")
        languageHint.textColor = .systemOrange
        for view in [back, close, general, appearanceLabel, appearanceControl, languageLabel, languageControl, languageHint, countLabel, countControl, capturePagesLabel, capturePagesControl, hidePinsLabel, hidePinsControl, hideRecordingPinsLabel, hideRecordingPinsControl, permissions,
                     permissionLabel, permissionState, authorize, permissionHint] { addSubview(view) }
        refreshAppearanceSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshAppearanceSelection() {
        appearanceControl.selectItem(at: AppAppearancePreference.allCases.firstIndex(of: preferences.appearancePreference) ?? 0)
        languageControl.selectItem(at: AppLanguagePreference.allCases.firstIndex(of: preferences.languagePreference) ?? 0)
        countControl.selectItem(at: preferences.pinRecentCount - 1)
        capturePagesControl.selectItem(at: CapturePageVisibilityPreference.allCases.firstIndex(of: preferences.capturePageVisibility) ?? 0)
        hideRecordingPinsControl.state = preferences.hidePinsWhenRecording ? .on : .off
        hidePinsControl.state = preferences.hidePinsWhenCapturing ? .on : .off
        languageHint.isHidden = AppLocalization.resolvesToEnglish(preferences.languagePreference) == AppLocalization.isEnglish
        for control in [appearanceControl, languageControl, countControl, capturePagesControl] {
            // AppKit hides the first item when adding pull-down entries even with
            // a separate button title. All entries here are actual setting values.
            control.item(at: 0)?.isHidden = false
            control.title = control.selectedItem?.title ?? ""
            control.setAccessibilityValue(control.title)
            for item in control.itemArray { item.state = item === control.selectedItem ? .on : .off }
        }
    }
    func refreshPermissions(granted: Bool) {
        permissionState.stringValue = granted ? L("已授权") : L("未授权")
        permissionState.textColor = granted ? HomeWindowPalette.muted : .systemOrange
        authorize.isHidden = granted
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let formInset: CGFloat = 24
        let right = bounds.width - formInset, controlWidth: CGFloat = 172
        let closeWidth = max(84, close.fittingSize.width), backWidth = max(112, back.fittingSize.width)
        close.frame = CGRect(x: bounds.maxX - closeWidth, y: HomeFooterLayout.buttonY(in: bounds), width: closeWidth, height: HomeFooterLayout.buttonHeight)
        back.frame = CGRect(x: close.frame.minX - 12 - backWidth, y: close.frame.minY, width: backWidth, height: HomeFooterLayout.buttonHeight)
        general.frame = CGRect(x: formInset, y: 8, width: right - formInset, height: 18)
        appearanceLabel.frame = CGRect(x: formInset, y: 46, width: 230, height: 22)
        appearanceControl.frame = CGRect(x: right - controlWidth, y: 41, width: controlWidth, height: 30)
        languageLabel.frame = CGRect(x: formInset, y: 90, width: ceil(languageLabel.fittingSize.width), height: 22)
        languageControl.frame = CGRect(x: right - controlWidth, y: 85, width: controlWidth, height: 30)
        layoutStatus(languageHint, beside: languageLabel, trailingEdge: languageControl.frame.minX - 20)
        countLabel.frame = CGRect(x: formInset, y: 134, width: 230, height: 22)
        countControl.frame = CGRect(x: right - controlWidth, y: 129, width: controlWidth, height: 30)
        capturePagesLabel.frame = CGRect(x: formInset, y: 178, width: right - controlWidth - formInset - 20, height: 22)
        capturePagesControl.frame = CGRect(x: right - controlWidth, y: 173, width: controlWidth, height: 30)
        hidePinsLabel.frame = CGRect(x: formInset, y: 222, width: right - controlWidth - formInset - 20, height: 22)
        hidePinsControl.sizeToFit()
        hidePinsControl.setFrameOrigin(CGPoint(x: right - hidePinsControl.frame.width, y: 232 - hidePinsControl.frame.height / 2))
        hideRecordingPinsLabel.frame = CGRect(x: formInset, y: 266, width: right - controlWidth - formInset - 20, height: 22)
        hideRecordingPinsControl.sizeToFit()
        hideRecordingPinsControl.setFrameOrigin(CGPoint(x: right - hideRecordingPinsControl.frame.width, y: 276 - hideRecordingPinsControl.frame.height / 2))
        permissions.frame = CGRect(x: formInset, y: 320, width: right - formInset, height: 18)
        permissionLabel.frame = CGRect(x: formInset, y: 352, width: ceil(permissionLabel.fittingSize.width), height: 22)
        let authorizeWidth = max(84, ceil(authorize.fittingSize.width))
        authorize.frame = CGRect(x: right - authorizeWidth, y: 347, width: authorizeWidth, height: 30)
        layoutStatus(permissionState, beside: permissionLabel, trailingEdge: authorize.frame.minX - 20)
        permissionHint.frame = CGRect(x: formInset, y: 378, width: right - formInset, height: 18)
    }
    private func layoutStatus(_ status: NSTextField, beside label: NSTextField, trailingEdge: CGFloat) {
        status.frame = CGRect(x: label.frame.maxX + 12, y: label.frame.minY,
            width: max(0, trailingEdge - label.frame.maxX - 12), height: 22)
        status.frame.origin.y += label.firstBaselineOffsetFromTop - status.firstBaselineOffsetFromTop
    }
    override func draw(_ dirtyRect: NSRect) {
        HomeWindowPalette.edge.withAlphaComponent(0.22).setFill()
        CGRect(x: 24, y: 306, width: bounds.width - 48, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func goBack() { onBack() }
    @objc private func closePage() { window?.performClose(nil) }
    @objc private func appearanceChanged() {
        let index = appearanceControl.indexOfSelectedItem
        guard AppAppearancePreference.allCases.indices.contains(index) else { return }
        preferences.setAppearancePreference(AppAppearancePreference.allCases[index]); refreshAppearanceSelection(); onChange()
    }
    @objc private func languageChanged() {
        let index = languageControl.indexOfSelectedItem
        guard AppLanguagePreference.allCases.indices.contains(index) else { return }
        preferences.setLanguagePreference(AppLanguagePreference.allCases[index])
        refreshAppearanceSelection()
    }
    @objc private func countChanged() {
        guard (0..<20).contains(countControl.indexOfSelectedItem) else { return }
        guard preferences.pinRecentCount != countControl.indexOfSelectedItem + 1 else { return }
        preferences.setPinRecentCount(countControl.indexOfSelectedItem + 1); refreshAppearanceSelection(); onChange()
    }
    @objc private func capturePagesChanged() {
        let index = capturePagesControl.indexOfSelectedItem
        guard CapturePageVisibilityPreference.allCases.indices.contains(index) else { return }
        preferences.setCapturePageVisibility(CapturePageVisibilityPreference.allCases[index])
        refreshAppearanceSelection(); onChange()
    }
    @objc private func hideRecordingPinsChanged() {
        preferences.setHidePinsWhenRecording(hideRecordingPinsControl.state == .on)
        refreshAppearanceSelection(); onChange()
    }
    @objc private func hidePinsChanged() {
        preferences.setHidePinsWhenCapturing(hidePinsControl.state == .on)
        refreshAppearanceSelection(); onChange()
    }
    @objc private func requestPermission() { onRequestPermission() }
}

/// Small original line drawings using the same arched panes and latches as Home.
@MainActor
enum WindowGlyph {
    enum Kind { case records, batch, settings, authorize, back, close }
    static func image(_ kind: Kind) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            HomeWindowPalette.ink.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.2
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            func arch(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
                path.move(to: CGPoint(x: x, y: y + height)); path.line(to: CGPoint(x: x, y: y + width / 2))
                path.curve(to: CGPoint(x: x + width, y: y + width / 2),
                    controlPoint1: CGPoint(x: x, y: y - width / 6), controlPoint2: CGPoint(x: x + width, y: y - width / 6))
                path.line(to: CGPoint(x: x + width, y: y + height)); path.close()
            }
            switch kind {
            case .records:
                arch(x: 2, y: 1, width: 12, height: 14)
                path.stroke(); path.removeAllPoints()
                arch(x: 6, y: 5, width: 12, height: 13)
                path.move(to: CGPoint(x: 12, y: 6)); path.line(to: CGPoint(x: 12, y: 18))
                path.move(to: CGPoint(x: 6, y: 12)); path.line(to: CGPoint(x: 18, y: 12))
            case .batch:
                arch(x: 1, y: 1, width: 9, height: 12)
                arch(x: 5, y: 4, width: 9, height: 12)
                arch(x: 9, y: 7, width: 9, height: 12)
                path.move(to: CGPoint(x: 13.5, y: 9)); path.line(to: CGPoint(x: 13.5, y: 18))
                path.move(to: CGPoint(x: 10, y: 14)); path.line(to: CGPoint(x: 17, y: 14))
            case .close:
                arch(x: 3, y: 1, width: 14, height: 17)
                path.move(to: CGPoint(x: 10, y: 2)); path.line(to: CGPoint(x: 10, y: 18))
                path.move(to: CGPoint(x: 3, y: 9)); path.line(to: CGPoint(x: 17, y: 9))
                path.move(to: CGPoint(x: 8, y: 12)); path.line(to: CGPoint(x: 8, y: 15))
                path.move(to: CGPoint(x: 12, y: 12)); path.line(to: CGPoint(x: 12, y: 15))
            case .settings:
                arch(x: 3, y: 1, width: 14, height: 17)
                path.move(to: CGPoint(x: 10, y: 2)); path.line(to: CGPoint(x: 10, y: 18))
                path.move(to: CGPoint(x: 3, y: 9)); path.line(to: CGPoint(x: 17, y: 9))
                let plate = NSBezierPath(roundedRect: CGRect(x: 8, y: 11, width: 4, height: 6), xRadius: 1, yRadius: 1)
                plate.lineWidth = 1.2; plate.stroke()
                path.move(to: CGPoint(x: 6, y: 13)); path.line(to: CGPoint(x: 11, y: 13))
            case .authorize:
                arch(x: 3, y: 1, width: 14, height: 17)
                path.move(to: CGPoint(x: 10, y: 3)); path.line(to: CGPoint(x: 10, y: 18))
                path.move(to: CGPoint(x: 4, y: 17)); path.line(to: CGPoint(x: 7, y: 14))
                path.line(to: CGPoint(x: 7, y: 6)); path.line(to: CGPoint(x: 4, y: 8))
                path.move(to: CGPoint(x: 12, y: 10)); path.line(to: CGPoint(x: 14, y: 12)); path.line(to: CGPoint(x: 18, y: 7))
            case .back:
                arch(x: 7, y: 1, width: 11, height: 17)
                path.move(to: CGPoint(x: 1, y: 11)); path.line(to: CGPoint(x: 11, y: 11))
                path.move(to: CGPoint(x: 4, y: 8)); path.line(to: CGPoint(x: 1, y: 11)); path.line(to: CGPoint(x: 4, y: 14))
            }
            path.stroke(); return true
        }
        // Rounded AppKit buttons and borderless launch cells tint templates differently.
        // Draw with the shared appearance-aware ink in both hosts.
        image.isTemplate = false
        return image
    }
}
