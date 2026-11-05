// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT
import AppKit

/// A shared selector with a bounded list aligned to the visible button edges.
/// NSMenu remains the option model; its system popup geometry is not used.
@MainActor
final class SettingsSelector: NSPopUpButton, NSWindowDelegate {
    private(set) var listPanel: NSPanel?
    private var scroll: NSScrollView?
    private var rows: [SettingsListRow] = []
    private var highlightIsVisible = false
    private(set) var showsKeyboardFocus = false
    private var highlightedIndex = 0
    private var localMonitor: Any?
    private var globalMonitor: Any?
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { super.init(coder: coder); focusRingType = .none }
    override func becomeFirstResponder() -> Bool {
        showsKeyboardFocus = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 48
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool { showsKeyboardFocus = false; needsDisplay = true; return super.resignFirstResponder() }
    // This custom button displays the option model, not AppKit's independent
    // pull-down cell caption. Keep its label and accessibility value consistent.
    override var title: String {
        get { selectedItem?.title ?? super.title }
        set { super.title = newValue }
    }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 1 : 0, alpha: isHighlighted ? 0.16 : 0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let font = NSFont.systemFont(ofSize: 13)
        let text = selectedItem?.title ?? ""
        let textRect = NSRect(x: 12, y: (bounds.height - 18) / 2, width: bounds.width - 38, height: 18)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: textRect, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        NSColor.labelColor.setStroke()
        let chevron = NSBezierPath(); chevron.lineWidth = 1.8; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round
        let x = bounds.width - 22, y = bounds.midY
        chevron.move(to: CGPoint(x: x, y: y - 2)); chevron.line(to: CGPoint(x: x + 4, y: y + 2)); chevron.line(to: CGPoint(x: x + 8, y: y - 2)); chevron.stroke()
        if showsKeyboardFocus && window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { showsKeyboardFocus = false; window?.makeFirstResponder(self); performClick(nil) }
    override func performClick(_ sender: Any?) { if listPanel == nil { openList() } else { dismissList() } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; performClick(nil); return true }
    override func keyDown(with event: NSEvent) {
        if [49, 125, 126, 36].contains(event.keyCode) { openList() } else { super.keyDown(with: event) }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { dismissList() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func openList() {
        guard isEnabled, listPanel == nil, let host = window, numberOfItems > 0 else { return }
        let anchor = host.convertToScreen(convert(bounds, to: nil))
        let screen = host.screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        let desiredHeight = CGFloat(min(8, numberOfItems)) * 28 + 8
        let below = anchor.minY - screen.minY - 4, above = screen.maxY - anchor.maxY - 4
        let opensBelow = below >= desiredHeight || below >= above
        let height = min(desiredHeight, max(36, opensBelow ? below : above))
        let panel = SettingsListPanel(contentRect: NSRect(x: anchor.minX,
            y: opensBelow ? anchor.minY - 4 - height : anchor.maxY + 4,
            width: anchor.width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .popUpMenu; panel.appearance = host.effectiveAppearance
        panel.delegate = self
        let surface = SettingsListSurface(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = surface
        let scroll = NSScrollView(frame: surface.bounds.insetBy(dx: 4, dy: 4))
        scroll.hasVerticalScroller = numberOfItems > 8; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = SettingsListDocument(frame: NSRect(x: 0, y: 0, width: scroll.bounds.width,
            height: CGFloat(numberOfItems) * 28))
        highlightedIndex = max(0, indexOfSelectedItem); highlightIsVisible = false
        rows = itemArray.enumerated().map { index, item in
            let row = SettingsListRow(title: item.title,
                target: self, action: #selector(choose(_:)))
            row.state = index == indexOfSelectedItem ? .on : .off
            row.tag = index; row.isBordered = false; row.alignment = .left
            row.font = .systemFont(ofSize: 13); row.wantsLayer = true
            row.frame = NSRect(x: 4, y: CGFloat(index) * 28, width: document.bounds.width - (numberOfItems > 8 ? 22 : 8), height: 28)
            row.setAccessibilityLabel(item.title)
            row.onHover = { [weak self] entered in
                guard let self else { return }
                if entered { self.highlightedIndex = index }
                self.highlightIsVisible = entered
                self.highlightRow(scrollIntoView: false)
            }
            document.addSubview(row); return row
        }
        scroll.documentView = document; surface.addSubview(scroll)
        self.scroll = scroll; listPanel = panel
        panel.onKey = { [weak self] event in self?.handleListKey(event) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.window !== self?.listPanel { self?.dismissList() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.dismissList() }
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel)
        highlightRow()
    }
    private func handleListKey(_ event: NSEvent) {
        switch event.keyCode {
        case 53, 48: dismissList()
        case 125: highlightIsVisible = true; highlightedIndex = min(numberOfItems - 1, highlightedIndex + 1); highlightRow()
        case 126: highlightIsVisible = true; highlightedIndex = max(0, highlightedIndex - 1); highlightRow()
        case 36, 49, 76: choose(rows[highlightedIndex])
        default: break
        }
    }
    private func highlightRow(scrollIntoView: Bool = true) {
        for (index, row) in rows.enumerated() {
            row.emphasized = highlightIsVisible && index == highlightedIndex
            row.needsDisplay = true
        }
        if scrollIntoView { rows[highlightedIndex].scrollToVisible(rows[highlightedIndex].bounds) }
    }
    @objc private func choose(_ sender: NSButton) {
        selectItem(at: sender.tag); title = selectedItem?.title ?? ""; needsDisplay = true
        dismissList()
        sendAction(action, to: target)
    }
    func dismissList() {
        guard let panel = listPanel else { return }
        listPanel = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        panel.delegate = nil; panel.parent?.removeChildWindow(panel); panel.close()
        rows.removeAll(); scroll = nil; needsDisplay = true
    }
    func windowDidResignKey(_ notification: Notification) { dismissList() }
}
private final class SettingsListPanel: NSPanel {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}
private final class SettingsListDocument: NSView { override var isFlipped: Bool { true } }
private final class SettingsListSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(calibratedWhite: dark ? 0.16 : 1, alpha: 1).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        shape.fill(); NSColor.separatorColor.setStroke(); shape.lineWidth = 1; shape.stroke()
    }
}

private final class SettingsListRow: NSButton {
    var onHover: ((Bool) -> Void)?
    var emphasized = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if emphasized || isHighlighted {
            NSColor(calibratedWhite: dark ? 1 : 0, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let textY = (bounds.height - 18) / 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ]
        // Reserve the same checkmark column in every row. Padding with spaces
        // gives different text origins with proportional system fonts.
        if state == .on {
            ("✓" as NSString).draw(in: NSRect(x: 4, y: textY, width: 16, height: 18), withAttributes: attributes)
        }
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        var textAttributes = attributes; textAttributes[.paragraphStyle] = style
        (title as NSString).draw(in: NSRect(x: 24, y: textY, width: max(0, bounds.width - 28), height: 18),
            withAttributes: textAttributes)
    }
}
