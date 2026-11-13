// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// One screenshot transaction owns only the pages it temporarily hid. Pins and
/// capture controls have independent presentation rules and never join this set.
@MainActor
final class CapturePageVisibility {
    enum Choice { case hide, keepVisible, cancel }
    private final class Page {
        weak var window: NSWindow?
        var closed = false
        init(_ window: NSWindow) { self.window = window }
    }
    private var pages: [Page] = []
    private(set) var token: UUID?
    private var closeObserver: NSObjectProtocol?
    var hasHiddenPages: Bool { !pages.isEmpty }

    init() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.pages.filter { $0.window === window }.forEach { $0.closed = true }
            }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    static func isPage(_ window: NSWindow) -> Bool {
        CaptureWindowPolicy.includes(window, hidePins: true) && window.isVisible && !window.isMiniaturized
    }

    func begin(preference: CapturePageVisibilityPreference, windows: [NSWindow],
               choose: () -> Choice) -> UUID? {
        restore()
        let visible = windows.filter(Self.isPage)
        let hide: Bool
        switch preference {
        case .automatic: hide = true
        case .never: hide = false
        case .ask:
            if visible.isEmpty { hide = false }
            else {
                switch choose() {
                case .hide: hide = true
                case .keepVisible: hide = false
                case .cancel: return nil
                }
            }
        }
        let id = UUID(); token = id
        if hide {
            pages = visible.map(Page.init)
            visible.forEach { $0.orderOut(nil) }
        }
        return id
    }

    func restore(ifCurrent id: UUID) {
        guard token == id else { return }
        restore()
    }
    func restore() {
        let hidden = pages
        pages = []; token = nil
        // Input windows arrive front to back. Restore their relative stacking
        // without activating Patch or making an old page the key window.
        for page in hidden.reversed() where !page.closed {
            guard let window = page.window, !window.isMiniaturized else { continue }
            window.orderFront(nil)
        }
    }
}
