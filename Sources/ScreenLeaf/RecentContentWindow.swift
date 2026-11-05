// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Formatting is shared by cards and accessibility labels and uses local calendar days.
enum RecentContentPresentation {
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return L("刚刚") }
        if elapsed < 3600 {
            let count = Int(elapsed / 60)
            return AppLocalization.isEnglish && count == 1 ? L("1 分钟前") : LF("%d 分钟前", count)
        }
        if elapsed < 86400 {
            let count = Int(elapsed / 3600)
            return AppLocalization.isEnglish && count == 1 ? L("1 小时前") : LF("%d 小时前", count)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLocalization.isEnglish ? "en_US" : "zh_CN")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = AppLocalization.isEnglish ? (sameYear ? "MMM d, HH:mm" : "yyyy-MM-dd HH:mm")
            : (sameYear ? "M月d日 HH:mm" : "yyyy/M/d HH:mm")
        return formatter.string(from: date)
    }
    static func groupTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return L("昨天") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: AppLocalization.isEnglish ? "en_US" : "zh_CN")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = AppLocalization.isEnglish ? (sameYear ? "MMM d" : "MMM d, yyyy")
            : (sameYear ? "M月d日" : "yyyy年M月d日")
        return formatter.string(from: date)
    }
}

private final class RecentPanelView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { WindowAmbientBackground.draw(in: self) }
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
private final class RecentGridView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class RecentInfoButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking); self.tracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class RecentContentWindowController: NSWindowController, NSWindowDelegate {
    private let store: RecentContentStore
    private let onPin: (RecentContentStore.Item) -> Void
    private let now: () -> Date
    private let content = RecentPanelView()
    private let grid = RecentGridView()
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let clear = NSButton(title: L("清空"), target: nil, action: nil)
    private let typeFilter = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let info = RecentInfoButton(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!, target: nil, action: nil)
    private var infoPopover: NSPopover?
    private var groups: [(label: NSTextField, cards: [RecentCardView])] = []
    private var empty: NSTextField?
    private var refreshTimer: Timer?
    private var arranging = false
    private var displayedDay: Date?

