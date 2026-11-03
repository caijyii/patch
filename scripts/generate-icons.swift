// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

@main
struct GenerateIcons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "IconGeneration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected an output directory."])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let suffix = scale == 2 ? "@2x" : ""
                try writePNG(IconArtwork.applicationImage(size: CGFloat(pixels)), pixels: pixels,
                             to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
        try writePNG(IconArtwork.applicationImage(), pixels: 1024,
                     to: output.appendingPathComponent("AppIcon.png"))
        try writePNG(IconArtwork.menuBarImage(), pixels: 36,
                     to: output.appendingPathComponent("MenuBarIcon.png"))
        try writePNG(preview(), pixels: 1120, to: output.appendingPathComponent("IconPreview.png"), height: 640)
        print("Generated application iconset, menu bar image and visual preview: \(output.path)")
    }

    private static func writePNG(_ image: NSImage, pixels: Int, to url: URL, height: Int? = nil) throws {
        let pixelHeight = height ?? pixels
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixelHeight,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "IconGeneration", code: 2)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixelHeight),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGeneration", code: 3)
        }
        try data.write(to: url)
    }

    private static func preview() -> NSImage {
        NSImage(size: NSSize(width: 1120, height: 640), flipped: false) { bounds in
            let titleColor = NSColor(calibratedWhite: 0.14, alpha: 1)
            let captionColor = NSColor(calibratedWhite: 0.46, alpha: 1)
            NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
            bounds.fill()
            IconArtwork.applicationImage(size: 380).draw(in: NSRect(x: 90, y: 150, width: 380, height: 380))
            drawLabel("小贴 · Patch", at: CGPoint(x: 115, y: 106), size: 26, color: titleColor)
            drawLabel("截图与贴图", at: CGPoint(x: 115, y: 72), size: 17, color: captionColor)
            drawLabel("菜单栏 · 实际尺寸与放大", at: CGPoint(x: 595, y: 500), size: 19, color: titleColor)
            for (index, dark) in [false, true].enumerated() {
                let strip = NSRect(x: 595, y: 355 - CGFloat(index) * 100, width: 405, height: 66)
                (dark ? NSColor(calibratedWhite: 0.17, alpha: 1) : NSColor(calibratedWhite: 0.91, alpha: 1)).setFill()
                NSBezierPath(roundedRect: strip, xRadius: 12, yRadius: 12).fill()
                let icon = IconArtwork.menuBarImage()
                icon.isTemplate = false
                let tint = dark ? NSColor.white : NSColor.black
                let tinted = NSImage(size: icon.size, flipped: false) { rect in
                    icon.draw(in: rect)
                    tint.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(x: 631, y: strip.midY - 9, width: 18, height: 18))
                tinted.draw(in: NSRect(x: 702, y: strip.midY - 18, width: 36, height: 36))
                drawLabel(dark ? "深色" : "浅色", at: CGPoint(x: 800, y: strip.midY - 10), size: 17, color: tint)
            }
            drawLabel("一片叶子，贴在树干上", at: CGPoint(x: 595, y: 175), size: 18, color: captionColor)
            return true
        }
    }

    private static func drawLabel(_ text: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color
        ])
    }
}
