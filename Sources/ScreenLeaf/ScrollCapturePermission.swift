// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
enum ScrollCapturePermission {
    struct Snapshot {
        let accessibilityTrusted: Bool
        let canPostEvents: Bool

        var isGranted: Bool { accessibilityTrusted && canPostEvents }
        var explanation: String {
            if accessibilityTrusted && !canPostEvents {
                return "小贴的控制权限尚未完全生效。请在“系统设置 → 隐私与安全性 → 设备控制和数据访问／辅助功能”中确认小贴已开启。\n\n开启后请回到小贴重新开始；若已经开启，请退出并重新打开小贴后重试。"
            }
            return "长截图需要控制权限，用于锁定横向滚动和自动滚动。请在“系统设置 → 隐私与安全性 → 设备控制和数据访问／辅助功能”中开启小贴。\n\n开启后请回到小贴重新开始长截图。"
        }
    }
    enum Choice { case request, openSettings, later }
    enum Request { case accessibility, postEvents }

    static func ensurePermission() -> Bool {
        let snapshot = Snapshot(accessibilityTrusted: AXIsProcessTrusted(),
                                canPostEvents: CGPreflightPostEventAccess())
        return ensurePermission(snapshot: snapshot, choose: { snapshot in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "长截图需要控制权限"
            alert.informativeText = snapshot.explanation
            alert.addButton(withTitle: "申请权限并打开设置")
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .request
            case .alertSecondButtonReturn: return .openSettings
            default: return .later
            }
        }, request: { permission in
            switch permission {
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions([
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary)
            case .postEvents:
                _ = CGRequestPostEventAccess()
            }
        }, openSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
               NSWorkspace.shared.open(url) { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        })
    }

    /// Keep this attempt outside the selector even if requesting appears to grant
    /// permission immediately: OS prompts are asynchronous and Settings may be frontmost.
    static func ensurePermission(snapshot: Snapshot, choose: (Snapshot) -> Choice,
                                 request: (Request) -> Void, openSettings: () -> Void) -> Bool {
        guard !snapshot.isGranted else { return true }
        switch choose(snapshot) {
        case .request:
            // Request only one missing capability to avoid competing OS prompts,
            // then always expose the actual settings.
            request(snapshot.accessibilityTrusted ? .postEvents : .accessibility)
            openSettings()
        case .openSettings:
            openSettings()
        case .later:
            break
        }
        return false
    }
}
