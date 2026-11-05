// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// A static, opaque wall background shared by functional windows.
@MainActor
enum WindowAmbientBackground {
    nonisolated static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.135, green: 0.135, blue: 0.135, alpha: 1) : .white
    }

    static func draw(in view: NSView, radiusScale: CGFloat = 1) {
        let bounds = view.bounds
        color.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let light = dark ? NSColor(srgbRed: 1, green: 0.84, blue: 0.60, alpha: 0.12)
                         : NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 0.13)
        guard let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [light.cgColor, light.withAlphaComponent(dark ? 0.035 : 0.045).cgColor,
                     light.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1]) else { return }
        context.saveGState()
        context.clip(to: bounds)
        let topInset = bounds.height * 0.16
        let centerY = view.isFlipped ? bounds.minY + topInset : bounds.maxY - topInset
        context.translateBy(x: bounds.minX + bounds.width * 0.12, y: centerY)
        context.scaleBy(x: 1, y: 0.88)
        context.drawRadialGradient(glow, startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: bounds.width * 0.68 * radiusScale, options: [])
        context.restoreGState()
    }
}

@MainActor
final class WindowAmbientView: NSView {
    var glowRadiusScale: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        WindowAmbientBackground.draw(in: self, radiusScale: glowRadiusScale)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
