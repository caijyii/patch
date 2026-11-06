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
        var support: Double = 1
        var confidence: Double { support - error * 2 }
    }

    private let limits: Limits
    private var previous: Frame?
    private struct Segment {
        let start: Int
        let end: Int
        let sourceOrigin: Int
    }
    private var segments: [Segment] = []
    private var output = Data()
    private var fixedScreenPixels: [UInt8] = []
    private var usesBodySeams = false
    private(set) var contentRect: CGRect?
    private(set) var scrollAnchor: CGPoint?
    private(set) var outputRevision = 0
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
            segments = [Segment(start: 0, end: height, sourceOrigin: 0)]
            contentRect = CGRect(x: 0, y: 0, width: width, height: height)
            scrollAnchor = CGPoint(x: width / 2, y: height / 2)
            outputRevision += 1
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

        guard output.count + fixedScreenPixels.count + inputBytes * 3 <= limits.maximumWorkingBytes else {
            return .limitReached("已达到长截图高度或内存上限。可以完成并保存已有结果，再分段截图。")
        }
        let stationary = stationaryPixels(previous, frame)
        var motionExclusions = motionExclusions(stationary, width: frame.width, height: frame.height)
        if fixedScreenPixels.count == stationary.count {
            for i in motionExclusions.indices where fixedScreenPixels[i] != 0 { motionExclusions[i] = 1 }
        }
        let maximumDisplacement = Int(Double(frame.height) * 0.78)
        guard maximumDisplacement >= 3 else { return .paused("截图区域太矮，无法可靠识别重叠内容。") }
        var verticalMatches: [Match] = []
        verticalMatches.reserveCapacity(maximumDisplacement * 2)
        for displacement in -maximumDisplacement...maximumDisplacement where abs(displacement) >= 3 {
            if let match = score(previous, frame, displacement: displacement, horizontal: 0, excluding: motionExclusions) {
                verticalMatches.append(match)
            }
        }
        verticalMatches.sort { $0.error < $1.error }
        guard var best = verticalMatches.first else {
            return .paused("画面缺少可识别的细节。请让文字或图案进入区域，再缓慢滚动。")
        }

        // Inspect horizontal motion before accepting a merely approximate vertical match.
        // We deliberately do not hide missing edge pixels with a crop or fabricated fill.
        if best.error > 0.010,
           let shifted = horizontalMatch(previous, frame, maximumDisplacement: maximumDisplacement, excluding: motionExclusions),
           shifted.error < 0.035,
           shifted.mismatchFraction < 0.12,
           shifted.error + 0.010 < best.error {
            return .paused("检测到约 \(abs(shifted.horizontal)) 像素的左右偏移。请回到上一段位置并回正，或完成已有结果后重新截图。")
        }

        var localized = false
        if best.error > 0.050 || best.mismatchFraction > 0.14 {
            // A changing anchored surface can invalidate a minority of blocks.
            // Require a majority consensus among textured body blocks instead.
            let localMatches = (-maximumDisplacement...maximumDisplacement).compactMap { displacement -> Match? in
                guard abs(displacement) >= 3 else { return nil }
                return score(previous, frame, displacement: displacement, horizontal: 0,
                             excluding: motionExclusions, localized: true)
            }.sorted { $0.confidence > $1.confidence }
            if let localBest = localMatches.first {
                localized = true; verticalMatches = localMatches; best = localBest
            }
        }
        guard best.error <= 0.050, best.mismatchFraction <= 0.14 else {
            return .paused("没有找到可靠的重叠内容。请回到上一段并慢一点滚动；动态画面或固定顶栏也可能影响拼接。")
        }
        let ambiguityDistance = max(4, frame.height / 100)
        if let alternative = verticalMatches.first(where: {
            abs($0.displacement - best.displacement) >= ambiguityDistance
        }), (localized ? best.confidence - alternative.confidence : alternative.error - best.error) < 0.020,
           !resolvesAmbiguity(previous, frame, best: best, candidates: verticalMatches,
                              minimumSeparation: ambiguityDistance, excluding: motionExclusions, localized: localized) {
            return .paused("画面重复度较高，无法确定滚动距离。请缩小滚动步幅，或换一个包含更多文字的区域。")
        }

        var inferred = fixedPixels(previous, frame, stationary: stationary, displacement: best.displacement)
        if localized {
            let overlapStart = max(0, -best.displacement), overlapEnd = min(frame.height, frame.height - best.displacement)
            for y in overlapStart..<overlapEnd { for x in 0..<frame.width {
                let old = (y + best.displacement) * frame.width + x, new = y * frame.width + x
                let difference = (0..<3).reduce(0) { $0 + abs(Int(previous.pixels[old * 4 + $1]) - Int(frame.pixels[new * 4 + $1])) }
                if difference > 30 { inferred[old] = 1; inferred[new] = 1 }
            } }
        }
        var knownFixed = inferred
        if fixedScreenPixels.count == inferred.count {
            for i in fixedScreenPixels.indices where fixedScreenPixels[i] != 0 && inferred[i] == 0 {
                let y = i / frame.width, x = i % frame.width
                let shifted = y + best.displacement, reverse = y - best.displacement
                func agrees(_ old: Int, _ new: Int) -> Bool {
                    (0..<3).reduce(0) { $0 + abs(Int(previous.pixels[old * 4 + $1]) - Int(frame.pixels[new * 4 + $1])) } <= 6
                }
                let nowMovesWithDocument = (shifted >= 0 && shifted < frame.height && agrees(shifted * frame.width + x, i)) ||
                    (reverse >= 0 && reverse < frame.height && agrees(i, reverse * frame.width + x))
                if !nowMovesWithDocument { knownFixed[i] = 1 }
            }
        }
        // Released/relocated surfaces stop masking the body once it follows the
        // measured translation again; masks do not grow for the whole session.
        for i in knownFixed.indices { motionExclusions[i] = knownFixed[i] != 0 || motionExclusions[i] != 0 ? 1 : 0 }
        let bodySeam = trustedBodySeam(previous, frame, displacement: best.displacement,
                                       stationary: stationary, localized: localized)
        guard !bodySeam.needed || bodySeam.offset != nil else {
            return .paused("没有找到可靠的重叠正文。请回到上一段并慢一点滚动。")
        }
        return appendFrame(frame, origin: lastOrigin + best.displacement, inputBytes: inputBytes,
                           fixedMask: knownFixed, motionMask: motionExclusions,
                           seam: bodySeam.offset.map { lastOrigin + best.displacement + $0 },
                           bodyAnchor: bodySeam.anchor)
    }

    func image() -> CGImage? { renderedImage() }

    private func renderedImage() -> CGImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                            .union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func preview(maximumDimension: CGFloat = 500) -> CGImage? {
        guard let full = renderedImage() else { return nil }
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
                                   candidates: [Match], minimumSeparation: Int, excluding mask: [UInt8], localized: Bool = false) -> Bool {
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
                                       horizontal: 0, dense: true, excluding: mask, localized: localized),
              detailedBest.error <= 0.050, detailedBest.mismatchFraction <= 0.14 else { return false }
        for candidate in alternatives {
            guard let detailed = score(older, newer, displacement: candidate.displacement,
                                       horizontal: 0, dense: true, excluding: mask, localized: localized),
                  (localized ? detailedBest.confidence - detailed.confidence : detailed.error - detailedBest.error) >= 0.020 else { return false }
        }
        return true
    }

    private func score(_ older: Frame, _ newer: Frame, displacement: Int, horizontal: Int,
                       coarse: Bool = false, dense: Bool = false, excluding mask: [UInt8]? = nil,
                       localized: Bool = false) -> Match? {
        let overlap = older.height - abs(displacement)
        let stepX = dense ? 1 : max(2, older.width / (coarse ? 20 : 48))
        let stepY = dense ? 1 : max(2, overlap / (coarse ? 20 : 64))
        let xStart = max(2, -horizontal + 2)
        let xEnd = min(older.width - 2, newer.width - horizontal - 2)
        guard overlap > 8, xStart < xEnd else { return nil }
        var error = 0
        var mismatch = 0
        var samples = 0
        var tileErrors = [Int](repeating: 0, count: 16), tileMismatches = tileErrors, tileSamples = tileErrors
        let yStart = max(0, -displacement)
        for y in stride(from: yStart + 2, to: yStart + overlap - 2, by: stepY) {
            for x in stride(from: xStart, to: xEnd, by: stepX) {
                let oldIndex = ((y + displacement) * older.width + x) * 4
                let newIndex = (y * newer.width + x + horizontal) * 4
                if let mask, mask[oldIndex / 4] != 0 || mask[newIndex / 4] != 0 { continue }
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
                if localized {
                    let tile = min(3, (y - yStart) * 4 / overlap) * 4 + min(3, x * 4 / older.width)
                    tileErrors[tile] += difference; tileSamples[tile] += 1
                    if difference > 90 { tileMismatches[tile] += 1 }
                }
            }
        }
        guard samples >= (coarse ? 12 : 24) else { return nil }
        if localized {
            let populated = (0..<16).filter { tileSamples[$0] >= 6 }
            let reliable = populated.filter { Double(tileErrors[$0]) / Double(tileSamples[$0] * 765) <= 0.050 &&
                Double(tileMismatches[$0]) / Double(tileSamples[$0]) <= 0.14 }
            guard populated.count >= 4, reliable.count >= 3,
                  reliable.count * 2 >= populated.count else { return nil }
            let keptSamples = reliable.reduce(0) { $0 + tileSamples[$1] }
            let keptError = reliable.reduce(0) { $0 + tileErrors[$1] }
            let keptMismatches = reliable.reduce(0) { $0 + tileMismatches[$1] }
            return Match(displacement: displacement, horizontal: horizontal,
                         error: Double(keptError) / Double(keptSamples * 765),
                         mismatchFraction: Double(keptMismatches) / Double(keptSamples), samples: keptSamples,
                         support: Double(reliable.count) / Double(populated.count))
        }
        return Match(displacement: displacement, horizontal: horizontal,
                     error: Double(error) / Double(samples * 765),
                     mismatchFraction: Double(mismatch) / Double(samples), samples: samples)
    }

    private func horizontalMatch(_ older: Frame, _ newer: Frame, maximumDisplacement: Int, excluding mask: [UInt8]) -> Match? {
        let verticalStep = max(1, older.height / 100)
        var coarseMatches: [Match] = []
        for horizontal in stride(from: -16, through: 16, by: 2) where horizontal != 0 {
            for displacement in stride(from: -maximumDisplacement, through: maximumDisplacement, by: verticalStep) {
                if let match = score(older, newer, displacement: displacement, horizontal: horizontal, coarse: true, excluding: mask) {
                    coarseMatches.append(match)
                }
            }
        }
        coarseMatches.sort { $0.error < $1.error }
        var best: Match?
        for candidate in coarseMatches.prefix(5) {
            for horizontal in (candidate.horizontal - 1)...(candidate.horizontal + 1) where horizontal != 0 {
                for displacement in max(-maximumDisplacement, candidate.displacement - verticalStep)...min(maximumDisplacement, candidate.displacement + verticalStep) {
                    if let match = score(older, newer, displacement: displacement, horizontal: horizontal, excluding: mask),
                       best == nil || match.error < best!.error { best = match }
                }
            }
        }
        return best
    }

    private func appendFrame(_ frame: Frame, origin: Int, inputBytes: Int,
                             fixedMask: [UInt8], motionMask: [UInt8], seam: Int?, bodyAnchor: CGPoint?) -> Update {
        guard agreesWithRevisitedCoverage(frame, origin: origin, fixedMask: fixedMask) else {
            return .paused("当前画面与已拼接内容不一致。请回到上一段位置，等待内容稳定后继续。")
        }
        let newMinimum = min(minOrigin, origin)
        let newMaximum = max(maxOrigin, origin + frame.height)
        let newHeight = newMaximum - newMinimum
        guard newHeight <= limits.maximumHeight else {
            return .limitReached("已达到长截图高度或内存上限。可以完成并保存已有结果，再分段截图。")
        }
        if newHeight == height {
            previous = frame; lastOrigin = origin; fixedScreenPixels = fixedMask
            usesBodySeams = usesBodySeams || seam != nil
            scrollAnchor = bodyAnchor ?? safeAnchor(in: contentRect ?? .zero, mask: motionMask, frameWidth: frame.width) ?? scrollAnchor
            return .revisited(height: height)
        }
        // Hard seams copy only newly exposed rows, without alpha blending or repair.
        // The export-sized reserve also covers temporary per-input matching masks.
        guard newHeight * width * 12 + inputBytes * 2 <= limits.maximumWorkingBytes else {
            return .limitReached("已达到长截图高度或内存上限。可以完成并保存已有结果，再分段截图。")
        }
        let topRows = minOrigin - newMinimum, bottomRows = newMaximum - maxOrigin
        if topRows > 0 {
            let join = min(maxOrigin, max(minOrigin, seam ?? minOrigin))
            var extended = Data(capacity: newHeight * width * 4)
            extended.append(contentsOf: frame.pixels.prefix((join - origin) * width * 4))
            extended.append(output.suffix((maxOrigin - join) * width * 4)); output = extended
            segments = [Segment(start: newMinimum, end: join, sourceOrigin: origin)] + segments.compactMap {
                let start = max(join, $0.start)
                return start < $0.end ? Segment(start: start, end: $0.end, sourceOrigin: $0.sourceOrigin) : nil
            }
        } else if bottomRows > 0 {
            let join = min(maxOrigin, max(minOrigin, seam ?? maxOrigin))
            output = Data(output.prefix((join - minOrigin) * width * 4))
            output.append(contentsOf: frame.pixels.suffix((newMaximum - join) * width * 4))
            segments = segments.compactMap {
                let end = min(join, $0.end)
                return $0.start < end ? Segment(start: $0.start, end: end, sourceOrigin: $0.sourceOrigin) : nil
            } + [Segment(start: join, end: newMaximum, sourceOrigin: origin)]
        }
        height = newHeight; minOrigin = newMinimum; lastOrigin = origin
        previous = frame; fixedScreenPixels = fixedMask; outputRevision += 1
        usesBodySeams = usesBodySeams || seam != nil
        scrollAnchor = bodyAnchor ?? safeAnchor(in: contentRect ?? .zero, mask: motionMask, frameWidth: frame.width) ?? scrollAnchor
        return .appended(rows: topRows + bottomRows, height: height)
    }

    private func trustedBodySeam(_ older: Frame, _ newer: Frame, displacement: Int,
                                 stationary: [UInt8], localized: Bool) -> (needed: Bool, offset: Int?, anchor: CGPoint?) {
        let width = older.width, height = older.height
        func difference(_ old: Int, _ new: Int) -> Int {
            (0..<3).reduce(0) { $0 + abs(Int(older.pixels[old * 4 + $1]) - Int(newer.pixels[new * 4 + $1])) }
        }
        func stationaryRow(_ y: Int) -> Bool { (0..<width).allSatisfy { stationary[y * width + $0] != 0 } }
        var top = 0, bottom = height
        while top < height && stationaryRow(top) { top += 1 }
        while bottom > top && stationaryRow(bottom - 1) { bottom -= 1 }
        var fixedEdge = false
        for y in 0..<height where y < top || y >= bottom {
            for x in stride(from: 0, to: width, by: max(1, width / 80)) {
                let shifted = y + displacement, reverse = y - displacement
                if (shifted >= 0 && shifted < height && difference(shifted * width + x, y * width + x) > 30) ||
                    (reverse >= 0 && reverse < height && difference(y * width + x, reverse * width + x) > 30) {
                    fixedEdge = true; break
                }
            }
            if fixedEdge { break }
        }
        guard fixedEdge || localized || usesBodySeams else { return (false, nil, nil) }
        let start = max(0, -displacement), end = min(height, height - displacement)
        let middle = (start + end) / 2
        var chosen: CGPoint?
        for y in start..<end {
            var good = 0, samples = 0, nearestX: Int?
            for x in 1..<(width - 1) {
                let old = (y + displacement) * width + x, new = y * width + x
                // A seam needs actual moving detail. Flat or screen-anchored rows
                // cannot prove that the old footer has been replaced by document.
                if stationary[old] != 0 && stationary[new] != 0 { continue }
                samples += 1
                if difference(old, new) <= 6 {
                    good += 1
                    if nearestX == nil || abs(x - width / 2) < abs((nearestX ?? 0) - width / 2) { nearestX = x }
                }
            }
            guard good >= 3, good * 5 >= samples * 4, let x = nearestX else { continue }
            if chosen == nil || abs(y - middle) < abs(Int(chosen?.y ?? 0) - middle) { chosen = CGPoint(x: x, y: y) }
        }
        return (true, chosen.map { Int($0.y) }, chosen)
    }

    private func agreesWithRevisitedCoverage(_ frame: Frame, origin: Int, fixedMask: [UInt8]) -> Bool {
        let start = max(origin, minOrigin), end = min(origin + frame.height, maxOrigin)
        guard end - start > 8 else { return false }
        return output.withUnsafeBytes { storage in
            let bytes = storage.bindMemory(to: UInt8.self)
            var error = 0, mismatches = 0, samples = 0
            for y in stride(from: start + 2, to: end - 2, by: max(2, (end - start) / 64)) {
                // The measured overlap already establishes this region's motion.
                // Check only older document coverage newly revisited by this frame.
                if y >= lastOrigin && y < lastOrigin + frame.height { continue }
                guard let segment = segments.first(where: { y >= $0.start && y < $0.end }) else { return false }
                for x in stride(from: 2, to: width - 2, by: max(2, width / 48)) {
                    if fixedMask[(y - origin) * width + x] != 0 ||
                        fixedMask[(y - segment.sourceOrigin) * width + x] != 0 { continue }
                    let a = ((y - minOrigin) * width + x) * 4
                    let b = ((y - origin) * frame.width + x) * 4
                    let difference = abs(Int(bytes[a]) - Int(frame.pixels[b]))
                        + abs(Int(bytes[a + 1]) - Int(frame.pixels[b + 1]))
                        + abs(Int(bytes[a + 2]) - Int(frame.pixels[b + 2]))
                    error += difference; if difference > 90 { mismatches += 1 }; samples += 1
                }
            }
            return samples < 24 || (Double(error) / Double(samples * 765) <= 0.050
                && Double(mismatches) / Double(samples) <= 0.14)
        }
    }

    private func stationaryPixels(_ older: Frame, _ newer: Frame) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: older.width * older.height)
        for pixel in result.indices {
            let i = pixel * 4
            let difference = abs(Int(older.pixels[i]) - Int(newer.pixels[i]))
                + abs(Int(older.pixels[i + 1]) - Int(newer.pixels[i + 1]))
                + abs(Int(older.pixels[i + 2]) - Int(newer.pixels[i + 2]))
            if difference <= 6 { result[pixel] = 1 }
        }
        return result
    }

    private func motionExclusions(_ stationary: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: stationary.count)
        // Identical glyph fragments are useful negative evidence for other scroll
        // distances. Only exclude sustained stationary surfaces, not every matching
        // black/white pixel in a text page.
        for x in 0..<width {
            var y = 0
            while y < height {
                if stationary[y * width + x] == 0 { y += 1; continue }
                let start = y
                while y < height && stationary[y * width + x] != 0 { y += 1 }
                if y - start >= 16 { for row in start..<y { result[row * width + x] = 1 } }
            }
        }
        return result
    }

    private func fixedPixels(_ older: Frame, _ newer: Frame, stationary: [UInt8], displacement: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: stationary.count)
        func disagrees(_ a: Int, _ b: Int) -> Bool {
            let i = a * 4, j = b * 4
            return abs(Int(older.pixels[i]) - Int(newer.pixels[j]))
                + abs(Int(older.pixels[i + 1]) - Int(newer.pixels[j + 1]))
                + abs(Int(older.pixels[i + 2]) - Int(newer.pixels[j + 2])) > 30
        }
        // Stationary surfaces contradicted by document motion are matching
        // exclusions only. Their original pixels remain in the full-width output.
        for x in 0..<older.width {
            var y = 0
            while y < older.height {
                guard stationary[y * older.width + x] != 0 else { y += 1; continue }
                let start = y
                var evidence = false
                while y < older.height && stationary[y * older.width + x] != 0 {
                    let shifted = y + displacement, reverse = y - displacement
                    if shifted >= 0 && shifted < older.height,
                       disagrees(shifted * older.width + x, y * older.width + x) { evidence = true }
                    if reverse >= 0 && reverse < older.height,
                       disagrees(y * older.width + x, reverse * older.width + x) { evidence = true }
                    y += 1
                }
                if evidence && y - start >= 3 {
                    for row in start..<y { result[row * older.width + x] = 1 }
                }
            }
        }
        return result
    }

    private func safeAnchor(in rect: CGRect, mask: [UInt8], frameWidth: Int) -> CGPoint? {
        let cx = Int(rect.midX), cy = Int(rect.midY)
        func candidate(_ x: Int, _ y: Int) -> CGPoint? {
            guard x >= Int(rect.minX) + 8, x < Int(rect.maxX) - 8,
                  y >= Int(rect.minY) + 8, y < Int(rect.maxY) - 8 else { return nil }
            guard (-6...6).allSatisfy({ dy in
                (-6...6).allSatisfy { dx in mask[(y + dy) * frameWidth + x + dx] == 0 }
            }) else { return nil }
            return CGPoint(x: x, y: y)
        }
        if let center = candidate(cx, cy) { return center }
        // Usually the center or the first clear ring succeeds; avoid scanning
        // every 13×13 neighborhood of a large capture on each accepted frame.
        for radius in stride(from: 4, through: Int(max(rect.width, rect.height)), by: 4) {
            for offset in stride(from: -radius, through: radius, by: 4) {
                if let point = candidate(cx + offset, cy - radius) ?? candidate(cx + offset, cy + radius) { return point }
            }
            for offset in stride(from: -radius + 4, to: radius, by: 4) {
                if let point = candidate(cx - radius, cy + offset) ?? candidate(cx + radius, cy + offset) { return point }
            }
        }
        return nil
    }
}