    init(store: RecentContentStore, now: @escaping () -> Date = Date.init, onPin: @escaping (RecentContentStore.Item) -> Void) {
        self.store = store; self.now = now; self.onPin = onPin
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        PatchWindowTitle.apply(to: window, title: L("Patch · 剪贴记录")); window.minSize = CGSize(width: 460, height: 340)
        let initialFrame = window.frame
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.setFrame(initialFrame, display: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = WindowAmbientBackground.color
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        clear.target = self; clear.action = #selector(clearCurrentFilter); clear.bezelStyle = .rounded
        clear.identifier = NSUserInterfaceItemIdentifier("history.clear")
        typeFilter.segmentCount = 3; typeFilter.selectedSegment = 0
        typeFilter.segmentStyle = .rounded
        typeFilter.identifier = NSUserInterfaceItemIdentifier("history.filter")
        typeFilter.target = self; typeFilter.action = #selector(filterChanged)
        info.identifier = NSUserInterfaceItemIdentifier("history.info")
        info.isBordered = false; info.contentTintColor = .secondaryLabelColor
        info.image = info.image?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        info.target = self; info.action = #selector(showInfo)
        info.onHover = { [weak self] entered in
            if entered { self?.showInfo() } else { self?.infoPopover?.close() }
        }
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12)
        status.identifier = NSUserInterfaceItemIdentifier("history.count")
        notice.textColor = .secondaryLabelColor; notice.font = .systemFont(ofSize: 11)
        notice.isHidden = true
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = grid
        for view in [status, info, clear, typeFilter, notice, scroll] { content.addSubview(view) }
        content.onLayout = { [weak self] in self?.layoutContent() }
        NotificationCenter.default.addObserver(self, selector: #selector(calendarContextChanged), name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarContextChanged), name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(calendarContextChanged), name: .NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        window.center(); reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { refreshTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    private var selectedFilter: RecentContentStore.Filter {
        RecentContentStore.Filter(rawValue: typeFilter.selectedSegment) ?? .all
    }
    func reload() {
        let position = scroll.contentView.bounds.origin
        grid.subviews.forEach { $0.removeFromSuperview() }; groups.removeAll(); empty = nil
        let filtered = store.items.filter(selectedFilter.includes)
        clear.isEnabled = !filtered.isEmpty
        clear.title = L("清空")
        let clearDescription: String
        switch selectedFilter {
        case .all: clearDescription = L("清空全部记录")
        case .images: clearDescription = L("清空图片记录")
        case .text: clearDescription = L("清空文本记录")
        }
        clear.toolTip = clearDescription; clear.setAccessibilityLabel(clearDescription)
        if let window { PatchWindowTitle.apply(to: window, title: L("Patch · 剪贴记录")) }
        status.stringValue = AppLocalization.isEnglish && filtered.count == 1
            ? L("共 1 条") : LF("共 %d 条", filtered.count)
        for (index, title) in [L("全部"), L("图片"), L("文本")].enumerated() {
            typeFilter.setLabel(title, forSegment: index)
            typeFilter.setWidth(max(52, ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 28), forSegment: index)
        }
        typeFilter.setAccessibilityLabel(L("内容类型"))
        let explanation = L("退出后将清空剪贴记录")
        info.toolTip = nil
        info.setAccessibilityLabel(explanation); info.setAccessibilityHelp(explanation)
        notice.stringValue = store.notice.map { L($0) } ?? ""; notice.isHidden = store.notice == nil
        let current = now()
        let calendar = Calendar.current
        displayedDay = calendar.startOfDay(for: current)
        let days = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        for day in days.keys.sorted(by: >) {
            let items = days[day]!
            let label = NSTextField(labelWithString: RecentContentPresentation.groupTitle(day, now: current, calendar: calendar))
            label.font = .systemFont(ofSize: 12, weight: .medium); label.textColor = .secondaryLabelColor
            label.identifier = NSUserInterfaceItemIdentifier("history.group.\(Int(day.timeIntervalSince1970))")
            grid.addSubview(label)
            let cards = items.map { item in
                let card = RecentCardView(item: item, now: current)
                card.pin.target = self; card.pin.action = #selector(pinItem(_:))
                card.remove.target = self; card.remove.action = #selector(removeItem(_:))
                grid.addSubview(card)
                return card
            }
            groups.append((label, cards))
        }
        if filtered.isEmpty {
            let label = NSTextField(wrappingLabelWithString: store.items.isEmpty
                ? L("还没有剪贴记录\n截图或复制内容后，会显示在这里。") : L("没有这类剪贴记录"))
            label.identifier = NSUserInterfaceItemIdentifier("history.empty")
            label.alignment = .center; label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 13)
            grid.addSubview(label); empty = label
        }
        layoutContent()
        let maximum = max(0, grid.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(position.y, maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private func layoutContent() {
        guard !arranging else { return }
        arranging = true; defer { arranging = false }
        let layoutBounds = window.map { content.convert($0.contentLayoutRect, from: nil) } ?? content.bounds
        let width = layoutBounds.width
        let topInset = layoutBounds.minY
        clear.frame = CGRect(x: width - 90, y: topInset + 13, width: 74, height: 30)
        info.frame = CGRect(x: clear.frame.minX - 32, y: topInset + 16, width: 24, height: 24)
        let filterWidth = typeFilter.fittingSize.width
        typeFilter.frame = CGRect(x: 18, y: topInset + 14, width: filterWidth, height: 28)
        let countWidth = ceil(max(status.intrinsicContentSize.width, status.fittingSize.width))
        status.frame = CGRect(x: info.frame.minX - countWidth - 10, y: topInset + 20, width: countWidth, height: 18)
        let top = topInset + (notice.isHidden ? 56 : 84)
        notice.frame = CGRect(x: 18, y: topInset + 49, width: width - 36, height: 28)
        scroll.frame = CGRect(x: 0, y: top, width: width, height: max(80, layoutBounds.maxY - top - 16))
        scroll.tile()
        let gridWidth = scroll.contentView.bounds.width
        // Put the scroller inside the outer margin instead of adding its width
        // only on the right. Both styles leave equal space around the cards.
        let track = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroll.scrollerStyle)
        let sideInset = max(24, track + 6)
        let usableWidth = max(1, width - sideInset * 2)
        let columns = usableWidth >= 740 ? 3 : 2
        let gap: CGFloat = 12
        let cardWidth = floor((usableWidth - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let cardsWidth = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap
        let cardsX = (width - cardsWidth) / 2
        let cardHeight: CGFloat = 206
        var y: CGFloat = 0
        for group in groups {
            group.label.frame = CGRect(x: cardsX + 2, y: y + 2, width: cardsWidth - 4, height: 18)
            y += 30
            for (index, card) in group.cards.enumerated() {
                card.frame = CGRect(x: cardsX + CGFloat(index % columns) * (cardWidth + gap),
                                    y: y + CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
                card.needsLayout = true
                card.layoutSubtreeIfNeeded()
            }
            y += CGFloat((group.cards.count + columns - 1) / columns) * (cardHeight + gap) + 12
        }
        grid.frame = CGRect(x: 0, y: 0, width: gridWidth, height: max(scroll.contentView.bounds.height, y))
        empty?.frame = CGRect(x: cardsX + 20, y: 68, width: cardsWidth - 40, height: 60)
    }
    @objc private func filterChanged() {
        scroll.contentView.scroll(to: .zero)
        reload()
    }
    @objc private func scrollerStyleChanged() { content.needsLayout = true }
    @objc private func calendarContextChanged() { if window?.isVisible == true { reload() } }
    @objc private func clearCurrentFilter() {
        guard store.items.contains(where: selectedFilter.includes) else { return }
        store.clear(selectedFilter)
    }
    @objc private func showInfo() {
        guard infoPopover?.isShown != true else { return }
        let controller = NSViewController()
        let text = L("退出后将清空剪贴记录"), font = NSFont.systemFont(ofSize: 12)
        let width = min(280, ceil((text as NSString).size(withAttributes: [.font: font]).width)) + 4
        let height = ceil((text as NSString).boundingRect(with: CGSize(width: width - 4, height: 1000),
            options: [.usesLineFragmentOrigin], attributes: [.font: font]).height) + 4
        controller.view = NSView(frame: CGRect(x: 0, y: 0, width: width + 20, height: height + 14))
        controller.view.identifier = NSUserInterfaceItemIdentifier("history.info-popover")
        let label = NSTextField(wrappingLabelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier("history.info-explanation")
        label.font = font; label.frame = CGRect(x: 10, y: 7, width: width, height: height)
        controller.view.addSubview(label)
        let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
        popover.contentViewController = controller; popover.contentSize = controller.view.bounds.size
        infoPopover = popover
        popover.show(relativeTo: info.bounds, of: info, preferredEdge: .minY)
    }
    @objc private func removeItem(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { store.remove(id) }
    }
    @objc private func pinItem(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue,
              let item = store.items.first(where: { $0.id.uuidString == value }) else { return }
        onPin(item)
    }
    @objc private func timeContextChanged() {
        guard window?.isVisible == true else { return }
        let current = now()
        if displayedDay != Calendar.current.startOfDay(for: current) { reload() }
        else { groups.flatMap(\.cards).forEach { $0.pin.refreshTime(current) } }
    }
    override func showWindow(_ sender: Any?) {
        if let window { WindowActivationCoordinator.shared.register(window) }
        reload(); super.showWindow(sender); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if refreshTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.timeContextChanged() }
            }
            timer.tolerance = 2; RunLoop.main.add(timer, forMode: .common); refreshTimer = timer
        }
    }
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil; infoPopover?.close(); infoPopover = nil
        // Closed cards must release their copies of records evicted by the store.
        grid.subviews.forEach { $0.removeFromSuperview() }; groups.removeAll(); empty = nil
    }
}

private final class RecentCardView: NSView {
    let pin: RecentItemButton
    let remove: NSButton
    override var isFlipped: Bool { true }
    init(item: RecentContentStore.Item, now: Date) {
        pin = RecentItemButton(item: item, now: now)
        remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("删除这条记录"))!, target: nil, action: nil)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("history.card.\(item.id.uuidString)")
        pin.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        remove.identifier = pin.identifier
        remove.isBordered = false; remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = L("删除这条记录"); remove.setAccessibilityLabel(LF("删除%@：%@", item.kindTitle, item.title))
        addSubview(pin); addSubview(remove)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout(); pin.frame = bounds
        remove.frame = CGRect(x: bounds.width - 36, y: bounds.height - 36, width: 28, height: 28)
    }
}

