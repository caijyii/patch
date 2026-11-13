// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

/// Selection coordinates use AppKit's lower-left origin.
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    static let hitTolerance: CGFloat = 7
    // Corners take precedence where the horizontal and vertical edge bands meet.
    static let hitTestOrder: [SelectionHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]

    func hitRect(in rect: CGRect) -> CGRect {
        let anchor = point(in: rect)
        let radius = Self.hitTolerance
        switch self {
        case .top, .bottom:
            return CGRect(x: rect.minX - radius, y: anchor.y - radius, width: rect.width + 2 * radius, height: 2 * radius)
        case .left, .right:
            return CGRect(x: anchor.x - radius, y: rect.minY - radius, width: 2 * radius, height: rect.height + 2 * radius)
        default:
            return CGRect(x: anchor.x - radius, y: anchor.y - radius, width: 2 * radius, height: 2 * radius)
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

enum SelectionGeometry {
    static func handle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        guard isFinite(rect), !rect.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        return SelectionHandle.hitTestOrder.first { $0.hitRect(in: rect).contains(point) }
    }

    /// Convert WindowServer's global top-left coordinates to this screen's local coordinates.
    static func windowRect(_ quartzRect: CGRect, primaryTop: CGFloat, screenFrame: CGRect) -> CGRect? {
        guard isFinite(quartzRect), isFinite(screenFrame), primaryTop.isFinite else { return nil }
        let global = CGRect(x: quartzRect.minX, y: primaryTop - quartzRect.maxY,
                            width: quartzRect.width, height: quartzRect.height)
        let clipped = global.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= 16, clipped.height >= 16 else { return nil }
        return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    static func move(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        guard isFinite(rect), isFinite(bounds), delta.width.isFinite, delta.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        // Valid selections retain their size. Oversized input can only fit after clipping its size.
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        return CGRect(x: clamp(rect.minX + delta.width, bounds.minX, bounds.maxX - width),
                      y: clamp(rect.minY + delta.height, bounds.minY, bounds.maxY - height),
                      width: width, height: height)
    }

    static func resize(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint,
                       within bounds: CGRect, minimumSize: CGFloat = 16) -> CGRect {
        guard isFinite(rect), isFinite(bounds), point.x.isFinite, point.y.isFinite,
              bounds.width > 0, bounds.height > 0, minimumSize.isFinite else { return .zero }
        let original = move(rect, by: .zero, within: bounds)
        let minimumWidth = min(max(0, minimumSize), bounds.width)
        let minimumHeight = min(max(0, minimumSize), bounds.height)
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft:
            minX = clamp(point.x, bounds.minX, maxX - minimumWidth)
        case .topRight, .right, .bottomRight:
            maxX = clamp(point.x, minX + minimumWidth, bounds.maxX)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            maxY = clamp(point.y, minY + minimumHeight, bounds.maxY)
        case .bottomLeft, .bottom, .bottomRight:
            minY = clamp(point.y, bounds.minY, maxY - minimumHeight)
        default: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// CGImage crops start at the upper left and use the actual image dimensions, not display scale.
    static func pixelRect(_ rect: CGRect, in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard isFinite(rect), isFinite(bounds), bounds.width > 0, bounds.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return .zero }
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        let pixels = CGRect(x: (clipped.minX - bounds.minX) * scaleX,
                            y: (bounds.maxY - clipped.maxY) * scaleY,
                            width: clipped.width * scaleX, height: clipped.height * scaleY)
        return pixels.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func toolbarFrame(selection: CGRect?, size: CGSize, within bounds: CGRect,
                             gap: CGFloat = 12, backingScaleFactor: CGFloat? = nil) -> CGRect {
        guard isFinite(bounds), size.width.isFinite, size.height.isFinite, gap.isFinite,
              bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let spacing = max(0, gap)
        let centerX = selection?.midX ?? bounds.midX
        let x = clamp(centerX - width / 2, bounds.minX, bounds.maxX - width)
        let y: CGFloat
        if let selection {
            let below = selection.minY - spacing - height
            let above = selection.maxY + spacing
            if below >= bounds.minY {
                y = below
            } else if above + height <= bounds.maxY {
                y = above
            } else {
                y = below
            }
        } else {
            y = bounds.minY + spacing
        }
        let result = CGRect(x: x, y: clamp(y, bounds.minY, bounds.maxY - height),
                            width: width, height: height)
        return backingScaleFactor.map { pixelAlignedFrame(result, within: bounds, backingScaleFactor: $0) } ?? result
    }

    /// Align a floating control's origin to its target display, without changing
    /// its logical-point size or moving it outside the available area.
    static func pixelAlignedFrame(_ rect: CGRect, within bounds: CGRect, backingScaleFactor scale: CGFloat) -> CGRect {
        guard isFinite(rect), isFinite(bounds), scale.isFinite, scale > 0 else { return rect }
        func coordinate(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            let low = ceil(lower * scale) / scale, high = floor(upper * scale) / scale
            guard low <= high else { return lower }
            return clamp((value * scale).rounded() / scale, low, high)
        }
        return CGRect(x: coordinate(rect.minX, lower: bounds.minX, upper: bounds.maxX - rect.width),
                      y: coordinate(rect.minY, lower: bounds.minY, upper: bounds.maxY - rect.height),
                      width: rect.width, height: rect.height)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height >= 0
    }
}
