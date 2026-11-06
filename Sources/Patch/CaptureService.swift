// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureService {
    private let permission: ScreenCapturePermission
    init(permission: ScreenCapturePermission? = nil) { self.permission = permission ?? ScreenCapturePermission() }
    var hasPermission: Bool { permission.isGranted }
    func capture(_ region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw PatchError(message: "选中的显示器已断开，请重新框选。")
        }
        let included = CaptureWindowPolicy.includedWindowIDs
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && !included.contains($0.windowID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = max(2, Int((region.rect.width * region.scale).rounded()))
        configuration.height = max(2, Int((region.rect.height * region.scale).rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func ensurePermission() -> Bool {
        permission.ensurePermission()
    }
}

/// Read-only status is separate from requesting access, so opening Home never prompts.
@MainActor
final class ScreenCapturePermission {
    enum Choice { case request, settings, later }
    private let check: () -> Bool
    private let present: () -> Choice
    private let request: () -> Bool
    private let openSettings: () -> Void
    private var isPresenting = false

    init(check: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         activate: (() -> Void)? = nil,
         present: (() -> Choice)? = nil,
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         openSettings: @escaping () -> Void = {
             if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                 NSWorkspace.shared.open(url)
             }
         }) {
        self.check = check
        let bringForward = activate ?? { NSApp.activate(ignoringOtherApps: true) }
        if let present {
            self.present = { bringForward(); return present() }
        } else {
            self.present = { Self.showPrompt(activate: bringForward) }
        }
        self.request = request; self.openSettings = openSettings
    }
    var isGranted: Bool { check() }
    func ensurePermission() -> Bool {
        guard !isGranted else { return true }
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        switch present() {
        case .request: return request()
        case .settings: openSettings(); return false
        case .later: return false
        }
    }
    private static func showPrompt(activate: () -> Void) -> Choice {
        let alert = NSAlert()
        alert.messageText = L("允许小贴捕获屏幕")
        alert.informativeText = L("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许小贴。首次允许后可能需要退出并重新打开 App。你也可以先用示例体验标注与贴图。")
        alert.addButton(withTitle: L("申请权限"))
        alert.addButton(withTitle: L("打开系统设置"))
        alert.addButton(withTitle: L("稍后"))
        WindowActivationCoordinator.shared.register(alert.window)
        defer { WindowActivationCoordinator.shared.unregister(alert.window) }
        activate()
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .request
        case .alertSecondButtonReturn: return .settings
        default: return .later
        }
    }
}
