// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

enum DemoImage {
    @MainActor
    static func make() -> CGImage {
        let image = NSImage(size: NSSize(width: 960, height: 600))
        image.lockFocus()
        NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 960, height: 600).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 880, height: 520), xRadius: 24, yRadius: 24).fill()
        let lines: [(String, CGFloat, CGFloat)] = [
            ("Patch", 42, 470),
            ("让截图、标注和贴图连起来", 28, 408),
            ("这是内置示例，不需要屏幕录制权限。", 22, 338),
            ("试试箭头、方框、文字、序号、画笔和马赛克。", 22, 286),
            ("OCR example: Capture, annotate, pin.", 24, 218),
            ("提取文字后，可以复制或贴成可编辑便签。", 22, 158),
            ("示例编号：Patch-2026-001", 18, 96)
        ]
        for (text, size, y) in lines {
            (text as NSString).draw(at: NSPoint(x: 80, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: size > 30 ? .bold : .regular),
                .foregroundColor: NSColor(calibratedRed: 0.10, green: 0.23, blue: 0.17, alpha: 1)
            ])
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
}
