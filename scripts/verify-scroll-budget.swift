// Synthetic pixels only. Exercises stitching, previews, and lossless PNG export.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

@main enum BudgetProbe {
    static var width = 2400, viewportHeight = 1600
    static func verifyPixels(_ image: CGImage) {
        let data = image.dataProvider!.data!, raw = CFDataGetBytePtr(data)!
        for y in 0..<image.height { for x in 0..<image.width {
            let v = hash(x, y), i = (y * image.width + x) * 4
            precondition(raw[i] == UInt8(truncatingIfNeeded: v) && raw[i+1] == UInt8(truncatingIfNeeded: v >> 8)
                && raw[i+2] == UInt8(truncatingIfNeeded: v >> 16) && raw[i+3] == 255, "Pixel changed")
        } }
    }
    static func hash(_ x: Int, _ y: Int) -> UInt32 {
        var v = UInt32(truncatingIfNeeded: x) &* 747_796_405 ^ UInt32(truncatingIfNeeded: y) &* 2_891_336_453 ^ 19
        v = (v ^ (v >> 16)) &* 2_246_822_519
        return v
    }
    static func frame(top: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * viewportHeight * 4)
        for y in 0..<viewportHeight { for x in 0..<width {
            let v = hash(x, y + top), i = (y * width + x) * 4
            bytes[i] = UInt8(truncatingIfNeeded: v); bytes[i+1] = UInt8(truncatingIfNeeded: v >> 8); bytes[i+2] = UInt8(truncatingIfNeeded: v >> 16)
        } }
        return CGImage(width: width, height: viewportHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func peak(_ label: String) {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("PEAK \(label): \(usage.ru_maxrss / 1024 / 1024) MiB"); fflush(stdout)
    }
    static func main() {
        guard CommandLine.arguments.count == 3, ["128", "256", "512"].contains(CommandLine.arguments[1]),
              ["retina", "tall"].contains(CommandLine.arguments[2]) else {
            fputs("Usage: verify-scroll-budget 128|256|512 retina|tall\n", stderr); exit(2)
        }
        let tall = CommandLine.arguments[2] == "tall"
        if tall { width = 128; viewportHeight = 1200 }
        var limits = ScrollStitcher.Limits()
        limits.maximumWorkingBytes = Int(CommandLine.arguments[1])! * 1024 * 1024
        let stitcher = ScrollStitcher(limits: limits)
        let start = Date()
        for top in stride(from: 0, through: tall ? 60_000 : 30_000, by: 600) {
            let accepted: Bool = autoreleasepool {
                let update = stitcher.append(frame(top: top))
                switch update {
                case .started, .appended: _ = stitcher.preview(); return true
                case .limitReached(let reason):
                    precondition(reason == (tall ? .height : .memory), "Wrong limit reason")
                    print("LIMIT budget=\(CommandLine.arguments[1]) width=\(stitcher.width) height=\(stitcher.height)"); return false
                default: fatalError("Unexpected update: \(update)")
                }
            }
            if !accepted { break }
        }
        if tall { precondition(stitcher.height == 60_000, "Height cap must allow the entire 60,000-pixel output") }
        else {
            let expected = ["128": 3400, "256": 8200, "512": 17200][CommandLine.arguments[1]]!
            precondition(stitcher.height == expected, "Unexpected Retina output capacity")
        }
        peak("stitch")
        let image = stitcher.image()!
        verifyPixels(image)
        print("EXACT: all output pixels match source")
        autoreleasepool {
            let png = NSMutableData()
            let writer = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, image, nil)
            precondition(CGImageDestinationFinalize(writer))
            peak("PNG export")
            let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png, nil)!, 0, nil)!
            precondition(decoded.width == image.width && decoded.height == image.height)
            // Normalize PNG decoding to the same RGBA layout and compare every byte.
            let context = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
                bytesPerRow: decoded.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
            verifyPixels(context.makeImage()!)
            print("PASS: PNG round-trip preserves every source pixel")
            print("PNG: \(png.length / 1024 / 1024) MiB, unchanged dimensions \(decoded.width)x\(decoded.height)")
        }
        print("ELAPSED: \(Int(Date().timeIntervalSince(start))) sec")
    }
}
