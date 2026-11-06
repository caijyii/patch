// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText

private struct VerificationError: Error, CustomStringConvertible {
    let description: String
}
private enum Paper { case noise, text }
private struct Layer {
    var rect: CGRect
    var white = false
    var rounded = false
    var version: UInt32 = 0
    func contains(_ x: Int, _ y: Int) -> Bool {
        let point = CGPoint(x: x, y: y)
        guard rect.contains(point) else { return false }
        guard rounded else { return true }
        let radius: CGFloat = 10
        let cx = min(max(point.x, rect.minX + radius), rect.maxX - radius - 1)
        let cy = min(max(point.y, rect.minY + radius), rect.maxY - radius - 1)
        return pow(point.x - cx, 2) + pow(point.y - cy, 2) <= radius * radius
    }
}
@main private enum VerifyScrollFixed {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw VerificationError(description: message) }
    }
    static func hash(_ x: Int, _ y: Int, _ seed: UInt32 = 19) -> UInt32 {
        var v = UInt32(truncatingIfNeeded: x) &* 747_796_405 ^ UInt32(truncatingIfNeeded: y) &* 2_891_336_453 ^ seed
        v = (v ^ (v >> 16)) &* 2_246_822_519
        return v
    }
    static func pixels(width: Int, height: Int, left: Int = 0, top: Int,
                       paper: Paper, layers: [Layer] = [], horizontal: Int = 0) -> Data {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let worldX = x + left + horizontal, worldY = y + top
            var value: UInt32
            if paper == .noise { value = hash(worldX, worldY) }
            else {
                let row = Int(floor(Double(worldY) / 25)), gy = ((worldY % 25) + 25) % 25
                let inset = 12 + Int(hash(row, 17) % 4) * 9
                let cell = (worldX - inset) / 9, gx = (worldX - inset) % 9
                let ink = worldX >= inset && worldX < 300 && gy >= 3 && gy < 14 && gx >= 0 && gx < 6 &&
                    (hash(cell, row) >> UInt32((gy - 3) / 2 * 3 + gx / 2)) & 1 != 0
                value = ink ? 0x202020 : 0xFFFFFF
            }
            for layer in layers where layer.contains(x, y) {
                value = layer.white ? 0xFFFFFF : hash(x, y, 3_571 + layer.version)
            }
            let i = (y * width + x) * 4
            bytes[i] = UInt8(truncatingIfNeeded: value)
            bytes[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
        } }
        return Data(bytes)
    }
    static func image(width: Int = 320, height: Int = 300, top: Int,
                      paper: Paper = .noise, layers: [Layer] = [], horizontal: Int = 0) throws -> CGImage {
        let data = pixels(width: width, height: height, top: top, paper: paper, layers: layers, horizontal: horizontal)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw VerificationError(description: "Cannot create synthetic image")
        }
        return image
    }
    static func bytes(_ image: CGImage?) throws -> Data {
        guard let image, let data = image.dataProvider?.data else { throw VerificationError(description: "Missing exported pixels") }
        return data as Data
    }
    static func verifyExact(_ stitcher: ScrollStitcher, base: Int = 0, paper: Paper = .noise) throws {
        guard let rect = stitcher.contentRect else { throw VerificationError(description: "Missing content rect") }
        let expected = pixels(width: stitcher.width, height: stitcher.height, left: Int(rect.minX),
                              top: base + stitcher.minOrigin, paper: paper)
        let actual = try bytes(stitcher.image())
        let differences = zip(actual, expected).filter { $0 != $1 }.count
        try check(actual == expected, "Wrong document pixels: \(differences) bytes; rect=\(rect), origin=\(stitcher.minOrigin), height=\(stitcher.height)")
    }
    static func accepted(_ update: ScrollStitcher.Update) -> Bool {
        switch update { case .started, .appended, .revisited, .duplicate: return true; default: return false }
    }
    static func snapshot(_ stitcher: ScrollStitcher) throws -> String {
        let data = try bytes(stitcher.preview(maximumDimension: 1000))
        return "\(stitcher.contentRect as Any)|\(stitcher.scrollAnchor as Any)|\(stitcher.lastOrigin)|\(stitcher.minOrigin)|\(stitcher.width)|\(stitcher.height)|\(stitcher.outputRevision)|\(data.base64EncodedString())"
    }
    static func save(_ image: CGImage?, to url: URL) throws {
        guard let image, let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VerificationError(description: "Cannot write diagnostic image")
        }
        CGImageDestinationAddImage(writer, image, nil)
        try check(CGImageDestinationFinalize(writer), "Cannot finish diagnostic image")
    }
    static func numberedImage(top: Int, height: Int = 420, chrome: Bool = true) throws -> CGImage {
        let width = 600
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw VerificationError(description: "Cannot create numbered text fixture")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        func label(_ text: String, x: CGFloat, y: CGFloat, color: CGFloat = 0.12) {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: color, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, context)
        }
        for row in max(0, top / 28 - 2)...((top + height) / 28 + 1) {
            let y = CGFloat(70 + row * 28 - top)
            label(String(format: "Row %03d  value %05d  continuous text", row + 1, (row + 1) * 137), x: 126, y: y)
        }
        if chrome {
        context.setFillColor(CGColor(gray: 0.91, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 44))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1)); context.fill(CGRect(x: 0, y: 44, width: 108, height: 312))
        context.setFillColor(CGColor(gray: 0.88, alpha: 1)); context.fill(CGRect(x: 0, y: 356, width: width, height: 64))
        label("PATCH  /  Fixed toolbar", x: 16, y: 28)
        for (index, text) in ["Tools", "Capture", "History", "Options"].enumerated() { label(text, x: 12, y: CGFloat(76 + index * 36)) }
        label("Fixed footer  |  scroll step 28 px", x: 16, y: 392)
        }
        guard let result = context.makeImage() else { throw VerificationError(description: "Cannot finish numbered fixture") }
        return result
    }

    static func sequence(_ name: String, paper: Paper = .noise,
                         positions: [Int] = [0, 60, 120, 180, 240, 180, 60, 0, -60, 0, 120, 240, 300],
                         layers: (Int, Int) -> [Layer]) throws -> ScrollStitcher {
        let stitcher = ScrollStitcher()
        var expected = Data(), minimum = 0, maximum = 0
        var captured: [(origin: Int, pixels: Data)] = []
        for (index, position) in positions.enumerated() {
            let currentLayers = layers(index, position)
            let frame = try image(top: position, paper: paper, layers: currentLayers)
            captured.append((position, try bytes(frame)))
            let oldRevision = stitcher.outputRevision
            let update = stitcher.append(frame)
            try check(accepted(update), "\(name) at \(position): \(update)")
            if index == 0 {
                expected = try bytes(frame); minimum = position; maximum = position + 300
            } else if position < minimum {
                var extended = Data(try bytes(frame).prefix((minimum - position) * 320 * 4))
                extended.append(expected); expected = extended; minimum = position
                try check(stitcher.outputRevision > oldRevision, "prepend must revise output")
            } else if position + 300 > maximum {
                expected.append(try bytes(frame).suffix((position + 300 - maximum) * 320 * 4))
                maximum = position + 300
                try check(stitcher.outputRevision > oldRevision, "append must revise output")
            } else {
                try check(stitcher.outputRevision == oldRevision, "revisit must retain original hard seams")
            }
            try check(stitcher.width == 320 && stitcher.height == maximum - minimum,
                      "\(name) must preserve full selection dimensions")
            try check(stitcher.contentRect == CGRect(x: 0, y: 0, width: 320, height: 300),
                      "\(name) must never crop original selection")
            try check(stitcher.lastOrigin == position && stitcher.minOrigin == minimum,
                      "\(name) wrong moving-document position")
            let actual = try bytes(stitcher.image())
            for row in 0..<stitcher.height {
                let documentY = minimum + row
                let sourceRow = actual.subdata(in: row * 320 * 4..<(row + 1) * 320 * 4)
                try check(captured.contains { source in
                    guard documentY >= source.origin && documentY < source.origin + 300 else { return false }
                    let offset = (documentY - source.origin) * 320 * 4
                    return sourceRow == source.pixels.subdata(in: offset..<(offset + 320 * 4))
                }, "\(name) row \(documentY) must come from one real source row, without blending or shifting")
            }
            try check(stitcher.preview() != nil && stitcher.scrollAnchor != nil,
                      "\(name) must stay previewable, exportable and operable")
        }
        print("PASS \(name): full selection, exact source-row seams, both directions, export after every frame")
        return stitcher
    }
    static func run(output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let header = Layer(rect: CGRect(x: 0, y: 0, width: 320, height: 48))
        let footer = Layer(rect: CGRect(x: 0, y: 270, width: 320, height: 30))
        let sidebar = Layer(rect: CGRect(x: 0, y: 0, width: 96, height: 300))
        let center = Layer(rect: CGRect(x: 128, y: 110, width: 64, height: 80))
        let cases: [(String, [Layer])] = [
            ("plain document", []), ("fixed header", [header]), ("fixed footer", [footer]),
            ("fixed sidebar", [sidebar]), ("combined edges", [header, footer, sidebar]),
            ("center popup", [center]),
            ("opaque white popup", [Layer(rect: center.rect, white: true)]),
            ("bottom badge", [Layer(rect: CGRect(x: 280, y: 265, width: 24, height: 24))])
        ]
        for (name, layers) in cases { _ = try sequence(name, layers: { _, _ in layers }) }
        let tallFooter = Layer(rect: CGRect(x: 0, y: 200, width: 320, height: 100))
        let footerResult = try sequence("footer taller than scroll step", positions: [0, 30, 60, 90, 120], layers: { _, _ in [tallFooter] })
        let footerPixels = try bytes(footerResult.image())
        let continuousBody = pixels(width: 320, height: 320, top: 0, paper: .noise)
        try check(Data(footerPixels.prefix(continuousBody.count)) == continuousBody,
                  "footer must not hide newly exposed moving-document rows when step is smaller than footer")
        let finalFooter = pixels(width: 320, height: 300, top: 120, paper: .noise, layers: [tallFooter]).suffix(100 * 320 * 4)
        try check(footerPixels.suffix(100 * 320 * 4) == finalFooter, "last frame footer must remain at output bottom")
        print("PASS tall footer hard seam retains every moving body row and the last footer")
        let changingFooter = try sequence("changing footer taller than step", positions: [0, 30, 60, 90, 120], layers: { index, _ in
            [Layer(rect: tallFooter.rect, version: UInt32(index))]
        })
        let changingFooterPixels = try bytes(changingFooter.image())
        try check(Data(changingFooterPixels.prefix(continuousBody.count)) == continuousBody,
                  "changing footer must not omit any body row")
        let changingHeader = Layer(rect: CGRect(x: 0, y: 0, width: 320, height: 100))
        let headerResult = try sequence("changing header upward with smaller step", positions: [0, -30, -60, -90, -120], layers: { index, _ in
            [Layer(rect: changingHeader.rect, version: UInt32(index))]
        })
        let upwardBody = pixels(width: 320, height: 320, top: -20, paper: .noise)
        try check(Data(try bytes(headerResult.image()).suffix(upwardBody.count)) == upwardBody,
                  "changing header must not omit body rows during upward scroll")
        print("PASS changing top/bottom bars with smaller steps preserve every body pixel")
        for (name, layer) in [
            ("white text popup", Layer(rect: CGRect(x: 80, y: 105, width: 160, height: 85), white: true)),
            ("rounded white text button", Layer(rect: CGRect(x: 185, y: 130, width: 90, height: 46), white: true, rounded: true)),
            ("edge white text popup", Layer(rect: CGRect(x: 0, y: 105, width: 120, height: 85), white: true))
        ] { _ = try sequence(name, paper: .text, layers: { _, _ in [layer] }) }
        _ = try sequence("changing fixed popup", layers: { index, _ in
            [Layer(rect: center.rect, version: UInt32(index))]
        })
        _ = try sequence("changing fixed header", layers: { index, _ in
            [Layer(rect: header.rect, version: UInt32(index))]
        })
        let dynamic = try sequence("appearing and resizing popup", layers: { index, _ in
            if index < 2 { return [header] }
            return [header, Layer(rect: CGRect(x: 100 + index % 3 * 8, y: 110, width: 92, height: 80), version: UInt32(index))]
        })
        try save(dynamic.image(), to: output.appendingPathComponent("continuous-hard-seams.png"))
        let drift = ScrollStitcher()
        _ = drift.append(try image(top: 0, layers: [center]))
        _ = drift.append(try image(top: 60, layers: [center]))
        let state = try snapshot(drift)
        try check(!accepted(drift.append(try image(top: 120, layers: [center], horizontal: 8))), "horizontal drift must pause")
        try check(try snapshot(drift) == state && drift.image() != nil, "rejected drift changes existing export")
        try check(!accepted(drift.append(try image(top: 1200, layers: [center]))), "non-overlap jump must pause")
        try check(try snapshot(drift) == state && drift.image() != nil, "rejected jump changes existing export")
        try check(accepted(drift.append(try image(top: 120, layers: [center]))), "valid later frame must recover")
        print("PASS horizontal drift / no overlap preserve export and recover on valid frame")
        for useMemory in [false, true] {
            var limits = ScrollStitcher.Limits()
            if useMemory { limits.maximumWorkingBytes = 1_536_000 } else { limits.maximumHeight = 340 }
            let bounded = ScrollStitcher(limits: limits)
            _ = bounded.append(try image(top: 0, layers: [sidebar]))
            let before = try snapshot(bounded)
            guard case .limitReached = bounded.append(try image(top: 60, layers: [sidebar])) else {
                throw VerificationError(description: "full selection output ignored resource limit")
            }
            try check(try snapshot(bounded) == before && bounded.image() != nil, "limit changes existing export")
        }
        let full = ScrollStitcher()
        try check(full.append(try image(width: 3840, height: 2160, top: 0)) == .started(height: 2160), "4K first frame rejected")
        print("PASS full-width memory and height limits preserve export; 4K first frame remains supported")
        let numbered = ScrollStitcher()
        for position in stride(from: 0, through: 252, by: 28) {
            let frame = try numberedImage(top: position)
            if position == 0 { try save(frame, to: output.appendingPathComponent("numbered-fixed-first.png")) }
            let update = numbered.append(frame)
            try check(accepted(update) && numbered.image() != nil, "numbered fixed UI at \(position): \(update)")
            try check(numbered.lastOrigin == position && numbered.width == 600, "numbered body offset or full width changed")
        }
        try save(numbered.image(), to: output.appendingPathComponent("numbered-fixed-continuous.png"))
        let numberedPixels = try bytes(numbered.image())
        let cleanNumbered = try bytes(numberedImage(top: 0, height: numbered.height, chrome: false))
        for y in 44..<(numbered.height - 64) {
            let region = (y * 600 + 108) * 4..<(y + 1) * 600 * 4
            try check(numberedPixels.subdata(in: region) == cleanNumbered.subdata(in: region),
                      "numbered text body row \(y) is omitted or distorted by fixed toolbar/footer")
        }
        try check(numberedPixels.prefix(44 * 600 * 4) == bytes(numberedImage(top: 0)).prefix(44 * 600 * 4),
                  "first toolbar must remain intact")
        try check(numberedPixels.suffix(64 * 600 * 4) == bytes(numberedImage(top: 252)).suffix(64 * 600 * 4),
                  "last footer must remain intact")
        try save(numbered.image(), to: output.appendingPathComponent("numbered-fixed-continuous.png"))
        print("PASS readable numbered text: every body pixel matches clean full document; first toolbar and last footer intact")
        print("PASS all continuous fixed-element checks")
    }
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output",
              CommandLine.arguments[2].hasPrefix("/") else {
            print("Usage: verify-scroll-fixed --output /absolute/temporary/output-directory (offline synthetic pixels only)")
            return
        }
        do { try run(output: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)) }
        catch { print("FAIL \(error)"); exit(1) }
    }
}
