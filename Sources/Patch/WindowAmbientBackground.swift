// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit

/// An opaque seasonal wall shared by Home and functional windows.
@MainActor
enum WindowAmbientBackground {
    nonisolated static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.135, green: 0.135, blue: 0.135, alpha: 1) : .white
    }

    private static let refresh = AmbientSeasonRefresh()

    static func lightTint(for season: HomeSeason) -> NSColor {
        switch season {
        case .spring: return NSColor(srgbRed: 0.55, green: 0.72, blue: 0.47, alpha: 0.13)
        case .summer: return NSColor(srgbRed: 0.36, green: 0.72, blue: 0.65, alpha: 0.13)
        case .autumn: return NSColor(srgbRed: 1, green: 0.78, blue: 0.35, alpha: 0.13)
        case .winter: return NSColor(srgbRed: 0.92, green: 0.79, blue: 0.56, alpha: 0.10)
        }
    }

    static func draw(in view: NSView, radiusScale: CGFloat = 1, season: HomeSeason = .current()) {
        refresh.views.add(view)
        let bounds = view.bounds
        color.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let light = dark ? NSColor(srgbRed: 1, green: 0.84, blue: 0.60, alpha: 0.12)
                         : lightTint(for: season)
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

/// Weak registrations keep open windows in sync without retaining them or polling.
@MainActor
private final class AmbientSeasonRefresh: NSObject {
    let views = NSHashTable<NSView>.weakObjects()
    override init() {
        super.init()
        for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemClockDidChange,
                     .NSSystemTimeZoneDidChange, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(invalidate),
            name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func invalidate(_ notification: Notification) {
        views.allObjects.forEach { $0.needsDisplay = true }
    }
}
