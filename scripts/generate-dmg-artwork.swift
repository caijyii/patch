// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT
import AppKit

// Finder draws the real, draggable icons and their labels over this 2x background.
guard CommandLine.arguments.count == 2 else { fputs("Usage: generate-dmg-artwork <output.png>\n", stderr); exit(2) }
let output = CommandLine.arguments[1]
let width = 720, height = 352
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
let ink = color(0.22, 0.31, 0.26)
color(0.975, 0.974, 0.949).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
let arch = NSBezierPath()
arch.move(to: NSPoint(x: 48, y: 288)); arch.line(to: NSPoint(x: 48, y: 144))
arch.curve(to: NSPoint(x: 360, y: 64), controlPoint1: NSPoint(x: 48, y: 100), controlPoint2: NSPoint(x: 277, y: 64))
arch.curve(to: NSPoint(x: 672, y: 144), controlPoint1: NSPoint(x: 443, y: 64), controlPoint2: NSPoint(x: 672, y: 100))
arch.line(to: NSPoint(x: 672, y: 288)); arch.close()
color(0.936, 0.951, 0.921).setFill(); arch.fill()
color(0.79, 0.83, 0.77).setStroke(); arch.lineWidth = 1; arch.stroke()
let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 285, y: 151))
arrow.curve(to: NSPoint(x: 435, y: 151), controlPoint1: NSPoint(x: 337, y: 175), controlPoint2: NSPoint(x: 383, y: 175))
arrow.move(to: NSPoint(x: 417, y: 147)); arrow.line(to: NSPoint(x: 435, y: 151)); arrow.line(to: NSPoint(x: 425, y: 167))
ink.withAlphaComponent(0.65).setStroke(); arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
