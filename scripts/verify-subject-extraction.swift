import Foundation
import CoreGraphics
import CoreImage
import ImageIO

private struct SubjectVerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct SubjectExtractionVerification {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SubjectVerificationFailure(description: message) }
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SubjectVerificationFailure(description: "Cannot read sample image: \(url.path)")
        }
        return image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SubjectVerificationFailure(description: "Cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "PNG export did not finish")
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(CIImage(cgImage: image), toBitmap: buffer.baseAddress!, rowBytes: image.width * 4,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return bytes
    }

    private static func alphaCounts(_ image: CGImage) -> (clear: Int, solid: Int) {
        let bytes = rgba(image)
        var clear = 0, solid = 0
        for index in stride(from: 3, to: bytes.count, by: 4) {
            if bytes[index] == 0 { clear += 1 }
            if bytes[index] >= 250 { solid += 1 }
        }
        return (clear, solid)
    }

    private static func multipleDucks(_ source: CGImage) throws -> CGImage {
        let width = source.width * 3 + 40, height = source.height + 40
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SubjectVerificationFailure(description: "Cannot create the two-duck fixture")
        }
        canvas.setFillColor(CGColor(red: 0.15, green: 0.09, blue: 0.29, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.draw(source, in: CGRect(x: 20, y: 20, width: source.width, height: source.height))
        canvas.draw(source, in: CGRect(x: source.width * 2 + 20, y: 20, width: source.width, height: source.height))
        guard let image = canvas.makeImage() else { throw SubjectVerificationFailure(description: "Fixture rendering failed") }
        return image
    }

    private static func verifyDuck(_ source: CGImage, output: URL) throws {
        let result = try SubjectExtraction.analyze(source)
        try require(result.instances.count == 1, "The supplied duck sample did not produce exactly one instance: \(result.instances)")
        let head = result.instance(atNormalizedTopLeft: CGPoint(x: 0.36, y: 0.30))
        let body = result.instance(atNormalizedTopLeft: CGPoint(x: 0.59, y: 0.65))
        let outline = result.instance(atNormalizedTopLeft: CGPoint(x: 0.27, y: 0.18))
        try require(head != nil && head == body && head == outline, "Head, body and black outline must select the same duck")
        try require(result.instance(atNormalizedTopLeft: CGPoint(x: 0.85, y: 0.15)) == nil, "Background click selected a subject")
        for point in [CGPoint(x: -0.01, y: 0.5), CGPoint(x: 1.01, y: 0.5),
                      CGPoint(x: 0.5, y: -0.01), CGPoint(x: 0.5, y: 1.01),
                      CGPoint(x: .nan, y: 0.5), CGPoint(x: 0.5, y: .infinity)] {
            try require(result.instance(atNormalizedTopLeft: point) == nil, "Invalid normalized point selected a subject")
        }
        _ = result.instance(atNormalizedTopLeft: CGPoint(x: 1, y: 1))
        let emptyImage = try result.image(selecting: [])
        let emptyMask = try result.maskImage(selecting: [])
        let invalidImage = try result.image(selecting: IndexSet([0, 999999]))
        let invalidMask = try result.maskImage(selecting: IndexSet([0, 999999]))
        try require(emptyImage == nil && emptyMask == nil && invalidImage == nil && invalidMask == nil,
                    "Empty or invalid instance selection must return nil, never all subjects")
        guard let cutout = try result.image(selecting: result.instances),
              let mask = try result.maskImage(selecting: result.instances) else {
            throw SubjectVerificationFailure(description: "Valid instance selection returned nil")
        }
        var mixed = result.instances
        mixed.insert(0); mixed.insert(999999)
        guard let validOnly = try result.image(selecting: mixed) else {
            throw SubjectVerificationFailure(description: "Mixed valid and invalid selection returned nil")
        }
        try require(rgba(cutout) == rgba(validOnly), "Invalid instance IDs changed the selected output")
        for image in [cutout, mask] {
            try require(image.width == source.width && image.height == source.height, "Output cropped the original canvas")
            let counts = alphaCounts(image)
            try require(counts.clear > 0 && counts.solid > 0, "Output must include transparent background and opaque subject pixels")
        }
        let maskBytes = rgba(mask)
        for index in stride(from: 0, to: maskBytes.count, by: 4) where maskBytes[index + 3] >= 250 {
            try require(maskBytes[index] >= 245 && maskBytes[index + 1] >= 245 && maskBytes[index + 2] >= 245,
                        "Mask foreground must be white")
        }
        let url = output.appendingPathComponent("duck-cutout.png")
        try write(cutout, to: url)
        try write(mask, to: output.appendingPathComponent("duck-mask.png"))
        let decoded = try load(url)
        let counts = alphaCounts(decoded)
        try require(decoded.width == source.width && decoded.height == source.height && counts.clear > 0 && counts.solid > 0,
                    "PNG round trip did not retain full dimensions and alpha")
        print("PASS: one duck; head/body/outline lookup; background and invalid points; empty/invalid selection; full-size alpha PNG")
    }

    private static func verifySubsets(_ source: CGImage, output: URL) throws {
        let fixture = try multipleDucks(source)
        try write(fixture, to: output.appendingPathComponent("two-ducks-source.png"))
        let result: SubjectExtractionResult
        do { result = try SubjectExtraction.analyze(fixture) }
        catch SubjectExtractionError.noSubjects {
            print("NOTE: Vision found no subjects in the synthetic two-duck fixture; subset detection is not asserted")
            return
        }
        let y = (20 + CGFloat(source.height) * 0.30) / CGFloat(fixture.height)
        let left = result.instance(atNormalizedTopLeft: CGPoint(x: (20 + CGFloat(source.width) * 0.36) / CGFloat(fixture.width), y: y))
        let right = result.instance(atNormalizedTopLeft: CGPoint(x: (CGFloat(source.width) * 2 + 20 + CGFloat(source.width) * 0.36) / CGFloat(fixture.width), y: y))
        guard let left, let right, left != right else {
            print("NOTE: Vision did not separate the two duck seed points (instances=\(Array(result.instances))); subset detection is not asserted")
            return
        }
        guard let first = try result.image(selecting: IndexSet(integer: left)),
              let second = try result.image(selecting: IndexSet(integer: right)),
              let all = try result.image(selecting: IndexSet([left, right])) else {
            throw SubjectVerificationFailure(description: "Multi-subject subset output returned nil")
        }
        try require(rgba(first) != rgba(second), "Different detected instances produced the same cutout")
        try require(alphaCounts(first).solid < alphaCounts(all).solid && alphaCounts(second).solid < alphaCounts(all).solid,
                    "One-instance selection retained both whole subjects")
        try write(first, to: output.appendingPathComponent("two-ducks-left.png"))
        try write(second, to: output.appendingPathComponent("two-ducks-right.png"))
        try write(all, to: output.appendingPathComponent("two-ducks-all.png"))
        print("PASS: distinct detected subjects can be exported individually or together (left=\(left), right=\(right))")
    }

    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw SubjectVerificationFailure(description: "Usage: verify-subject-extraction SAMPLE_IMAGE OUTPUT_DIRECTORY")
            }
            let sample = try load(URL(fileURLWithPath: CommandLine.arguments[1]))
            let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try verifyDuck(sample, output: output)
            try verifySubsets(sample, output: output)
            print("PASS: subject extraction verification finished")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
