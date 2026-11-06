// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CoreGraphics

/// Screen coordinates are AppKit points (origin at the lower left).
struct CaptureRegion {
    let rect: CGRect
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let scale: CGFloat
    let targetPID: pid_t?

    var sourceRect: CGRect {
        CGRect(x: rect.minX - screenFrame.minX,
               y: screenFrame.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    var eventPoint: CGPoint {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        return CGPoint(x: rect.midX, y: primaryTop - rect.midY)
    }
}

@MainActor
func showError(_ error: Error, title: String = "操作未完成") {
    let alert = NSAlert()
    alert.messageText = L(title)
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: L("知道了"))
    WindowActivationCoordinator.shared.register(alert.window)
    defer { WindowActivationCoordinator.shared.unregister(alert.window) }
    alert.runModal()
}

struct PatchError: LocalizedError {
    let message: String
    var errorDescription: String? { L(message) }
}

/// Ordinary Patch documents/settings are valid screenshot subjects. Transient
/// panels, pins and capture controls keep their existing exclusion behavior.
@MainActor
enum CaptureWindowPolicy {
    static func includes(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel)
    }
    static var includedWindowIDs: Set<CGWindowID> {
        Set(NSApp.windows.filter { includes($0) }.compactMap { CGWindowID(exactly: $0.windowNumber) })
    }
}
