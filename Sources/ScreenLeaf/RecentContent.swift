// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import ImageIO

/// Session-only content. Preferences persist separately; captured content never goes to disk.
@MainActor
final class RecentContentStore {
    enum Filter: Int {
        case all, images, text

        func includes(_ item: Item) -> Bool {
            switch (self, item.content) {
            case (.images, .text), (.text, .image): return false
            default: return true
            }
        }
    }

    struct Item: Identifiable {
        enum Content {
            case image(Data, CGSize, CGFloat?)
            case text(String)
        }
        let id: UUID
        let fingerprint: String
        let content: Content
        let memoryCost: Int
        let date: Date
        let thumbnail: NSImage?
        var kindTitle: String {
            switch content { case .image: return L("图片"); case .text: return L("文本") }
        }
        var title: String {
            switch content {
            case .image(_, let size, _): return LF("图片 · %d × %d", Int(size.width), Int(size.height))
            case .text(let value): return String(value.prefix(180))
            }
        }
    }
    private(set) var items: [Item] = []
    private(set) var memoryUsage = 0
    private(set) var limit: Int
    let memoryLimit: Int
    private(set) var notice: String?
    var onChange: (() -> Void)?
    var onUserRemoval: ((Filter) -> Void)?
    private let now: () -> Date

    init(limit: Int = 20, memoryLimit: Int = 128 * 1024 * 1024, now: @escaping () -> Date = Date.init) {
        self.limit = max(1, limit)
        self.memoryLimit = max(1, memoryLimit)
        self.now = now
    }
    func setLimit(_ value: Int) {
        limit = max(1, value); trim(); onChange?()
    }
    func addText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= memoryLimit else { oversized(); return }
        insert(.init(id: UUID(), fingerprint: "text:" + digest(data), content: .text(text),
                     memoryCost: data.count, date: now(), thumbnail: nil))
    }
    func addImage(_ image: CGImage, pixelScale: CGFloat?) {
        // Budget decoded pixels as well as compressed data, before allocating the canonical bitmap.
        let pixels = Int64(image.width) * Int64(image.height) * 4
        guard pixels > 0, pixels < Int64(memoryLimit) else { oversized(); return }
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
        guard cost <= memoryLimit else { oversized(); return }
        insert(.init(id: UUID(), fingerprint: fingerprint, content: .image(data, pixelSize, validScale),
                     memoryCost: cost, date: now(), thumbnail: thumbnail))
    }
    func remove(_ id: UUID) {
        onUserRemoval?(.all)
        items.removeAll { $0.id == id }; recalculate(); onChange?()
    }
    func clear(_ filter: Filter = .all) {
        items.removeAll(where: filter.includes)
        recalculate(); notice = nil
        onUserRemoval?(filter)
        onChange?()
    }
    private func insert(_ item: Item) {
        // Recopying or repinning an existing item neither duplicates it nor changes recency.
        guard !items.contains(where: { $0.fingerprint == item.fingerprint }) else { return }
        notice = nil; items.insert(item, at: 0); trim(); onChange?()
    }
    private func trim() {
        recalculate()
        while items.count > limit || memoryUsage > memoryLimit {
            guard let last = items.popLast() else { break }
            memoryUsage -= last.memoryCost
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
        guard !excluded.contains(where: { types.contains(NSPasteboard.PasteboardType($0)) }),
              !types.contains(.fileURL) else { return }
        if types.contains(.png) || types.contains(.tiff) {
            guard filter != .images else { return }
            // Reject excessive encoded payloads before asking AppKit to decode them.
            guard let data = pasteboard.data(forType: types.contains(.png) ? .png : .tiff), data.count <= store.memoryLimit,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue * height.doubleValue * 4 < Double(store.memoryLimit),
                  let image = ImageToolsUI.clipboardImage(from: pasteboard), pasteboard.changeCount == change else { return }
            store.addImage(image.image, pixelScale: image.pixelScale)
        } else if filter != .text, let text = pasteboard.string(forType: .string), pasteboard.changeCount == change {
            store.addText(text)
        }
    }
}
