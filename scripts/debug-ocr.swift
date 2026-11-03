// Concatenated with ImageTools.swift; all fixtures are generated locally.
import Darwin

private func describeImage(_ name: String, _ image: CGImage) {
    let space = image.colorSpace
    print("IMAGE \(name): \(image.width)x\(image.height), bpc=\(image.bitsPerComponent), bpp=\(image.bitsPerPixel), row=\(image.bytesPerRow), alpha=\(image.alphaInfo.rawValue), bitmap=0x\(String(image.bitmapInfo.rawValue, radix: 16)), space=\(space?.name.map { $0 as String } ?? "nil"), model=\(space?.model.rawValue ?? -1), provider=\(image.dataProvider?.data.map { CFDataGetLength($0) } ?? -1)")
    fflush(stdout)
}

// Every mutable access is guarded by this lock; the box crosses the GCD queue.
private final class OCRDebugResults: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func failed() { lock.lock(); count += 1; lock.unlock() }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private func readOCR(_ name: String, _ image: CGImage, _ queue: String) -> Bool {
    do {
        let text = try ImageToolsOCRWorker.read(image)
        print("PASS OCR \(name) [\(queue), main=\(Thread.isMainThread)]: \(text.replacingOccurrences(of: "\n", with: " | "))")
        fflush(stdout)
        return text.contains("Patch")
    } catch {
        let error = error as NSError
        print("FAIL OCR \(name) [\(queue), main=\(Thread.isMainThread)]: domain=\(error.domain), code=\(error.code), info=\(error.userInfo)")
        fflush(stdout)
        return false
    }
}

@main
private struct OCRDebug {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let path = CommandLine.arguments.dropFirst().first ?? "/private/tmp"
        let output = URL(fileURLWithPath: path)
        print("Process: \(ProcessInfo.processInfo.processName), pid=\(ProcessInfo.processInfo.processIdentifier), macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let demo = DemoImage.make()
        let rendered = try ImageToolsCanvas(image: demo).renderedImage()
        let decodedData = try ImageToolsUI.png(rendered)
        guard let decoded = NSBitmapImageRep(data: decodedData)?.cgImage else { fatalError("PNG decode failed") }
        guard let context = CGContext(data: nil, width: 900, height: 300, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Fixture allocation failed") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
        context.translateBy(x: 0, y: 300); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: "Patch", attributes: [
            .font: NSFont.systemFont(ofSize: 80, weight: .semibold), .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 35, y: 35))
        NSAttributedString(string: "截图文字识别", attributes: [
            .font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 35, y: 140))
        NSGraphicsContext.restoreGraphicsState()
        let simple = context.makeImage()!
        let retinaContext = CGContext(data: nil, width: 1920, height: 1200, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        retinaContext.interpolationQuality = .high
        retinaContext.draw(rendered, in: CGRect(x: 0, y: 0, width: 1920, height: 1200))
        let retina = retinaContext.makeImage()!
        let fixtures = [("demo-original", demo), ("demo-rendered", rendered), ("demo-rendered-1920x1200", retina), ("demo-png-decoded", decoded), ("simple-900x300", simple)]
        for (name, image) in fixtures {
            describeImage(name, image)
            try ImageToolsUI.png(image).write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
        }
        let result = OCRDebugResults()
        for (name, image) in fixtures {
            if !readOCR(name, image, "main") { result.failed() }
        }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            // Sequential requests reproduce the application's one-click worker path;
            // concurrent OCR requests are deliberately excluded from this comparison.
            for (name, image) in fixtures {
                if !readOCR(name, image, "global") { result.failed() }
            }
            group.leave()
        }
        group.wait()
        let total = fixtures.count * 2
        print("SUMMARY: \(total - result.failures)/\(total) OCR cases recognized Patch")
        if result.failures != 0 { exit(1) }
    }
}
