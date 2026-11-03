// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// Original, resolution-independent seasonal artwork, embedded with the application.
enum HomeSceneryArtwork {
    private static let treeScale: CGFloat = 1.6
    static func draw(in context: CGContext, bounds: CGRect, season: HomeSeason, dark: Bool, motionTime: TimeInterval = 0) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        context.clip(to: bounds)
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / 720, y: bounds.height / 480)
        context.setFillColor(color(skyColor(for: season, dark: dark)))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let horizon = CGMutablePath()
        horizon.move(to: CGPoint(x: 0, y: 412))
        horizon.addCurve(to: CGPoint(x: 410, y: 408), control1: CGPoint(x: 180, y: 383),
                         control2: CGPoint(x: 282, y: 432))
        horizon.addCurve(to: CGPoint(x: 720, y: 390), control1: CGPoint(x: 540, y: 383),
                         control2: CGPoint(x: 635, y: 404))
        let ground = horizon.mutableCopy()!
        ground.addLine(to: CGPoint(x: 720, y: 480))
        ground.addLine(to: CGPoint(x: 0, y: 480))
        ground.closeSubpath()
        context.addPath(ground)
        context.setFillColor(color(groundColor(for: season, dark: dark),
            alpha: season == .winter ? (dark ? 0.20 : 0.65) : (dark ? 0x35 / 255.0 : 0x3d / 255.0)))
        context.fillPath()
        context.addPath(horizon)
        context.setStrokeColor(color(season == .winter ? (dark ? 0xb8c7cd : 0xa1b1ba) :
            (dark ? 0xafbd9e : 0x95a485), alpha: 0.4))
        context.setLineWidth(1.4)
        context.strokePath()

        drawTree(in: context, season: season, dark: dark, motionTime: motionTime)
        drawSkyAndGrass(in: context, season: season, dark: dark)
        context.restoreGState()
    }

    private static func drawTree(in context: CGContext, season: HomeSeason, dark: Bool, motionTime: TimeInterval) {
        context.saveGState()
        context.translateBy(x: 500, y: -45)
        context.scaleBy(x: Self.treeScale, y: Self.treeScale)
        let sway = CGFloat(sin(motionTime * 0.55)) * 1.8 / Self.treeScale
        context.setStrokeColor(color(season == .winter ? (dark ? 0xabb9bc : 0x8c9da0) :
            (dark ? 0xa5b193 : 0x829274)))
        context.setFillColor(color(season == .winter ? (dark ? 0x7b8b8e : 0xb4c0bf) :
            (dark ? 0x7a8566 : 0xa9b58f), alpha: dark ? 0x55 / 255.0 : 0x60 / 255.0))
        context.setLineWidth(1.8 / sqrt(Self.treeScale))
        context.beginPath()
        context.move(to: CGPoint(x: -28, y: 370))
        context.addCurve(to: CGPoint(x: -10, y: 237), control1: CGPoint(x: -6, y: 350),
                         control2: CGPoint(x: -9, y: 301))
        for (x, y) in [(-42.0, 201.0), (-91, 173), (-85, 168), (-29, 191), (-8, 209),
                       (-11, 132), (-2, 125), (7, 195), (36, 152), (81, 121), (86, 127),
                       (48, 163), (12, 226)] {
            context.addLine(to: CGPoint(x: x, y: y))
        }
        context.addCurve(to: CGPoint(x: 35, y: 369), control1: CGPoint(x: 11, y: 302),
                         control2: CGPoint(x: 15, y: 346))
        context.addQuadCurve(to: CGPoint(x: -28, y: 370), control: CGPoint(x: 3, y: 361))
        context.drawPath(using: .fillStroke)

        let limbs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-88, 170, -143, 91, -202, 91), (-34, 199, -64, 90, -91, 42),
            (-2, 156, -9, 59, 27, 28), (40, 166, 98, 95, 149, 82), (78, 131, 147, 123, 186, 149)
        ]
        for (x, y, qx, qy, ex, ey) in limbs {
            context.beginPath()
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(to: CGPoint(x: ex + sway * 2, y: ey), control: CGPoint(x: qx + sway, y: qy))
            context.strokePath()
        }
        if season == .winter {
            drawWinterBranches(in: context, limbs: limbs, dark: dark, sway: sway)
            context.restoreGState()
            return
        }

        var clusters: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-154, 100, 73, 45), (-99, 60, 63, 47), (-31, 57, 64, 51), (43, 46, 67, 47),
            (104, 82, 69, 48), (157, 127, 64, 43), (-102, 151, 67, 47), (-31, 125, 74, 53),
            (70, 137, 80, 53), (-184, 144, 43, 36)
        ]
        if season == .spring {
            // Young crowns leave space between the branches and the new leaves.
            clusters = [(-158, 100, 57, 34), (-96, 57, 46, 36), (-28, 54, 43, 34),
                        (43, 43, 48, 35), (105, 80, 51, 36), (157, 126, 45, 31),
                        (-106, 145, 43, 30), (61, 131, 50, 35)]
        } else if season == .summer {
            // A few lower crowns make summer visibly fuller, beyond its palette.
            clusters += [(-157, 169, 51, 34), (-46, 181, 62, 39), (83, 181, 57, 36)]
        }
        for (index, cluster) in clusters.enumerated() {
            let (x, y, rx, ry) = cluster
            let dx = sway * (1 + CGFloat(index % 3) * 0.3)
            context.beginPath()
            context.move(to: CGPoint(x: x - rx + dx, y: y))
            context.addCurve(to: CGPoint(x: x + dx, y: y - ry),
                control1: CGPoint(x: x - rx * 1.08 + dx, y: y - ry * 0.7),
                control2: CGPoint(x: x - rx * 0.5 + dx, y: y - ry * 1.05))
            context.addCurve(to: CGPoint(x: x + rx + dx, y: y),
                control1: CGPoint(x: x + rx * 0.65 + dx, y: y - ry * 1.08),
                control2: CGPoint(x: x + rx * 1.1 + dx, y: y - ry * 0.4))
            context.addCurve(to: CGPoint(x: x + dx, y: y + ry),
                control1: CGPoint(x: x + rx * 1.05 + dx, y: y + ry * 0.7),
                control2: CGPoint(x: x + rx * 0.4 + dx, y: y + ry * 1.05))
            context.addCurve(to: CGPoint(x: x - rx + dx, y: y),
                control1: CGPoint(x: x - rx * 0.65 + dx, y: y + ry * 0.9),
                control2: CGPoint(x: x - rx * 1.03 + dx, y: y + ry * 0.5))
            context.setFillColor(color(season.leaves[index % 3], alpha: season == .spring ? 0.30 : 0.35))
            context.fillPath()

            context.setStrokeColor(color(dark ? 0xc2cdb0 : 0x8f9f7d, alpha: 0.35))
            context.setLineWidth(1)
            context.saveGState()
            context.translateBy(x: x + dx, y: y)
            context.rotate(by: 0.04)
            let contour = CGMutablePath()
            let ellipseScale = CGAffineTransform(scaleX: rx, y: ry)
            contour.addArc(center: .zero, radius: 1, startAngle: 3.3, endAngle: 5.5, clockwise: false,
                           transform: ellipseScale)
            context.addPath(contour)
            context.strokePath()
            context.restoreGState()

            context.setStrokeColor(color(dark ? 0xc2cdb0 : 0x8f9f7d, alpha: 0.45))
            for leaf in 0..<3 {
                let lx = x + CGFloat(sin(Double(index) * 2.4 + Double(leaf) * 4)) * rx * 0.65 + dx
                let ly = y + CGFloat(cos(Double(index) * 3 + Double(leaf) * 2)) * ry * 0.6
                context.beginPath()
                context.move(to: CGPoint(x: lx - 4, y: ly + 3))
                context.addQuadCurve(to: CGPoint(x: lx + 6, y: ly - 5), control: CGPoint(x: lx - 7, y: ly - 5))
                context.addQuadCurve(to: CGPoint(x: lx - 4, y: ly + 3), control: CGPoint(x: lx + 7, y: ly + 3))
                context.strokePath()
            }
        }
        if season == .spring {
            drawSpringBuds(in: context, dark: dark, sway: sway)
        } else if season == .summer {
            drawSummerLight(in: context, dark: dark, sway: sway)
        }
        context.restoreGState()
    }

    private static func drawSpringBuds(in context: CGContext, dark: Bool, sway: CGFloat) {
        context.setLineWidth(0.7)
        let buds: [(CGFloat, CGFloat)] = [(-199, 91), (-171, 119), (-120, 82),
            (-91, 44), (-57, 92), (-10, 110), (30, 35), (69, 104), (126, 67), (151, 112)]
        for (index, bud) in buds.enumerated() {
            let (x, y) = bud
            let dx = sway * (1.3 + CGFloat(index % 3) * 0.3)
            // Three small petals read as buds at the window's displayed size.
            context.setFillColor(color(dark ? 0xd9c9c7 : 0xfff8f5, alpha: dark ? 0.63 : 0.94))
            context.setStrokeColor(color(dark ? 0xc6acaf : 0xd6bfc1, alpha: 0.65))
            for offset: (CGFloat, CGFloat) in [(-2.8, -0.5), (0.2, -3.0), (2.9, 0.4)] {
                context.addEllipse(in: CGRect(x: x + dx + offset.0 - 2.7,
                    y: y + offset.1 - 2.7, width: 5.4, height: 5.4))
                context.drawPath(using: .fillStroke)
            }
            context.setFillColor(color(dark ? 0xc7bfa2 : 0xb7b991, alpha: 0.7))
            context.fillEllipse(in: CGRect(x: x + dx - 0.9, y: y - 1.2, width: 1.8, height: 1.8))
        }
    }

    private static func drawSummerLight(in context: CGContext, dark: Bool, sway: CGFloat) {
        context.setFillColor(color(dark ? 0xe5e3ba : 0xffffed, alpha: dark ? 0.09 : 0.27))
        for (index, spot) in [(-178.0, 105.0, 8.0), (-90, 81, 5), (-34, 149, 7),
                              (48, 78, 6), (84, 171, 5)].enumerated() {
            let (x, y, radius) = spot
            let dx = sway * (1 + CGFloat(index % 3) * 0.3)
            context.fillEllipse(in: CGRect(x: CGFloat(x) + dx - radius, y: y - radius * 0.65,
                width: radius * 2, height: radius * 1.3))
        }
    }

    private static func drawWinterBranches(in context: CGContext,
        limbs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)], dark: Bool, sway: CGFloat) {
        func point(on limb: (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat), at t: CGFloat) -> CGPoint {
            let (x, y, qx, qy, ex, ey) = limb
            let u = 1 - t
            return CGPoint(x: u * u * x + 2 * u * t * (qx + sway) + t * t * (ex + 2 * sway),
                           y: u * u * y + 2 * u * t * qy + t * t * ey)
        }
        // Each small branch starts on a parent curve, including while it sways.
        let twigs: [(Int, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, 0.35, -120, 118, -130, 79), (0, 0.72, -175, 77, -181, 51),
            (0, 0.95, -221, 86, -237, 66), (0, 0.60, -159, 131, -187, 140),
            (1, 0.45, -72, 115, -112, 91), (1, 0.82, -89, 60, -64, 32),
            (2, 0.45, 17, 91, 53, 71), (2, 0.73, -13, 54, -35, 36),
            (3, 0.32, 64, 110, 56, 78), (3, 0.71, 126, 86, 130, 53),
            (3, 0.93, 164, 67, 183, 63), (4, 0.43, 130, 122, 147, 96),
            (4, 0.70, 167, 143, 178, 171)
        ]
        context.setStrokeColor(color(dark ? 0xb6c3c5 : 0x9aabad, alpha: 0.78))
        context.setLineWidth(1.05 / sqrt(Self.treeScale))
        for (index, twig) in twigs.enumerated() {
            let (parent, t, qx, qy, ex, ey) = twig
            let start = point(on: limbs[parent], at: t)
            context.beginPath()
            context.move(to: start)
            context.addQuadCurve(to: CGPoint(x: ex + 2 * sway, y: ey),
                control: CGPoint(x: qx + sway * (1 + t), y: qy))
            context.strokePath()
            if index % 2 == 0 {
                // A short fork breaks the uniformity without filling in a crown.
                let u: CGFloat = 0.3, v: CGFloat = 0.7
                let fork = CGPoint(x: u * u * start.x + 2 * u * v * (qx + sway * (1 + t)) +
                    v * v * (ex + 2 * sway), y: u * u * start.y + 2 * u * v * qy + v * v * ey)
                context.beginPath()
                context.move(to: fork)
                context.addQuadCurve(to: CGPoint(x: fork.x + (index % 4 == 0 ? -13 : 13), y: fork.y - 12),
                    control: CGPoint(x: fork.x + (index % 4 == 0 ? -9 : 9), y: fork.y - 3))
                context.strokePath()
            }
        }
        // Thin white deposits follow the upper side of gently sloping limbs.
        context.setStrokeColor(color(dark ? 0xe4edef : 0xffffff, alpha: dark ? 0.76 : 0.97))
        context.setLineWidth(3.0 / sqrt(Self.treeScale))
        for (parent, start, end): (Int, CGFloat, CGFloat) in [(0, 0.53, 0.96), (3, 0.60, 0.95), (4, 0.27, 0.67)] {
            context.beginPath()
            for step in 0...12 {
                var p = point(on: limbs[parent], at: start + (end - start) * CGFloat(step) / 12)
                p.y -= 1.7
                if step == 0 { context.move(to: p) } else { context.addLine(to: p) }
            }
            context.strokePath()
        }
    }

    private static func drawSkyAndGrass(in context: CGContext, season: HomeSeason, dark: Bool) {
        context.setStrokeColor(color(season == .winter ? (dark ? 0xbbcbd2 : 0xa0b2bf) :
            (dark ? 0xb6c7ae : 0x98aa8d), alpha: 0.35))
        context.setLineWidth(1.5)
        for (x, y): (CGFloat, CGFloat) in [(89, 97), (631, 71)] {
            context.beginPath()
            context.move(to: CGPoint(x: x - 25, y: y))
            context.addCurve(to: CGPoint(x: x - 2, y: y - 8), control1: CGPoint(x: x - 29, y: y - 9),
                             control2: CGPoint(x: x - 12, y: y - 17))
            context.addCurve(to: CGPoint(x: x + 29, y: y - 4), control1: CGPoint(x: x + 5, y: y - 29),
                             control2: CGPoint(x: x + 32, y: y - 23))
            context.addCurve(to: CGPoint(x: x + 33, y: y + 6), control1: CGPoint(x: x + 51, y: y - 5),
                             control2: CGPoint(x: x + 47, y: y + 7))
            context.strokePath()
        }
        if season == .winter {
            drawSnowOnGround(in: context, dark: dark)
            return
        }
        for index in 0..<8 {
            let x = CGFloat(30 + index * 93)
            context.beginPath()
            context.move(to: CGPoint(x: x, y: 451))
            context.addLine(to: CGPoint(x: x - 3, y: 441))
            context.move(to: CGPoint(x: x, y: 451))
            context.addLine(to: CGPoint(x: x + 5, y: 445))
            context.strokePath()
        }
        if season == .spring {
            context.setFillColor(color(dark ? 0xdcc9cd : 0xf7e4e5, alpha: 0.8))
            for (x, y): (CGFloat, CGFloat) in [(123, 440), (309, 441), (588, 440)] {
                context.fillEllipse(in: CGRect(x: x - 2.6, y: y - 3, width: 5.2, height: 4.5))
            }
        }
    }

    private static func drawSnowOnGround(in context: CGContext, dark: Bool) {
        context.setStrokeColor(color(dark ? 0xd4e0e3 : 0xffffff, alpha: dark ? 0.38 : 0.86))
        context.setLineWidth(3.2)
        for (x, y, width): (CGFloat, CGFloat, CGFloat) in [(28, 433, 109), (203, 454, 132), (577, 432, 102)] {
            context.beginPath()
            context.move(to: CGPoint(x: x, y: y))
            context.addQuadCurve(to: CGPoint(x: x + width, y: y - 2),
                control: CGPoint(x: x + width * 0.5, y: y - 8))
            context.strokePath()
        }
        context.setFillColor(color(dark ? 0xe5eff1 : 0xffffff, alpha: dark ? 0.32 : 0.82))
        for (x, y, radius): (CGFloat, CGFloat, CGFloat) in [(119, 204, 1.8), (228, 304, 1.5),
            (327, 180, 1.7), (604, 285, 1.7), (669, 190, 1.4)] {
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private static func skyColor(for season: HomeSeason, dark: Bool) -> UInt32 {
        switch season {
        case .spring: return dark ? 0x334239 : 0xf0f5ef
        case .summer: return dark ? 0x30434a : 0xedf5f7
        case .autumn: return dark ? 0x344238 : 0xeef4f1
        case .winter: return dark ? 0x36424b : 0xecf1f5
        }
    }

    private static func groundColor(for season: HomeSeason, dark: Bool) -> UInt32 {
        switch season {
        case .spring: return dark ? 0x586746 : 0xd7e7d0
        case .summer: return dark ? 0x496548 : 0xd3e5d3
        case .autumn: return dark ? 0x4b5941 : 0xdbe6db
        case .winter: return dark ? 0xabbfc8 : 0xffffff
        }
    }

    private static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: alpha).cgColor
    }
}

private extension HomeSeason {
    var leaves: [UInt32] {
        switch self {
        case .spring: return [0xa8c996, 0xcbd9b5, 0xa2bd91]
        case .summer: return [0x88a47d, 0xb2c3a1, 0x759770]
        case .autumn: return [0xc1b17c, 0xd0b690, 0xb8bb91]
        case .winter: return [] // Winter is drawn as bare branches and snow.
        }
    }
}
