import XCTest
import Foundation
import CoreGraphics
@testable import Patch

final class ScrollStitcherTests: XCTestCase {
    private func image(width: Int = 96, height: Int = 90, top: Int, horizontal: Int = 0,
                       seed: UInt32 = 19) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Coordinate-based noise gives each row and column a unique deterministic signature.
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt32(truncatingIfNeeded: x + horizontal) &* 747_796_405 ^
                    UInt32(truncatingIfNeeded: y + top) &* 2_891_336_453 ^ seed
                value = (value ^ (value >> 16)) &* 2_246_822_519
                let index = (y * width + x) * 4
                bytes[index] = UInt8(truncatingIfNeeded: value)
                bytes[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[index + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testDownwardScrollProducesExactFullImage() {
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.append(image(top: 0)), .started(height: 90))
        XCTAssertEqual(stitcher.append(image(top: 27)), .appended(rows: 27, height: 117))
        XCTAssertEqual(stitcher.append(image(top: 58)), .appended(rows: 31, height: 148))
        let assembled = stitcher.image()!
        let expected = image(height: 148, top: 0)
        XCTAssertEqual(assembled.width, expected.width)
        XCTAssertEqual(assembled.height, expected.height)
        XCTAssertEqual(assembled.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
    }

    func testDuplicateFrameDoesNotGrowOutput() {
        let stitcher = ScrollStitcher()
        _ = stitcher.append(image(top: 0))
        XCTAssertEqual(stitcher.append(image(top: 0)), .duplicate)
        XCTAssertEqual(stitcher.height, 90)
    }

    func testUpwardScrollPrependsAndPreservesImageOrientation() {
        let stitcher = ScrollStitcher(direction: .up)
        XCTAssertEqual(stitcher.append(image(top: 100)), .started(height: 90))
        XCTAssertEqual(stitcher.append(image(top: 73)), .appended(rows: 27, height: 117))
        XCTAssertEqual(stitcher.append(image(top: 42)), .appended(rows: 31, height: 148))
        let assembled = stitcher.image()!
        let expected = image(height: 148, top: 42)
        XCTAssertEqual(assembled.dataProvider!.data! as Data, expected.dataProvider!.data! as Data)
    }

    func testHorizontalShiftIsRejectedAndRetainsPreviousResult() {
        let stitcher = ScrollStitcher()
        _ = stitcher.append(image(top: 0))
        guard case .paused(let explanation) = stitcher.append(image(top: 25, horizontal: 8)) else {
            return XCTFail("A horizontal shift must not corrupt the stitched output")
        }
        XCTAssertTrue(explanation.contains("左右偏移"))
        XCTAssertEqual(stitcher.height, 90)
        XCTAssertEqual(stitcher.append(image(top: 25)), .appended(rows: 25, height: 115))
    }

    func testUnrelatedContentIsRejected() {
        let stitcher = ScrollStitcher()
        _ = stitcher.append(image(top: 0))
        guard case .paused = stitcher.append(image(top: 35, seed: 728)) else {
            return XCTFail("Unrelated frames must be rejected")
        }
        XCTAssertEqual(stitcher.height, 90)
    }

    func testHeightLimitKeepsExistingImageAvailable() {
        var limits = ScrollStitcher.Limits()
        limits.maximumHeight = 110
        let stitcher = ScrollStitcher(limits: limits)
        _ = stitcher.append(image(top: 0))
        guard case .limitReached = stitcher.append(image(top: 30)) else {
            return XCTFail("The configured height limit should stop appending")
        }
        XCTAssertEqual(stitcher.image()?.height, 90)
    }

    func testBidirectionalRevisitsAndBothEndsAreExact() {
        let stitcher = ScrollStitcher()
        let positions = [0, 27, 58, 27, 0, -24, 15, 70]
        let expected: [ScrollStitcher.Update] = [.started(height: 90), .appended(rows: 27, height: 117),
            .appended(rows: 31, height: 148), .revisited(height: 148), .revisited(height: 148),
            .appended(rows: 24, height: 172), .revisited(height: 172), .appended(rows: 12, height: 184)]
        for (position, update) in zip(positions, expected) {
            XCTAssertEqual(stitcher.append(image(top: position)), update)
            XCTAssertEqual(stitcher.lastOrigin, position)
        }
        XCTAssertEqual(stitcher.minOrigin, -24)
        XCTAssertEqual(stitcher.maxOrigin, 160)
        XCTAssertEqual(stitcher.image()!.dataProvider!.data! as Data,
                       image(height: 184, top: -24).dataProvider!.data! as Data)
    }

    func testDirectionInitializerDoesNotPreventSwitchingDirection() {
        let stitcher = ScrollStitcher(direction: .up)
        _ = stitcher.append(image(top: 100))
        XCTAssertEqual(stitcher.append(image(top: 73)), .appended(rows: 27, height: 117))
        XCTAssertEqual(stitcher.append(image(top: 100)), .revisited(height: 117))
        XCTAssertEqual(stitcher.append(image(top: 130)), .appended(rows: 30, height: 147))
        XCTAssertEqual(stitcher.append(image(top: 100)), .revisited(height: 147))
        XCTAssertEqual(stitcher.image()!.dataProvider!.data! as Data,
                       image(height: 147, top: 73).dataProvider!.data! as Data)
    }

    func testRejectedJumpDoesNotChangeAbsolutePosition() {
        let stitcher = ScrollStitcher()
        _ = stitcher.append(image(top: 0))
        _ = stitcher.append(image(top: 58))
        guard case .paused = stitcher.append(image(top: 160)) else { return XCTFail("Jump must pause") }
        XCTAssertEqual(stitcher.lastOrigin, 58)
        XCTAssertEqual(stitcher.append(image(top: 0)), .revisited(height: 148))
        XCTAssertEqual(stitcher.image()!.dataProvider!.data! as Data,
                       image(height: 148, top: 0).dataProvider!.data! as Data)
    }

    func testUpwardMemoryLimitKeepsPositionAndAllowsSmallerStep() {
        var limits = ScrollStitcher.Limits()
        limits.maximumWorkingBytes = 190_000
        let stitcher = ScrollStitcher(limits: limits)
        _ = stitcher.append(image(top: 0))
        guard case .limitReached = stitcher.append(image(top: -30)) else { return XCTFail("Prepend must respect memory limit") }
        XCTAssertEqual(stitcher.lastOrigin, 0)
        XCTAssertEqual(stitcher.minOrigin, 0)
        XCTAssertEqual(stitcher.height, 90)
        XCTAssertEqual(stitcher.append(image(top: -5)), .appended(rows: 5, height: 95))
        XCTAssertEqual(stitcher.image()!.dataProvider!.data! as Data,
                       image(height: 95, top: -5).dataProvider!.data! as Data)
    }
}
