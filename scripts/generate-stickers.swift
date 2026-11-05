// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private struct Shape: Decodable {
    let path: String
    let fill: String?
    let stroke: String?
    let width: CGFloat
}
private struct Artwork: Decodable { let key: String; let shapes: [Shape] }
private struct CatalogItem: Decodable { let id: String; let title: String; let file: String; let retired: Bool? }
private struct GenerationFailure: Error { let message: String }

@main private struct GenerateStickers {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("scripts/sticker-artwork")
        let output = root.appendingPathComponent("Resources/PatchStickers")
        let preview = root.appendingPathComponent(".build/verification/original-stickers")
        for directory in [output, output.appendingPathComponent("pdf"), output.appendingPathComponent("svg"), preview] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let catalogData = try Data(contentsOf: source.appendingPathComponent("catalog.json"))
        let items = try JSONDecoder().decode([CatalogItem].self, from: catalogData)
        let selectable = items.filter { $0.retired != true }
        let sourceFiles = ["approved.json", "nature.json", "animals.json", "expressions-objects.json"]
        var artwork: [String: Artwork] = [:]
        for file in sourceFiles {
            for entry in try JSONDecoder().decode([Artwork].self, from: Data(contentsOf: source.appendingPathComponent(file))) {
                guard artwork[entry.key] == nil else { throw GenerationFailure(message: "Duplicate artwork: \(entry.key)") }
                artwork[entry.key] = entry
            }
        }
        guard items.count == artwork.count, Set(items.map(\.id)).count == items.count else {
            throw GenerationFailure(message: "Catalog entries and original artwork must match uniquely")
        }
        for item in items {
            let key = String(item.id.dropFirst("patch-".count))
            guard let art = artwork[key] else { throw GenerationFailure(message: "Missing artwork: \(key)") }
            // Parsing validates every command before exporting the resource.
            for shape in art.shapes { _ = try path(shape.path) }
            let paths = art.shapes.map { shape in
                "  <path d=\"\(shape.path)\" fill=\"\(shape.fill ?? "none")\" stroke=\"\(shape.stroke ?? "none")\" stroke-width=\"\(shape.width)\"/>"
            }.joined(separator: "\n")
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 96 96\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n\(paths)\n</svg>\n"
            let svgURL = output.appendingPathComponent("svg/\(item.id).svg")
            // CoreGraphics embeds creation metadata in PDFs. Preserve unchanged
            // originals so adding one sticker does not rewrite the whole library.
            if (try? String(contentsOf: svgURL, encoding: .utf8)) == svg,
               FileManager.default.fileExists(atPath: output.appendingPathComponent(item.file).path) { continue }
            var box = CGRect(x: 0, y: 0, width: 96, height: 96)
            guard let pdf = CGContext(output.appendingPathComponent(item.file) as CFURL, mediaBox: &box,
                [kCGPDFContextTitle: "Patch original sticker: \(item.title)",
                 kCGPDFContextCreator: "Patch vector artwork generator"] as CFDictionary) else {
                throw GenerationFailure(message: "Cannot create PDF: \(key)")
            }
            pdf.beginPDFPage(nil); pdf.translateBy(x: 0, y: 96); pdf.scaleBy(x: 1, y: -1)
            try draw(art, in: pdf, rect: box); pdf.endPDFPage(); pdf.closePDF()
            try svg.write(to: svgURL, atomically: true, encoding: .utf8)
        }
        try catalogData.write(to: output.appendingPathComponent("manifest.json"))
        try writePNG(preview.appendingPathComponent("all-stickers.png"), width: 1200, height: 990) { c in
            c.setFillColor(color("#f7f6f2")); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 990))
            label("小贴 · 原创手绘贴纸", x: 40, y: 24, size: 26, in: c)
            label("\(selectable.count) 个透明底矢量图案  ·  每格下方展示 16 / 24 点", x: 40, y: 66, size: 14, in: c, hex: "#85877b")
            for (index, item) in selectable.enumerated() {
                let x = CGFloat(30 + index % 8 * 144), y = CGFloat(112 + index / 8 * 198)
                c.setFillColor(color("#ffffff")); c.fill(CGRect(x: x, y: y, width: 136, height: 184))
                let art = artwork[String(item.id.dropFirst(6))]!
                try draw(art, in: c, rect: CGRect(x: x + 20, y: y + 12, width: 96, height: 96))
                label(item.title, x: x + 68, y: y + 116, size: 14, in: c, centered: true)
                try draw(art, in: c, rect: CGRect(x: x + 43, y: y + 151, width: 16, height: 16))
                try draw(art, in: c, rect: CGRect(x: x + 72, y: y + 147, width: 24, height: 24))
            }
            label("默认 16 点  ·  柔和填色与自然轮廓  ·  放大与导出保持矢量清晰度", x: 40, y: 936, size: 15, in: c)
        }
        try writePNG(preview.appendingPathComponent("small-sizes.png"), width: 1060, height: 440) { c in
            c.setFillColor(color("#f7f6f2")); c.fill(CGRect(x: 0, y: 0, width: 1060, height: 440))
            for (section, size) in [CGFloat(16), 24].enumerated() {
                let x = CGFloat(30 + section * 525)
                label("\(Int(size)) 点 · 浅色 / 深色背景", x: x, y: 18, size: 15, in: c)
                for dark in [false, true] {
                    let y: CGFloat = dark ? 244 : 66
                    c.setFillColor(color(dark ? "#363f3b" : "#ffffff")); c.fill(CGRect(x: x, y: y, width: 475, height: 168))
                    for (index, item) in selectable.enumerated() {
                        let art = artwork[String(item.id.dropFirst(6))]!
                        try draw(art, in: c, rect: CGRect(x: x + 18 + CGFloat(index % 8) * 58,
                            y: y + 13 + CGFloat(index / 8) * 40, width: size, height: size))
                    }
                }
            }
        }
        var provenance: [String: Any] = [
            "collection": "Patch original hand-drawn-style stickers",
            "author": "caijyii",
            "copyright": "Copyright (c) 2026 caijyii",
            "license": "MIT",
            "created": "2026-10-22",
            "origin": "Original vector paths authored with Codex for this project, following the user-approved six-icon style preview. Not derived from Fluent Emoji artwork.",
            "compatibility": "Legacy fluent-* identifiers and Unicode emoji are lookup aliases only.",
            "generator": "scripts/generate-stickers.sh",
            "source_directory": "scripts/sticker-artwork",
            "count": items.count,
            "selectable_count": selectable.count
        ]
        provenance["source_sha256"] = try Dictionary(uniqueKeysWithValues: (sourceFiles + ["catalog.json"]).map { file in
            (file, SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent(file))).map { String(format: "%02x", $0) }.joined())
        })
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("sources.json"))
        print("PASS: generated \(items.count) original SVG/PDF pairs (\(selectable.count) selectable), compatible manifest, provenance and full-size/16/24-point previews")
    }

    private static func color(_ value: String) -> CGColor {
        let hex = UInt32(value.dropFirst(), radix: 16)!
        return CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func path(_ source: String) throws -> CGPath {
        let tokens = source.split(separator: " "); var i = 0; let result = CGMutablePath()
        func point() throws -> CGPoint {
            guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i + 1]), x.isFinite, y.isFinite else {
                throw GenerationFailure(message: "Invalid path coordinates: \(source)")
            }
            i += 2; return CGPoint(x: x, y: y)
        }
        while i < tokens.count {
            let op = tokens[i]; i += 1
            switch op {
            case "M": result.move(to: try point())
            case "L": result.addLine(to: try point())
            case "Q": let control = try point(); result.addQuadCurve(to: try point(), control: control)
            case "C": let first = try point(), second = try point(); result.addCurve(to: try point(), control1: first, control2: second)
            case "Z": result.closeSubpath()
            default: throw GenerationFailure(message: "Unsupported path command: \(op)")
            }
        }
        return result
    }
    private static func draw(_ art: Artwork, in c: CGContext, rect: CGRect) throws {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY); c.scaleBy(x: rect.width / 96, y: rect.height / 96)
        c.setLineCap(.round); c.setLineJoin(.round)
        for shape in art.shapes {
            guard shape.width > 0, shape.width.isFinite, shape.fill != nil || shape.stroke != nil else {
                throw GenerationFailure(message: "Invalid shape in \(art.key)")
            }
            c.addPath(try path(shape.path)); c.setLineWidth(shape.width)
            if let fill = shape.fill { c.setFillColor(color(fill)) }
            if let stroke = shape.stroke { c.setStrokeColor(color(stroke)) }
            c.drawPath(using: shape.fill == nil ? .stroke : shape.stroke == nil ? .fill : .fillStroke)
        }
    }
    private static func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, in c: CGContext,
                              hex: String = "#5c6055", centered: Bool = false) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex)
        ]))
        let width = centered ? CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) : 0
        c.saveGState(); c.translateBy(x: x - width / 2, y: y + size); c.scaleBy(x: 1, y: -1)
        c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
    }
    private static func writePNG(_ url: URL, width: Int, height: Int, painter: (CGContext) throws -> Void) throws {
        let c = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8,
            bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(height * 2)); c.scaleBy(x: 2, y: -2); try painter(c)
        let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(out, c.makeImage()!, nil)
        guard CGImageDestinationFinalize(out) else { throw GenerationFailure(message: "Cannot write \(url.path)") }
    }
}
