// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit

@MainActor
final class CaptureService {
    func capture(_ region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw ScreenLeafError(message: "选中的显示器已断开，请重新框选。")
        }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
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
        guard !CGPreflightScreenCaptureAccess() else { return true }
        let alert = NSAlert()
        alert.messageText = "允许小贴捕获屏幕"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许小贴。首次允许后可能需要退出并重新打开 App。你也可以先用示例体验标注与贴图。"
        alert.addButton(withTitle: "申请权限")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return CGRequestScreenCaptureAccess()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return false
        default:
            return false
        }
    }
}
