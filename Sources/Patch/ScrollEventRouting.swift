// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import AppKit

enum ScrollEventRouting {
    static func captureTargetPID(windowOwnerPID: pid_t?, fallbackApplicationPID: pid_t?) -> pid_t? {
        if let pid = windowOwnerPID, pid > 0 { return pid }
        if let pid = fallbackApplicationPID, pid > 0 { return pid }
        return nil
    }

    static func isFrontmost(_ application: NSRunningApplication?) -> Bool {
        guard let application, !application.isTerminated,
              let foreground = NSWorkspace.shared.frontmostApplication else { return false }
        // AppKit may report -1 for a live app's PID; application equality remains valid.
        return application.isEqual(foreground)
    }

    static func mouseMovedFromAnchor(current: CGPoint, anchor: CGPoint) -> Bool {
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        // Allow subpixel and display rounding; intentional movement yields control.
        return dx * dx + dy * dy > 9
    }

    static func owner(ofWindow windowNumber: Int, windows: [[String: Any]]) -> pid_t? {
        guard windowNumber > 0 else { return nil }
        for window in windows {
            guard window[kCGWindowNumber as String] as? Int == windowNumber,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner > 0 else { continue }
            return owner
        }
        return nil
    }
}