private final class RecentItemButton: NSButton {
    private let item: RecentContentStore.Item
    private var time: String
    private var tracking: NSTrackingArea?
    private var hovered = false
    override var isFlipped: Bool { true }
    init(item: RecentContentStore.Item, now: Date) {
        self.item = item; time = RecentContentPresentation.timeLabel(item.date, now: now)
        super.init(frame: .zero)
        title = item.title; isBordered = false; setButtonType(.momentaryPushIn)
        setAccessibilityLabel(LF("贴出%@，%@：%@", item.kindTitle, time, item.title))
        toolTip = L("贴出这条记录")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshTime(_ now: Date) {
        time = RecentContentPresentation.timeLabel(item.date, now: now)
        setAccessibilityLabel(LF("贴出%@，%@：%@", item.kindTitle, time, item.title))
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 10, yRadius: 10).fill() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.setFill(); shape.fill()
        if isHighlighted || hovered {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.035).setFill(); shape.fill()
        }
        NSColor.separatorColor.withAlphaComponent(hovered ? 0.8 : 0.4).setStroke(); shape.lineWidth = 1; shape.stroke()
        let preview = CGRect(x: 12, y: 12, width: bounds.width - 24, height: bounds.height - 56)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: preview, xRadius: 5, yRadius: 5).addClip()
        if let thumbnail = item.thumbnail {
            for row in 0...Int(preview.height / 10) { for column in 0...Int(preview.width / 10) {
                NSColor(calibratedWhite: (row + column).isMultiple(of: 2) ? 0.82 : 0.94, alpha: 1).setFill()
                CGRect(x: preview.minX + CGFloat(column * 10), y: preview.minY + CGFloat(row * 10), width: 10, height: 10).fill()
            } }
            let factor = min(preview.width / thumbnail.size.width, preview.height / thumbnail.size.height)
            let size = CGSize(width: thumbnail.size.width * factor, height: thumbnail.size.height * factor)
            NSGraphicsContext.current?.imageInterpolation = .high
            thumbnail.draw(in: CGRect(x: preview.midX - size.width / 2, y: preview.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if case .text(let text) = item.content {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.lineSpacing = 4
            (String(text.prefix(2000)) as NSString).draw(with: preview.insetBy(dx: 6, dy: 5),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        }
        NSGraphicsContext.restoreGraphicsState()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let caption = "\(item.kindTitle) · \(time)"
        (caption as NSString).draw(in: CGRect(x: 14, y: bounds.height - 30, width: bounds.width - 54, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
    }
}
