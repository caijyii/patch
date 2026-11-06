// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// A local recording guide. Capture filtering, not window sharingType, keeps it
/// out of recorded media. The window never takes keyboard or pointer input.
@MainActor
final class RecordingRegionOverlay {
    private(set) var window: NSWindow?
    private var spaceObserver: NSObjectProtocol?
    var windowNumber: Int? { window?.windowNumber }

    func show(region: CaptureRegion) {
        close()
        let outline = RecordingOutlineWindow(contentRect: region.screenFrame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        outline.setFrame(region.screenFrame, display: false)
        outline.level = .floating
        outline.isOpaque = false; outline.backgroundColor = .clear; outline.hasShadow = false
        outline.ignoresMouseEvents = true; outline.isReleasedWhenClosed = false
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RecordingOutlineView(frame: CGRect(origin: .zero, size: region.screenFrame.size))
        view.selection = region.rect.offsetBy(dx: -region.screenFrame.minX, dy: -region.screenFrame.minY)
        outline.contentView = view
        window = outline
        outline.orderFrontRegardless()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.window?.orderFrontRegardless() }
            }
    }

    func close() {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        window?.close(); window = nil
    }

    deinit {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
}

private final class RecordingOutlineWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingOutlineView: NSView {
    var selection = CGRect.zero
    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: selection)); shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.16).setFill(); shade.fill()
        ToolbarPalette.accent.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5; border.stroke()
    }
}
