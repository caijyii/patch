// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

/// Tracks a viewport in document coordinates. Rejected frames never change pixels or position.
final class ScrollStitcher {
    enum Direction: Equatable { case down, up }
    enum Update: Equatable {
        case started(height: Int)
        case appended(rows: Int, height: Int)
        case revisited(height: Int)
        case duplicate
        case paused(String)
        case limitReached(String)
    }

    struct Limits {
        var maximumHeight = 20_000
        var maximumWorkingBytes = 128 * 1_024 * 1_024
    }

    private struct Frame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private struct Match {
        let displacement: Int
        let horizontal: Int
        let error: Double
        let mismatchFraction: Double
        let samples: Int
    }

    private let limits: Limits
    private var previous: Frame?
    private var output = Data()
    private(set) var width = 0
    private(set) var height = 0
    private(set) var lastOrigin = 0
    private(set) var minOrigin = 0
    var maxOrigin: Int { minOrigin + height }

    init(limits: Limits = Limits(), direction: Direction = .down) {
        self.limits = limits
        // Retain the old call-site contract; image matches now determine either direction.
        _ = direction
    }

    func append(_ image: CGImage) -> Update {
        guard image.width > 0, image.height > 0,
              image.width <= 8_192, image.height <= limits.maximumHeight,
              image.height <= Int.max / max(1, image.width * 4) else {
            return .limitReached("截图区域过大，请缩小区域后重新开始。")
        }
        let inputBytes = image.width * image.height * 4
        guard inputBytes <= limits.maximumWorkingBytes / 4 else {
            return .limitReached("截图区域过大，请缩小区域后重新开始。")
        }
        guard let frame = decode(image) else { return .paused("无法读取这一帧，请重试。") }
        guard let previous else {
            width = frame.width
            height = frame.height
            self.previous = frame
            lastOrigin = 0
            minOrigin = 0
            output = Data(frame.pixels)
            return .started(height: height)
        }
        guard frame.width == previous.width, frame.height == previous.height else {
            return .paused("截图区域尺寸发生变化，请结束当前长截图后重新框选。")
        }

        if previous.pixels == frame.pixels { return .duplicate }
        if let same = score(previous, frame, displacement: 0, horizontal: 0),
           same.error <= 0.010, same.mismatchFraction <= 0.025 {
            return .duplicate
        }

        let maximumDisplacement = Int(Double(frame.height) * 0.78)
        guard maximumDisplacement >= 3 else { return .paused("截图区域太矮，无法可靠识别重叠内容。") }
        var verticalMatches: [Match] = []
        verticalMatches.reserveCapacity(maximumDisplacement * 2)
        for displacement in -maximumDisplacement...maximumDisplacement where abs(displacement) >= 3 {
            if let match = score(previous, frame, displacement: displacement, horizontal: 0) {
                verticalMatches.append(match)
            }
        }
        verticalMatches.sort { $0.error < $1.error }
        guard let best = verticalMatches.first else {
            return .paused("画面缺少可识别的细节。请让文字或图案进入区域，再缓慢滚动。")
        }

        // Inspect horizontal motion before accepting a merely approximate vertical match.
        // We deliberately do not hide missing edge pixels with a crop or fabricated fill.
        if best.error > 0.010,
           let shifted = horizontalMatch(previous, frame, maximumDisplacement: maximumDisplacement),
           shifted.error < 0.035,
           shifted.mismatchFraction < 0.12,
           shifted.error + 0.010 < best.error {
            return .paused("检测到约 \(abs(shifted.horizontal)) 像素的左右偏移。请回到上一段位置并回正，或完成已有结果后重新截图。")
        }

        guard best.error <= 0.050, best.mismatchFraction <= 0.14 else {
            return .paused("没有找到可靠的重叠内容。请回到上一段并慢一点滚动；动态画面或固定顶栏也可能影响拼接。")
        }
        let ambiguityDistance = max(4, frame.height / 100)
        if let alternative = verticalMatches.first(where: {
            abs($0.displacement - best.displacement) >= ambiguityDistance
        }), alternative.error - best.error < 0.020,
           !resolvesAmbiguity(previous, frame, best: best, candidates: verticalMatches,
                              minimumSeparation: ambiguityDistance) {
            return .paused("画面重复度较高，无法确定滚动距离。请缩小滚动步幅，或换一个包含更多文字的区域。")
        }

        let newOrigin = lastOrigin + best.displacement
        guard agreesWithCoverage(frame, origin: newOrigin) else {
            return .paused("当前画面与已拼接内容不一致。请回到上一段位置，等待内容稳定后继续。")
        }
        let newMinimum = min(minOrigin, newOrigin)
        let newMaximum = max(maxOrigin, newOrigin + frame.height)
        let newHeight = newMaximum - newMinimum
        guard newHeight <= limits.maximumHeight else {
            return .limitReached("已达到长截图高度或内存上限。可以完成并保存已有结果，再分段截图。")
        }
        if newHeight == height {
            self.previous = frame
            lastOrigin = newOrigin
            return .revisited(height: height)
        }
        // Prepending can retain old output, a new output, an export, and both decoded frames.
        let estimatedWorkingBytes = newHeight * width * 4 * 3 + inputBytes * 2
        guard newHeight <= limits.maximumHeight,
              estimatedWorkingBytes <= limits.maximumWorkingBytes else {
            return .limitReached("已达到长截图高度或内存上限。可以完成并保存已有结果，再分段截图。")
        }
        let topRows = minOrigin - newMinimum
        let bottomRows = newMaximum - maxOrigin
        if topRows > 0 {
            var extended = Data(capacity: newHeight * width * 4)
            extended.append(contentsOf: frame.pixels.prefix(topRows * width * 4))
            extended.append(output)
            output = extended
        } else if bottomRows > 0 {
            let firstNewByte = (frame.height - bottomRows) * width * 4
            frame.pixels.withUnsafeBytes { bytes in
                output.append(bytes.bindMemory(to: UInt8.self).baseAddress! + firstNewByte,
                              count: bottomRows * width * 4)
            }
        }
        height = newHeight
        minOrigin = newMinimum
        lastOrigin = newOrigin
        self.previous = frame
        return .appended(rows: topRows + bottomRows, height: height)
    }

