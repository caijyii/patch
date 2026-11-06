// Synthetic, session-only fixtures. Never reads or changes the general pasteboard.
import AppKit
import AVFoundation
import Darwin

private struct QuotaFailure: Error { let message: String }
@main struct RecentQuotaVerification {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw QuotaFailure(message: message) }
    }
    @MainActor static func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<240 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw QuotaFailure(message: message)
    }
    static func image() throws -> CGImage {
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw QuotaFailure(message: "Cannot allocate synthetic image")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { throw QuotaFailure(message: "Cannot render synthetic image") }
        return image
    }
    static func video(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 128, AVVideoHeightKey: 80])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 80])
        writer.add(input)
        let started = writer.startWriting()
        try require(started, "Synthetic writer did not start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 128, 80, kCVPixelFormatType_32ARGB, nil, &pixel)
            guard let buffer = pixel else { throw QuotaFailure(message: "Cannot allocate synthetic frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw QuotaFailure(message: "Cannot access synthetic frame") }
            let pointer = address.assumingMemoryBound(to: UInt8.self)
            for y in 0..<80 { for x in 0..<128 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                pointer[offset] = 255; pointer[offset + 1] = 35
                pointer[offset + 2] = 170; pointer[offset + 3] = 220
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Synthetic frame failed")
        }
        writer.endSession(atSourceTime: CMTime(value: 15, timescale: 30))
        input.markAsFinished(); await writer.finishWriting()
        try require(writer.status == .completed, "Synthetic movie failed")
    }
    @MainActor static func quotas() throws {
        let store = RecentContentStore(), fixture = try image()
        try require(store.textLimit == 100 && store.imageLimit == 20 && store.videoLimit == 5 && store.limit == 125,
            "Default category counts changed")
        try require(store.textMemoryLimit == 8 * 1024 * 1024 && store.imageMemoryLimit == 128 * 1024 * 1024
            && store.videoMemoryLimit == 8 * 1024 * 1024, "Default category memory budgets changed")
        for scale in 1...20 { store.addImage(fixture, pixelScale: CGFloat(scale)) }
        let imageIDs = store.items.map(\.id)
        for index in 0...100 { store.addText("text \(index)") }
        try require(store.items.filter(RecentContentStore.Filter.images.includes).map(\.id) == imageIDs
            && store.items.filter(RecentContentStore.Filter.text.includes).count == 100, "Text count displaced images")
        let textIDs = store.items.filter(RecentContentStore.Filter.text.includes).map(\.id)
        store.addImage(fixture, pixelScale: 21)
        try require(store.items.filter(RecentContentStore.Filter.text.includes).map(\.id) == textIDs
            && store.items.filter(RecentContentStore.Filter.images.includes).count == 20, "Image count displaced text")
        let small = RecentContentStore(textMemoryLimit: 12)
        small.addImage(fixture, pixelScale: nil); let retainedImage = small.items[0].id
        small.addText("12345678"); small.addText("abcdefgh")
        try require(small.items.contains { $0.id == retainedImage } && small.items.filter(RecentContentStore.Filter.text.includes).count == 1,
            "Text memory eviction displaced an image")
        let probe = RecentContentStore(); probe.addImage(fixture, pixelScale: nil)
        let images = RecentContentStore(imageMemoryLimit: probe.items[0].memoryCost * 2)
        images.addText("old text survives image memory pressure")
        for scale in 1...3 { images.addImage(fixture, pixelScale: CGFloat(scale)) }
        try require(images.items.filter(RecentContentStore.Filter.images.includes).count == 2
            && images.items.filter(RecentContentStore.Filter.text.includes).count == 1, "Image memory displaced text")
        let ids = small.items.map(\.id)
        small.addText(String(repeating: "x", count: 13))
        try require(small.items.map(\.id) == ids && small.notice != nil, "Oversized text erased existing content")
        let legacy = RecentContentStore(limit: 2)
        legacy.addText("a"); legacy.addImage(fixture, pixelScale: nil); legacy.addText("b")
        try require(legacy.items.count == 2, "Explicit legacy total count lost compatibility")
        legacy.setLimit(1); try require(legacy.items.count == 1, "Explicit setLimit lost compatibility")
        print("PASS: independent text/image count and byte quotas, oversized rejection, legacy explicit limits")
    }
    @MainActor static func videos(in root: URL) async throws {
        let first = root.appendingPathComponent("fixture.mov")
        try await video(at: first)
        var urls = [first]
        for index in 1...6 {
            let url = root.appendingPathComponent("fixture-\(index).mov")
            try FileManager.default.copyItem(at: first, to: url); urls.append(url)
        }
        let store = RecentContentStore()
        store.addText("retained text"); store.addImage(try image(), pixelScale: 2)
        for url in urls.prefix(6) { store.addVideo(url) }
        try await waitFor("Five video references did not load") { store.items.filter(RecentContentStore.Filter.videos.includes).count == 5 }
        try require(store.items.filter(RecentContentStore.Filter.videos.includes).map(\.title)
            == Array(urls[1...5].reversed()).map(\.lastPathComponent), "Asynchronous video metadata reordered recency")
        try require(store.items.filter(\.isPinnable).count == 2, "Video quota displaced pin content")
        guard let firstItem = store.items.first, case .video(let reference) = firstItem.content else { throw QuotaFailure(message: "Missing video") }
        try require(reference.isAvailable && reference.thumbnail != nil && abs((reference.duration ?? 0) - 0.5) < 0.05,
            "Video preview, duration or file access failed")
        try require(firstItem.memoryCost < 128 * 80 * 4 + 4096, "Video accounting exceeds thumbnail plus metadata")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = RecentClipboardMonitor(store: store, pasteboard: board)
        defer { monitor.setEnabled(false) }
        board.clearContents(); board.writeObjects([reference.url as NSURL]); monitor.setEnabled(true)
        let ids = store.items.map(\.id)
        board.clearContents(); board.writeObjects([reference.url as NSURL]); monitor.poll()
        try await Task.sleep(for: .milliseconds(150))
        try require(store.items.map(\.id) == ids, "Copying a video duplicated or reordered history")
        board.clearContents(); board.setString("acknowledged fixture", forType: .string)
        monitor.acknowledgeCopy(); monitor.poll()
        try require(store.items.map(\.id) == ids, "Acknowledged history copy was imported again")
        let textURL = root.appendingPathComponent("ordinary.txt")
        try "ordinary file".write(to: textURL, atomically: true, encoding: .utf8)
        board.clearContents(); board.writeObjects([textURL as NSURL]); board.setString("ordinary.txt", forType: .string); monitor.poll()
        try require(store.items.map(\.id) == ids, "Ordinary Finder filename was imported as text")
        store.clear(.videos)
        board.clearContents(); board.writeObjects([urls[1] as NSURL, urls[2] as NSURL, textURL as NSURL]); monitor.poll()
        try await waitFor("Multiple Finder video URLs did not load") { store.items.filter(RecentContentStore.Filter.videos.includes).count == 2 }
        store.clear(.videos)
        store.addVideo(urls[3]); store.clear(.videos)
        try await Task.sleep(for: .milliseconds(150))
        try require(store.items.filter(RecentContentStore.Filter.videos.includes).isEmpty, "Clearing video resurrected a pending preview")
        board.clearContents(); board.writeObjects([urls[4] as NSURL])
        store.clear(.text)
        try await waitFor("Clearing text cancelled pending video collection") { store.items.filter(RecentContentStore.Filter.videos.includes).count == 1 }
        store.addText("delete only this text")
        guard let textID = store.items.first?.id else { throw QuotaFailure(message: "Missing deletion fixture") }
        store.addVideo(urls[5]); store.remove(textID)
        try await waitFor("Deleting text cancelled an unrelated pending video") { store.items.filter(RecentContentStore.Filter.videos.includes).count == 2 }
        store.addVideo(urls[5]); store.clear()
        try await Task.sleep(for: .milliseconds(150))
        try require(store.items.isEmpty && store.memoryUsage == 0, "Clearing all resurrected a pending preview")
        store.addVideo(urls[6])
        try await waitFor("Final video did not load") { !store.items.isEmpty }
        guard case .video(let deleted) = store.items[0].content else { throw QuotaFailure(message: "Missing final video") }
        try FileManager.default.removeItem(at: urls[6])
        try require(!deleted.isAvailable, "Deleted file still appears available")
        store.clear()
        let invalid = root.appendingPathComponent("no-preview.mov")
        try Data("not playable".utf8).write(to: invalid)
        store.addVideo(invalid)
        try await waitFor("A valid file reference was dropped after preview failure") { !store.items.isEmpty }
        try require(store.items[0].thumbnail == nil, "Invalid movie unexpectedly has a preview")
        let priorID = store.items[0].id
        try FileManager.default.removeItem(at: invalid)
        try FileManager.default.copyItem(at: first, to: invalid)
        store.addVideo(invalid)
        try await waitFor("Overwritten movie was not refreshed") { store.items.first?.id != priorID }
        try require(store.items.count == 1 && store.items[0].thumbnail != nil, "Overwritten URL retained a stale duplicate")
        store.clear()
        try require(FileManager.default.fileExists(atPath: first.path), "Clearing history deleted a source movie")
        print("PASS: five video references, thumbnail/duration, multi-file pasteboard, recopy deduplication, clear races, file replacement and missing files")
        print("FIXTURE: \(first.path)")
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("Run scripts/verify-recent-quotas.sh from Terminal.")
            return
        }
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try quotas(); try await videos(in: root)
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
