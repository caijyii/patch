// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Holds only a session-long file grant and a small preview, never the video bytes.
@MainActor
final class RecentVideoReference {
    let url: URL
    let fingerprint: String
    private let modificationDate: Date?
    private let fileSize: Int?
    private let hasSecurityScope: Bool
    private(set) var duration: TimeInterval?
    private(set) var thumbnail: NSImage?
    private(set) var thumbnailCost = 0

    init?(_ source: URL) {
        guard source.isFileURL else { return nil }
        let url = source.standardizedFileURL
        let access = source.startAccessingSecurityScopedResource()
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true, FileManager.default.isReadableFile(atPath: url.path),
              let type = values.contentType ?? UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .movie) || type.conforms(to: .video) else {
            if access { source.stopAccessingSecurityScopedResource() }
            return nil
        }
        // Retain the original URL, which may carry the pasteboard's sandbox grant.
        self.url = source
        hasSecurityScope = access
        modificationDate = values.contentModificationDate; fileSize = values.fileSize
        fingerprint = "video:" + url.absoluteString + ":" + String(values.fileSize ?? 0)
            + ":" + String(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
    deinit { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }

    var isAvailable: Bool {
        var currentURL = url
        currentURL.removeAllCachedResourceValues()
        guard FileManager.default.isReadableFile(atPath: url.path),
              let values = try? currentURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && values.fileSize == fileSize
            && values.contentModificationDate == modificationDate
    }
    var memoryCost: Int { thumbnailCost + url.absoluteString.utf8.count + 512 }

    func loadPreview() async {
        let asset = AVURLAsset(url: url)
        if let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds >= 0 {
            duration = time.seconds
        }
        guard !Task.isCancelled else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 400)
        let result = await withTaskCancellationHandler {
            try? await generator.image(at: .zero)
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        guard !Task.isCancelled, let image = result?.image else { return }
        thumbnail = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        thumbnailCost = image.bytesPerRow * image.height
    }
}

/// Session-only content. Preferences persist separately; captured content never goes to disk.
@MainActor
final class RecentContentStore {
    enum Filter: Int {
        case all, images, text, videos

        func includes(_ item: Item) -> Bool {
            switch self {
            case .all: return true
            case .images: if case .image = item.content { return true }
            case .text: if case .text = item.content { return true }
            case .videos: if case .video = item.content { return true }
            }
            return false
        }
    }

    struct Item: Identifiable {
        enum Content {
            case image(Data, CGSize, CGFloat?)
            case text(String)
            case video(RecentVideoReference)
        }
        let id: UUID
        let fingerprint: String
        let content: Content
        let memoryCost: Int
        let date: Date
        let thumbnail: NSImage?
        var isPinnable: Bool {
            switch content { case .image, .text: return true; case .video: return false }
        }
        var kindTitle: String {
            switch content { case .image: return L("图片"); case .text: return L("文本"); case .video: return L("视频") }
        }
        var title: String {
            switch content {
            case .image(_, let size, _): return LF("图片 · %d × %d", Int(size.width), Int(size.height))
            case .text(let value): return String(value.prefix(180))
            case .video(let reference): return reference.url.lastPathComponent
            }
        }
    }
    private(set) var items: [Item] = []
    private(set) var memoryUsage = 0
    /// Aggregate ceilings. Normal retention uses independent category quotas below.
    private(set) var limit: Int
    let memoryLimit: Int
    let textLimit: Int
    let imageLimit: Int
    let videoLimit: Int
    let textMemoryLimit: Int
    let imageMemoryLimit: Int
    let videoMemoryLimit: Int
    private(set) var notice: String?
    var onChange: (() -> Void)?
    var onUserRemoval: ((Filter) -> Void)?
    private let now: () -> Date
    private var combinedCountLimit: Int?
    private let combinedMemoryLimit: Int?
    private var pendingVideos: [String: Task<Void, Never>] = [:]
    private var pendingVideoURLs: [String: URL] = [:]
    private var pendingVideoOrder: [String] = []
    private var videoGeneration = 0