    func image() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                            .union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func preview(maximumDimension: CGFloat = 500) -> CGImage? {
        guard let full = image() else { return nil }
        let scale = min(1, maximumDimension / CGFloat(max(width, height)))
        let previewWidth = max(1, Int(CGFloat(width) * scale))
        let previewHeight = max(1, Int(CGFloat(height) * scale))
        guard let context = CGContext(data: nil, width: previewWidth, height: previewHeight,
                                      bitsPerComponent: 8, bytesPerRow: previewWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
        return context.makeImage()
    }

    private func decode(_ image: CGImage) -> Frame? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard succeeded else { return nil }
        return Frame(width: image.width, height: image.height, pixels: pixels)
    }

    private func resolvesAmbiguity(_ older: Frame, _ newer: Frame, best: Match,
                                   candidates: [Match], minimumSeparation: Int) -> Bool {
        // A sparse grid can miss the differing digits in otherwise repeated lines.
        // Recheck every plausible alternative, not just the sparse runner-up.
        let alternatives = candidates.filter {
            abs($0.displacement - best.displacement) >= minimumSeparation &&
                $0.error <= 0.050 && $0.mismatchFraction <= 0.14
        }
        let comparisons = alternatives + [best]
        let pixelCost = comparisons.reduce(0) {
            $0 + older.width * (older.height - abs($1.displacement))
        }
        // Keep pathological, highly repetitive regions bounded. Exhausting the
        // budget preserves the existing pause instead of guessing from a subset.
        guard pixelCost <= 32_000_000,
              let detailedBest = score(older, newer, displacement: best.displacement,
                                       horizontal: 0, dense: true),
              detailedBest.error <= 0.050, detailedBest.mismatchFraction <= 0.14 else { return false }
        for candidate in alternatives {
            guard let detailed = score(older, newer, displacement: candidate.displacement,
                                       horizontal: 0, dense: true),
                  detailed.error - detailedBest.error >= 0.020 else { return false }
        }
        return true
    }

