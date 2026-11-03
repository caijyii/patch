// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Export the exact built-in artwork, rather than maintaining separate image assets.
@main
struct GenerateHomeSeasons {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "HomeSeasons", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected an output directory"])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for season in HomeSeason.allCases {
            for dark in [false, true] {
                let suffix = dark ? "-dark" : ""
                try write(width: 1440, height: 960, to: output.appendingPathComponent("\(season.rawValue)\(suffix).png")) { context in
                    HomeSceneryArtwork.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 1440, height: 960),
                        season: season, dark: dark)
                }
            }
        }
        try write(width: 1500, height: 460, to: output.appendingPathComponent("spring-summer-winter.png")) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1500, height: 460))
            for (index, season) in [HomeSeason.spring, .summer, .winter].enumerated() {
                let x = CGFloat(index * 500 + 30)
                let names: [HomeSeason: String] = [.spring: "春 · 嫩芽", .summer: "夏 · 绿荫", .winter: "冬 · 薄雪"]
                label(names[season]!, at: CGPoint(x: x + 176, y: 30), in: context)
                drawWindow(in: context, rect: CGRect(x: x, y: 76, width: 440, height: 320), season: season)
            }
        }
        print("PASS: exported 8 seasonal backgrounds and spring-summer-winter.png to \(output.path)")
    }

    private static func write(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "HomeSeasons", code: 2)
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "HomeSeasons", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "HomeSeasons", code: 4) }
    }

    private static func drawWindow(in context: CGContext, rect: CGRect, season: HomeSeason) {
        let edge = NSColor(srgbRed: 0.58, green: 0.64, blue: 0.60, alpha: 1).cgColor
        let wood = NSColor(srgbRed: 0.97, green: 0.98, blue: 0.97, alpha: 1).cgColor
        context.addPath(arch(rect, rise: 78))
        context.setFillColor(wood); context.setStrokeColor(edge); context.setLineWidth(1)
        context.drawPath(using: .fillStroke)
        let inner = rect.insetBy(dx: 10, dy: 11)
        context.saveGState()
        context.addPath(arch(inner, rise: 68)); context.clip()
        HomeSceneryArtwork.draw(in: context, bounds: inner, season: season, dark: false)
        // The same translucent white glass as the home screen.
        context.setFillColor(CGColor(gray: 1, alpha: 0.59)); context.fill(inner)
        let cellWidth = (inner.width - 16) / 3
        for rail in [CGRect(x: inner.minX + cellWidth, y: inner.minY, width: 8, height: inner.height),
                     CGRect(x: inner.minX + cellWidth * 2 + 8, y: inner.minY, width: 8, height: inner.height),
                     CGRect(x: inner.minX, y: inner.minY + inner.height * 0.55, width: inner.width, height: 8)] {
            context.setFillColor(wood); context.fill(rail)
            context.setStrokeColor(edge); context.stroke(rail.insetBy(dx: 0.5, dy: 0.5))
        }
        context.restoreGState()
        context.addPath(arch(inner, rise: 68)); context.setStrokeColor(edge); context.strokePath()
        let sill = CGRect(x: rect.minX - 8, y: rect.maxY, width: rect.width + 16, height: 9)
        context.setFillColor(wood); context.fill(sill); context.setStrokeColor(edge); context.stroke(sill)
    }

    private static func arch(_ rect: CGRect, rise: CGFloat) -> CGPath {
        let path = CGMutablePath(), x = rect.minX, y = rect.minY, w = rect.width
        path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x, y: y + rise))
        path.addCurve(to: CGPoint(x: x + w / 2, y: y), control1: CGPoint(x: x, y: y + rise * 0.448),
            control2: CGPoint(x: x + w * 0.224, y: y))
        path.addCurve(to: CGPoint(x: rect.maxX, y: y + rise), control1: CGPoint(x: x + w * 0.776, y: y),
            control2: CGPoint(x: rect.maxX, y: y + rise * 0.448))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); path.closeSubpath()
        return path
    }

    private static func label(_ text: String, at point: CGPoint, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 20, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(srgbRed: 0.21, green: 0.28, blue: 0.25, alpha: 1).cgColor
        ]))
        context.saveGState(); context.translateBy(x: point.x, y: point.y + 20); context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
    }
}
