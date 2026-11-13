// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Shared vector artwork for the menu bar and the application bundle.
enum IconArtwork {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            // Fit the asymmetric silhouette to the small menu bar canvas.
            drawMark(in: NSRect(x: -2.5, y: -1.2, width: bounds.width * 1.25,
                               height: bounds.height * 1.19), sticker: false)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "patch"
        return image
    }

    static func applicationImage(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            let tile = bounds.insetBy(dx: size * 0.06, dy: size * 0.06)
            let background = NSBezierPath(roundedRect: tile, xRadius: size * 0.20, yRadius: size * 0.20)
            NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.93, alpha: 1).setFill()
            background.fill()
            drawMark(in: bounds.insetBy(dx: size * 0.14, dy: size * 0.14), sticker: true)
            return true
        }
    }

    private static func drawMark(in bounds: NSRect, sticker: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / 100, y: bounds.height / 100)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let ink = sticker
            ? NSColor(calibratedRed: 0.19, green: 0.27, blue: 0.23, alpha: 1).cgColor
            : NSColor.black.cgColor
        // A tapered body and flared roots give the tree a trunk, rather than a stroked stem.
        let tree = CGMutablePath()
        tree.move(to: CGPoint(x: 23, y: 10))
        tree.addCurve(to: CGPoint(x: 35, y: 34), control1: CGPoint(x: 35, y: 16), control2: CGPoint(x: 34, y: 25))
        tree.addLine(to: CGPoint(x: 36, y: 52))
        tree.addCurve(to: CGPoint(x: 17, y: 71), control1: CGPoint(x: 28, y: 56), control2: CGPoint(x: 22, y: 65))
        tree.addLine(to: CGPoint(x: 23, y: 76))
        tree.addCurve(to: CGPoint(x: 37, y: 61), control1: CGPoint(x: 27, y: 69), control2: CGPoint(x: 32, y: 64))
        tree.addLine(to: CGPoint(x: 39, y: 86))
        tree.addCurve(to: CGPoint(x: 44, y: 90), control1: CGPoint(x: 39, y: 89), control2: CGPoint(x: 41, y: 90))
        tree.addLine(to: CGPoint(x: 48, y: 90))
        tree.addCurve(to: CGPoint(x: 52, y: 85), control1: CGPoint(x: 51, y: 90), control2: CGPoint(x: 52, y: 88))
        tree.addLine(to: CGPoint(x: 52, y: 66))
        tree.addCurve(to: CGPoint(x: 66, y: 84), control1: CGPoint(x: 58, y: 70), control2: CGPoint(x: 62, y: 77))
        tree.addLine(to: CGPoint(x: 73, y: 81))
        tree.addCurve(to: CGPoint(x: 53, y: 57), control1: CGPoint(x: 69, y: 71), control2: CGPoint(x: 62, y: 62))
        tree.addLine(to: CGPoint(x: 55, y: 33))
        tree.addCurve(to: CGPoint(x: 68, y: 10), control1: CGPoint(x: 56, y: 23), control2: CGPoint(x: 58, y: 16))
        tree.addCurve(to: CGPoint(x: 54, y: 13), control1: CGPoint(x: 62, y: 10), control2: CGPoint(x: 58, y: 12))
        tree.addCurve(to: CGPoint(x: 44, y: 9), control1: CGPoint(x: 50, y: 10), control2: CGPoint(x: 47, y: 9))
        tree.addCurve(to: CGPoint(x: 34, y: 13), control1: CGPoint(x: 40, y: 9), control2: CGPoint(x: 37, y: 11))
        tree.addCurve(to: CGPoint(x: 23, y: 10), control1: CGPoint(x: 30, y: 11), control2: CGPoint(x: 27, y: 10))
        tree.closeSubpath()
        context.addPath(tree)
        context.setFillColor(ink)
        context.fillPath()

        if sticker {
            // Sparse vertical bark grooves reinforce the trunk at application-icon sizes.
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(1.8)
            context.move(to: CGPoint(x: 41, y: 23))
            context.addCurve(to: CGPoint(x: 43, y: 62), control1: CGPoint(x: 39, y: 35), control2: CGPoint(x: 43, y: 48))
            context.move(to: CGPoint(x: 49, y: 30))
            context.addCurve(to: CGPoint(x: 47, y: 80), control1: CGPoint(x: 47, y: 44), control2: CGPoint(x: 48, y: 66))
            context.strokePath()
        }

        // Place the sticker partly over the face of the trunk.
        context.saveGState()
        context.translateBy(x: -5, y: -6)
        defer { context.restoreGState() }

        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: 55, y: 53))
        leaf.addCurve(to: CGPoint(x: 84, y: 85), control1: CGPoint(x: 49, y: 71), control2: CGPoint(x: 62, y: 80))
        leaf.addCurve(to: CGPoint(x: 55, y: 53), control1: CGPoint(x: 86, y: 64), control2: CGPoint(x: 77, y: 48))
        leaf.closeSubpath()

        if sticker {
            // A white cutout edge and slight shadow read as a sticker at larger sizes.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 1.5, height: -2), blur: 2.4,
                              color: NSColor.black.withAlphaComponent(0.16).cgColor)
            context.addPath(leaf)
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(10)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        } else {
            // Cut the branch out behind the leaf; a template stays transparent in both appearances.
            context.saveGState()
            context.setBlendMode(.clear)
            context.addPath(leaf)
            context.setLineWidth(10)
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }

        context.addPath(leaf)
        context.setStrokeColor(ink)
        context.setLineWidth(4.8)
        if sticker {
            context.setFillColor(NSColor(calibratedRed: 0.61, green: 0.78, blue: 0.55, alpha: 1).cgColor)
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
        }

        context.setLineWidth(4.3)
        context.move(to: CGPoint(x: 58, y: 57))
        context.addCurve(to: CGPoint(x: 75, y: 76), control1: CGPoint(x: 63, y: 66), control2: CGPoint(x: 70, y: 68))
        context.strokePath()
    }
}