    private func score(_ older: Frame, _ newer: Frame, displacement: Int, horizontal: Int,
                       coarse: Bool = false, dense: Bool = false) -> Match? {
        let overlap = older.height - abs(displacement)
        let stepX = dense ? 1 : max(2, older.width / (coarse ? 20 : 48))
        let stepY = dense ? 1 : max(2, overlap / (coarse ? 20 : 64))
        let xStart = max(2, -horizontal + 2)
        let xEnd = min(older.width - 2, newer.width - horizontal - 2)
        guard overlap > 8, xStart < xEnd else { return nil }
        var error = 0
        var mismatch = 0
        var samples = 0
        let yStart = max(0, -displacement)
        for y in stride(from: yStart + 2, to: yStart + overlap - 2, by: stepY) {
            for x in stride(from: xStart, to: xEnd, by: stepX) {
                let oldIndex = ((y + displacement) * older.width + x) * 4
                let newIndex = (y * newer.width + x + horizontal) * 4
                // Flat backgrounds cannot identify a unique displacement. Sample edges/detail.
                let edgeX = abs(Int(older.pixels[oldIndex]) - Int(older.pixels[oldIndex + 4]))
                let edgeY = abs(Int(older.pixels[oldIndex]) - Int(older.pixels[oldIndex + older.width * 4]))
                let newEdgeX = abs(Int(newer.pixels[newIndex]) - Int(newer.pixels[newIndex + 4]))
                guard max(edgeX, edgeY, newEdgeX) >= 10 else { continue }
                let difference = abs(Int(older.pixels[oldIndex]) - Int(newer.pixels[newIndex])) +
                    abs(Int(older.pixels[oldIndex + 1]) - Int(newer.pixels[newIndex + 1])) +
                    abs(Int(older.pixels[oldIndex + 2]) - Int(newer.pixels[newIndex + 2]))
                error += difference
                if difference > 90 { mismatch += 1 }
                samples += 1
            }
        }
        guard samples >= (coarse ? 12 : 24) else { return nil }
        return Match(displacement: displacement, horizontal: horizontal,
                     error: Double(error) / Double(samples * 765),
                     mismatchFraction: Double(mismatch) / Double(samples), samples: samples)
    }

    private func horizontalMatch(_ older: Frame, _ newer: Frame, maximumDisplacement: Int) -> Match? {
        let verticalStep = max(1, older.height / 100)
        var coarseMatches: [Match] = []
        for horizontal in stride(from: -16, through: 16, by: 2) where horizontal != 0 {
            for displacement in stride(from: -maximumDisplacement, through: maximumDisplacement, by: verticalStep) {
                if let match = score(older, newer, displacement: displacement, horizontal: horizontal, coarse: true) {
                    coarseMatches.append(match)
                }
            }
        }
        coarseMatches.sort { $0.error < $1.error }
        var best: Match?
        for candidate in coarseMatches.prefix(5) {
            for horizontal in (candidate.horizontal - 1)...(candidate.horizontal + 1) where horizontal != 0 {
                for displacement in max(-maximumDisplacement, candidate.displacement - verticalStep)...min(maximumDisplacement, candidate.displacement + verticalStep) {
                    if let match = score(older, newer, displacement: displacement, horizontal: horizontal),
                       best == nil || match.error < best!.error { best = match }
                }
            }
        }
        return best
    }

    private func agreesWithCoverage(_ frame: Frame, origin: Int) -> Bool {
        let start = max(origin, minOrigin)
        let end = min(origin + frame.height, maxOrigin)
        guard end - start > 8 else { return false }
        let stepX = max(2, width / 48)
        let stepY = max(2, (end - start) / 64)
        return output.withUnsafeBytes { bytes in
            let stored = bytes.bindMemory(to: UInt8.self)
            var error = 0
            var mismatches = 0
            var samples = 0
            for y in stride(from: start + 2, to: end - 2, by: stepY) {
                for x in stride(from: 2, to: width - 2, by: stepX) {
                    let oldIndex = ((y - minOrigin) * width + x) * 4
                    let newIndex = ((y - origin) * width + x) * 4
                    let difference = abs(Int(stored[oldIndex]) - Int(frame.pixels[newIndex]))
                        + abs(Int(stored[oldIndex + 1]) - Int(frame.pixels[newIndex + 1]))
                        + abs(Int(stored[oldIndex + 2]) - Int(frame.pixels[newIndex + 2]))
                    error += difference
                    if difference > 90 { mismatches += 1 }
                    samples += 1
                }
            }
            return samples >= 24 && Double(error) / Double(samples * 765) <= 0.050
                && Double(mismatches) / Double(samples) <= 0.14
        }
    }
}