    /// Explicit legacy limits add a shared ceiling, useful for small deterministic fixtures.
    /// Omitting them keeps text and images from evicting each other.
    init(limit: Int? = nil, memoryLimit: Int? = nil,
         textLimit: Int = 100, imageLimit: Int = 20, videoLimit: Int = 5,
         textMemoryLimit: Int = 8 * 1024 * 1024, imageMemoryLimit: Int = 128 * 1024 * 1024,
         videoMemoryLimit: Int = 8 * 1024 * 1024,
         now: @escaping () -> Date = Date.init) {
        self.textLimit = max(1, textLimit)
        self.imageLimit = max(1, imageLimit)
        self.videoLimit = max(1, videoLimit)
        combinedCountLimit = limit.map { max(1, $0) }
        combinedMemoryLimit = memoryLimit.map { max(1, $0) }
        self.textMemoryLimit = min(max(1, textMemoryLimit), combinedMemoryLimit ?? Int.max)
        self.imageMemoryLimit = min(max(1, imageMemoryLimit), combinedMemoryLimit ?? Int.max)
        self.videoMemoryLimit = min(max(1, videoMemoryLimit), combinedMemoryLimit ?? Int.max)
        self.limit = combinedCountLimit ?? (self.textLimit + self.imageLimit + self.videoLimit)
        self.memoryLimit = combinedMemoryLimit ?? (self.textMemoryLimit + self.imageMemoryLimit + self.videoMemoryLimit)
        self.now = now
    }
    deinit { pendingVideos.values.forEach { $0.cancel() } }
    /// Retains the legacy explicit shared-count override; the app uses category quotas.
    func setLimit(_ value: Int) {
        limit = max(1, value); combinedCountLimit = limit; trim(); onChange?()
    }
    func addText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= textMemoryLimit else { oversized(); return }
        insert(.init(id: UUID(), fingerprint: "text:" + digest(data), content: .text(text),
                     memoryCost: data.count, date: now(), thumbnail: nil))
    }
    func addImage(_ image: CGImage, pixelScale: CGFloat?) {
        // Budget decoded pixels as well as compressed data, before allocating the canonical bitmap.
        let pixels = Int64(image.width) * Int64(image.height) * 4
        guard pixels > 0, pixels < Int64(imageMemoryLimit) else { oversized(); return }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let canonical = context.makeImage(), let data = try? ImageToolsUI.png(canonical) else { return }
        let validScale = pixelScale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let fingerprint = "image:" + digest(data) + ":" + (validScale.map { String(format: "%.4f", Double($0)) } ?? "unknown")
        let pixelSize = CGSize(width: image.width, height: image.height)
        // A Retina card needs more pixels than the former compact list preview.
        let factor = min(1, min(640 / pixelSize.width, 400 / pixelSize.height))
        let thumbWidth = max(1, Int(pixelSize.width * factor)), thumbHeight = max(1, Int(pixelSize.height * factor))
        let thumbContext = CGContext(data: nil, width: thumbWidth, height: thumbHeight, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        thumbContext?.draw(canonical, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        let thumbnail = thumbContext?.makeImage().map { NSImage(cgImage: $0, size: CGSize(width: thumbWidth, height: thumbHeight)) }
        let cost = Int(pixels) + data.count + thumbWidth * thumbHeight * 4
        guard cost <= imageMemoryLimit else { oversized(); return }
        insert(.init(id: UUID(), fingerprint: fingerprint, content: .image(data, pixelSize, validScale),
                     memoryCost: cost, date: now(), thumbnail: thumbnail))
    }
    func remove(_ id: UUID) {
        // Only cancel updates to the deleted video; unrelated pending copies survive.
        if let item = items.first(where: { $0.id == id }), case .video(let reference) = item.content {
            let matching = pendingVideoURLs.filter { $0.value == reference.url.standardizedFileURL }.map(\.key)
            for key in matching {
                pendingVideos.removeValue(forKey: key)?.cancel()
                pendingVideoURLs.removeValue(forKey: key)
                pendingVideoOrder.removeAll { $0 == key }
            }
        }
        onUserRemoval?(.all)
        items.removeAll { $0.id == id }; recalculate(); onChange?()
    }
    func clear(_ filter: Filter = .all) {
        if filter == .all || filter == .videos { cancelPendingVideos() }
        items.removeAll(where: filter.includes)
        recalculate(); notice = nil
        onUserRemoval?(filter)
        onChange?()
    }
    private func insert(_ item: Item) {
        // Recopying or repinning an existing item neither duplicates it nor changes recency.
        guard !items.contains(where: { $0.fingerprint == item.fingerprint }) else { return }
        notice = nil
        let index = items.firstIndex { $0.date <= item.date } ?? items.endIndex
        items.insert(item, at: index); trim(); onChange?()
    }
    func addVideo(_ url: URL) {
        guard let reference = RecentVideoReference(url) else { return }
        let fingerprint = reference.fingerprint
        guard !items.contains(where: { $0.fingerprint == fingerprint }), pendingVideos[fingerprint] == nil else { return }
        let date = now(), generation = videoGeneration
        // File copies can contain many URLs; do not start unbounded preview decoders.
        while pendingVideoOrder.count >= videoLimit {
            let oldest = pendingVideoOrder.removeFirst()
            pendingVideos.removeValue(forKey: oldest)?.cancel()
            pendingVideoURLs.removeValue(forKey: oldest)
        }
        pendingVideoOrder.append(fingerprint)
        pendingVideoURLs[fingerprint] = url.standardizedFileURL
        pendingVideos[fingerprint] = Task { [weak self] in
            await reference.loadPreview()
            guard !Task.isCancelled, let self, self.videoGeneration == generation,
                  self.pendingVideos[fingerprint] != nil else { return }
            self.pendingVideos.removeValue(forKey: fingerprint)
            self.pendingVideoURLs.removeValue(forKey: fingerprint)
            self.pendingVideoOrder.removeAll { $0 == fingerprint }
            guard reference.isAvailable else { return }
            guard reference.memoryCost <= self.videoMemoryLimit else { self.oversized(); return }
            // A saved-over file replaces its stale thumbnail, rather than producing two cards.
            self.items.removeAll { item in
                if case .video(let old) = item.content { return old.url.standardizedFileURL == url.standardizedFileURL }
                return false
            }
            self.insert(.init(id: UUID(), fingerprint: fingerprint, content: .video(reference),
                memoryCost: reference.memoryCost, date: date, thumbnail: reference.thumbnail))
        }
    }
    private func cancelPendingVideos() {
        videoGeneration += 1
        pendingVideos.values.forEach { $0.cancel() }
        pendingVideos.removeAll(); pendingVideoURLs.removeAll(); pendingVideoOrder.removeAll()
    }
    private func trim() {
        trim(.text, countLimit: textLimit, byteLimit: textMemoryLimit)
        trim(.images, countLimit: imageLimit, byteLimit: imageMemoryLimit)
        trim(.videos, countLimit: videoLimit, byteLimit: videoMemoryLimit)
        recalculate()
        while items.count > (combinedCountLimit ?? Int.max) || memoryUsage > (combinedMemoryLimit ?? Int.max) {
            guard let last = items.popLast() else { break }
            memoryUsage -= last.memoryCost
        }
    }
    private func trim(_ filter: Filter, countLimit: Int, byteLimit: Int) {
        let matching = items.filter(filter.includes)
        var count = matching.count
        var cost = matching.reduce(0) { $0 + $1.memoryCost }
        while count > countLimit || cost > byteLimit {
            guard let index = items.lastIndex(where: filter.includes) else { break }
            cost -= items.remove(at: index).memoryCost
            count -= 1
        }
    }
    private func recalculate() { memoryUsage = items.reduce(0) { $0 + $1.memoryCost } }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func oversized() { notice = "这条内容过大，未加入历史；现有记录已保留。"; onChange?() }
}

@MainActor
final class RecentClipboardMonitor {
    private let store: RecentContentStore
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChange: Int?
    private(set) var isEnabled = false
    init(store: RecentContentStore, pasteboard: NSPasteboard = .general) {
        self.store = store; self.pasteboard = pasteboard
        store.onUserRemoval = { [weak self] filter in
            guard let self else { return }
            if filter != .all {
                // The cleared records have already released their capacity.
                // Only collect pending copies of the remaining content type.
                self.poll(excluding: filter)
                return
            }
            // A user removal also acknowledges copies made since the last timer tick.
            self.lastChange = self.pasteboard.changeCount
        }
    }
    deinit { timer?.invalidate() }
    /// The history already owns this item; acknowledge a successful direct copy without re-importing it.
    func acknowledgeCopy() { lastChange = pasteboard.changeCount }
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        lastChange = nil
        poll()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func poll(excluding filter: RecentContentStore.Filter? = nil) {
        guard isEnabled else { return }
        let change = pasteboard.changeCount
        guard lastChange != change else { return }
        lastChange = change
        let types = Set(pasteboard.types ?? [])
        // Clipboard owners can mark content concealed/transient; it must not appear in a history panel.
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !excluded.contains(where: { types.contains(NSPasteboard.PasteboardType($0)) }) else { return }
        if types.contains(.fileURL) {
            guard filter != .videos,
                  let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL],
                  pasteboard.changeCount == change else { return }
            for url in urls { store.addVideo(url as URL) }
            // Finder also publishes file names as text. Never import those as text records.
            return
        }
        if types.contains(.png) || types.contains(.tiff) {
            guard filter != .images else { return }
            // Reject excessive encoded payloads before asking AppKit to decode them.
            guard let data = pasteboard.data(forType: types.contains(.png) ? .png : .tiff), data.count <= store.imageMemoryLimit,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue * height.doubleValue * 4 < Double(store.imageMemoryLimit),
                  let image = ImageToolsUI.clipboardImage(from: pasteboard), pasteboard.changeCount == change else { return }
            store.addImage(image.image, pixelScale: image.pixelScale)
        } else if filter != .text, let text = pasteboard.string(forType: .string), pasteboard.changeCount == change {
            store.addText(text)
        }
    }
}
