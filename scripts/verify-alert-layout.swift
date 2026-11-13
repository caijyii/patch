// Synthetic alerts only; no permission requests, capture, or system input.
import AppKit
import Darwin

@main private struct VerifyAlertLayout {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { fputs("FAIL: alert layout timed out\n", stderr); exit(1) }
        DispatchQueue.main.async { run(); exit(0) }
        app.run()
    }
    @MainActor private static func require(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    private static func normalize(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    @MainActor private static func run() {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            let cases: [(String, String, String, Bool)] = [
                ("screen", L("允许 patch 捕获屏幕"), L("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 patch。首次允许后可能需要退出并重新打开 App。你也可以先用示例体验标注与贴图。"), true),
                ("control", L("长截图需要控制权限"), ScrollCapturePermission.Snapshot(accessibilityTrusted: false, canPostEvents: false).explanation, true),
                ("partial", L("长截图需要控制权限"), ScrollCapturePermission.Snapshot(accessibilityTrusted: true, canPostEvents: false).explanation, true),
                ("transition", L("进入长截图将清除当前标注"), L("保留当前选区重新捕获，完成拼接后可重新标注。"), false),
                ("error", L("无法贴出剪贴板"), L("剪贴板中没有可贴出的图片或文字。"), false),
                ("hide-pages", L("截图时隐藏 patch 页面？"), "", false)
            ]
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, title, body, split) in cases {
                    let alert = NSAlert(); alert.messageText = title
                    if let icon = NSImage(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/icons/AppIcon.icns")) { alert.icon = icon }
                    let buttons: [String]
                    switch name {
                    case "control", "partial": buttons = [L("申请权限并打开设置"), L("打开系统设置"), L("稍后")]
                    case "transition": buttons = [L("继续长截图"), L("取消")]
                    case "error": buttons = [L("知道了")]
                    case "hide-pages": buttons = [L("隐藏并截图"), L("保持显示并截图"), L("取消")]
                    default: buttons = [L("申请权限"), L("打开系统设置"), L("稍后")]
                    }
                    buttons.forEach { alert.addButton(withTitle: $0) }
                    if name == "error" { alert.informativeText = body }
                    else if name != "hide-pages" { PatchAlertLayout.apply(to: alert, text: body, separateSentences: split) }
                    alert.window.appearance = NSAppearance(named: appearance)
                    require(alert.accessoryView == nil, "A custom body overrides the native alert layout")
                    require(normalize(alert.informativeText) == normalize(body), "Layout changed the original text")
                    require(alert.buttons.map(\.title) == buttons, "Layout changed native actions")
                    require(alert.buttons.first?.keyEquivalent == "\r", "Default keyboard action was lost")
                    let timer = Timer(timeInterval: 0.25, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            alert.window.contentView?.layoutSubtreeIfNeeded()
                            let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
                            require(alert.window.frame.width <= screen.width && alert.window.frame.height <= screen.height,
                                    "Native alert extends beyond the available display")
                            print("INFO: \(name) native panel=\(alert.window.frame.size)")
                            if let view = alert.window.contentView?.superview,
                               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                               let _ = bitmap.representation(using: .png, properties: [:]) {
                                view.cacheDisplay(in: view.bounds, to: bitmap)
                                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name)-\(language.rawValue)-\(appearance.rawValue).png"))
                            }
                            NSApp.stopModal(withCode: .alertThirdButtonReturn)
                            alert.window.orderOut(nil)
                        }
                    }
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    _ = alert.runModal()
                    print("PASS: \(name), \(language.rawValue), \(appearance.rawValue), original text preserved")
                }
            }
        }
        print("PASS: alert layout verification completed")
    }
}
