// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Use one leading title treatment on every titled Patch window. The native
/// title remains available to window menus and accessibility clients.
@MainActor
enum PatchWindowTitle {
    static func apply(to window: NSWindow, title: String) {
        window.title = title
        guard window.styleMask.contains(.titled) else { return }
        window.titleVisibility = .hidden
        let accessory = window.titlebarAccessoryViewControllers
            .compactMap { $0 as? PatchTitleAccessory }.first ?? {
                let accessory = PatchTitleAccessory()
                window.addTitlebarAccessoryViewController(accessory)
                return accessory
            }()
        accessory.setTitle(title, window: window)
    }
}

@MainActor
private final class PatchTitleAccessory: NSTitlebarAccessoryViewController {
    private let label = NSTextField(labelWithString: "")
    private weak var titleWindow: NSWindow?

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .left
        view = PatchTitleView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.identifier = NSUserInterfaceItemIdentifier("patch.window-title")
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func setTitle(_ title: String, window: NSWindow) {
        label.stringValue = title
        label.toolTip = title
        if titleWindow !== window {
            NotificationCenter.default.removeObserver(self)
            titleWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(updateWidth),
                name: NSWindow.didResizeNotification, object: window)
        }
        updateWidth()
    }

    @objc private func updateWidth() {
        guard let window = titleWindow else { return }
        view.setFrameSize(NSSize(width: min(ceil(label.intrinsicContentSize.width) + 16,
            max(40, window.frame.width - 112)), height: view.frame.height))
    }
}

private final class PatchTitleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
