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

/// Keep every part of the alert in the system's layout. A fixed-width accessory
/// can widen the panel while its native button column stays narrow.
@MainActor
enum PatchAlertLayout {
    static func apply(to alert: NSAlert, text: String, separateSentences: Bool = false) {
        var display = text
        if separateSentences {
            display = text.components(separatedBy: "\n").map { line in
                var sentences: [String] = []
                line.enumerateSubstrings(in: line.startIndex..<line.endIndex, options: .bySentences) { substring, _, _, _ in
                    if let substring { sentences.append(substring.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                return sentences.isEmpty ? line : sentences.joined(separator: "\n\n")
            }.joined(separator: "\n")
            display = display.replacingOccurrences(of: " → ", with: "\n→ ")
                .replacingOccurrences(of: "；", with: "；\n")
                .replacingOccurrences(of: "首次允许后可能需要退出并重新打开 App。", with: "首次允许后可能需要\n退出并重新打开 App。")
                .replacingOccurrences(of: "若已经开启，请", with: "若已经开启，\n请")
                .replacingOccurrences(of: "／辅助功能", with: "／\n辅助功能")
        }
        alert.accessoryView = nil
        alert.informativeText = display
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
    // Menu-bar actions can originate while another application is active.
    // Bring the blocking alert forward before entering its modal event loop.
    NSApp.activate(ignoringOtherApps: true)
    alert.window.center()
    alert.window.makeKeyAndOrderFront(nil)
    alert.runModal()
}

struct PatchError: LocalizedError {
    let message: String
    var errorDescription: String? { L(message) }
}

/// Identifies pin content without including its separate operation toolbar.
@MainActor protocol CapturePinWindow: AnyObject {}

/// Ordinary Patch documents/settings are valid screenshot subjects. Transient
/// panels and capture controls stay excluded; pin content follows the capture option.
@MainActor
enum CaptureWindowPolicy {
    static func includes(_ window: NSWindow, hidePins: Bool = true) -> Bool {
        if window is CapturePinWindow { return !hidePins }
        return window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel)
    }
    static var includedWindowIDs: Set<CGWindowID> {
        includedWindowIDs(hidePins: true)
    }
    static func includedWindowIDs(hidePins: Bool) -> Set<CGWindowID> {
        // WindowServer can briefly retain ordered-out windows in its on-screen
        // list. Native visibility must also govern pixels and window candidates.
        Set(NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized && includes($0, hidePins: hidePins) }
            .compactMap { CGWindowID(exactly: $0.windowNumber) })
    }
}
