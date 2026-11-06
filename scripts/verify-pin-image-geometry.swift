// Concatenated with the production pure geometry block; no windows or posted input.
import AppKit
import Darwin

private struct GeometryFailure: Error, CustomStringConvertible { let description: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw GeometryFailure(description: message) }
}
private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.00001 }

private func verifyGeometry() throws {
    let visible = CGRect(x: -1440, y: 100, width: 1440, height: 850)
    for (pixels, sourceScale) in [(CGSize(width: 400, height: 240), CGFloat(2)),
                                  (CGSize(width: 800, height: 18000), 2),
                                  (CGSize(width: 18000, height: 800), 1)] {
        let natural = ImageToolsPinImageGeometry.naturalSize(pixels: pixels, sourceScale: sourceScale)
        let fit = ImageToolsPinImageGeometry.fitScale(size: natural,
            available: ImageToolsPinImageGeometry.initialAvailableSize(visible: visible.size))
        let initial = CGRect(x: visible.minX + 20, y: visible.minY + 20,
                             width: natural.width * fit, height: natural.height * fit)
        try require(visible.contains(initial), "Initial full image leaves its display")
        try require(initial.width + 2 <= visible.width / 2 && initial.height + 2 <= visible.height / 2,
                    "Initial full image exceeds half-display width or height")
        try require(near(initial.width / initial.height, pixels.width / pixels.height), "Initial fit changes image aspect ratio")
        if pixels.width == 400 { try require(fit == 1 && initial.size == CGSize(width: 200, height: 120), "Small capture no longer preserves source points") }
        let anchor = CGPoint(x: initial.midX, y: initial.maxY - initial.height / 4)
        let enlarged = ImageToolsPinImageGeometry.zoomed(initial, factor: 1.25, anchor: anchor)
        try require(near((anchor.x - enlarged.minX) / enlarged.width, 0.5)
                    && near((anchor.y - enlarged.minY) / enlarged.height, 0.75), "Zoom moves the pixel under the pointer")
        try require(near(enlarged.width / enlarged.height, pixels.width / pixels.height), "Zoom changes aspect ratio")
        if pixels.height == 18000 { try require(fit < 0.2 && enlarged.height < initial.height * 1.3, "Long-image fit jumps to a fixed 20 percent minimum") }
    }
    let desktop = ImageToolsPinImageGeometry.desktopBounds([visible, CGRect(x: 0, y: 0, width: 1920, height: 1080)])
    let oversized = CGRect(x: -300, y: -8000, width: 1200, height: 18000)
    let host = ImageToolsPinImageGeometry.hostFrame(image: oversized, inset: 1, desktop: desktop)
    try require(desktop.contains(host) && host.width > 300 && host.maxX > 0 && host.minX < 0,
                "Host is unbounded or clips the image to only one display")
    try require(host.height <= desktop.height && oversized.height == 18000, "Clipping changes virtual image geometry")
    for y in [visible.minY, visible.maxY - oversized.height] {
        let reachable = ImageToolsPinImageGeometry.keepingReachable(CGRect(x: visible.midX, y: y, width: 1200, height: 18000), within: visible)
        try require(near(reachable.minY, y) && reachable.size == oversized.size, "Dragging cannot reach the first or last source row")
    }
    let away = ImageToolsPinImageGeometry.keepingReachable(oversized.offsetBy(dx: 100000, dy: -100000), within: visible)
    try require(away.intersection(visible).width >= 32 && away.intersection(visible).height >= 32,
                "Dragging can lose every reachable portion of the pin")
    print("PASS: source points, whole-image fit/aspect, pointer anchor, sub-20% zoom, cross-display bounds and reachable ends")
}

private func verifyCrop(backingScale: CGFloat, zoom: CGFloat) throws {
    let width = 800, height = 1800
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let index = (y * width + x) * 4
        source[index] = UInt8((x * 17 + y * 3) % 256)
        source[index + 1] = UInt8((x * 5 + y * 23) % 256)
        source[index + 2] = UInt8((x / 5 + y / 7) % 2 == 0 ? 0 : 255)
    } }
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)
    guard let provider = CGDataProvider(data: Data(source) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw GeometryFailure(description: "Cannot create pixels") }
    let rect = CGRect(x: -40 * zoom, y: -180 * zoom, width: 400 * zoom, height: 900 * zoom)
    let visible = CGRect(x: 0, y: 0, width: 180, height: 120)
    guard let mapping = ImageToolsPinImageGeometry.crop(imageSize: CGSize(width: width, height: height), imageRect: rect, visible: visible),
          let cropped = image.cropping(to: mapping.pixels) else { throw GeometryFailure(description: "Cannot map crop") }
    let pixelWidth = Int(visible.width * backingScale), pixelHeight = Int(visible.height * backingScale)
    guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { throw GeometryFailure(description: "Cannot create viewport") }
    context.translateBy(x: 0, y: CGFloat(pixelHeight)); context.scaleBy(x: backingScale, y: -backingScale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    NSImage(cgImage: cropped, size: mapping.destination.size).draw(in: mapping.destination, from: .zero,
        operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    guard let output = context.makeImage(), let data = output.dataProvider?.data as Data? else { throw GeometryFailure(description: "Missing rendered pixels") }
    for y in 0..<pixelHeight { for x in 0..<pixelWidth {
        let expected = ((y + 360) * width + x + 80) * 4, actual = (y * pixelWidth + x) * 4
        try require((0..<4).allSatisfy { data[actual + $0] == source[expected + $0] },
                    "Cropped drawing changed source pixels at \(x),\(y), backing \(backingScale)")
    } }
    try require(image.width == width && image.height == height, "Drawing changed original source")
    print("PASS: cropped display keeps exact source pixels at backing \(backingScale)x / zoom \(zoom)x")
}

guard CommandLine.arguments.dropFirst().elementsEqual(["--verify"]) else { exit(0) }
do {
    try verifyGeometry()
    try verifyCrop(backingScale: 2, zoom: 1)
    try verifyCrop(backingScale: 1, zoom: 2)
    print("PASS: whole-image pin geometry and cropped rendering complete")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
