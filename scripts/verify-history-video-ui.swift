// Synthetic video copies and an isolated pasteboard only. Never opens a real player.
import AppKit
import Darwin

private struct VideoUIFailure: Error, CustomStringConvertible {
    let description: String
}

@main private struct VerifyHistoryVideoUI {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else {
            print("FAIL: expected output directory and synthetic video fixture path")
            exit(64)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard !NSScreen.screens.isEmpty else {
            print("SKIP: history video UI requires an available desktop")
            exit(77)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        Task { @MainActor in
            do {
                try await verify(output: output, fixture: fixture)
                print("PASS: history video UI verification completed")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VideoUIFailure(description: message) }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    @MainActor private static func button(in content: NSView, id: UUID, action: String) throws -> NSButton {
        guard let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
            $0.identifier?.rawValue == id.uuidString && $0.action == NSSelectorFromString(action)
        }) else { throw VideoUIFailure(description: "Missing \(action) button for \(id)") }
        return button
    }
    @MainActor private static func waitForVideo(_ store: RecentContentStore, url: URL) async throws -> RecentContentStore.Item {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let item = store.items.first(where: {
                if case .video(let reference) = $0.content { return reference.url == url }
                return false
            }) { return item }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VideoUIFailure(description: "Synthetic video was not collected within 10 seconds")
    }
    @MainActor private static func hasNotice(_ content: NSView, text: String) -> Bool {
        descendants(content).compactMap { $0 as? NSTextField }.contains {
            !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == text
        }
    }
    @MainActor private static func render(_ content: NSView, to url: URL) throws {
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw VideoUIFailure(description: "Cannot allocate history screenshot")
        }
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VideoUIFailure(description: "Cannot encode history screenshot")
        }
        try png.write(to: url)
    }
    @MainActor private static func verifyTargets(_ content: NSView, id: UUID) throws {
        let copy = try button(in: content, id: id, action: "copyItem:")
        let remove = try button(in: content, id: id, action: "removeItem:")
        guard let card = copy.superview, card === remove.superview else {
            throw VideoUIFailure(description: "Copy and delete no longer share a card")
        }
        try require(!copy.frame.intersects(remove.frame) && card.bounds.contains(copy.frame)
                    && card.bounds.contains(remove.frame), "Copy/delete targets overlap or escape the card")
        guard let metadata = card.subviews.compactMap({ $0 as? NSTextField }).first(where: {
            $0.identifier?.rawValue == "history.metadata.\(id.uuidString)"
        }) else { throw VideoUIFailure(description: "Video footer metadata is missing") }
        try require(abs(metadata.frame.midY - copy.frame.midY) < 0.5
                    && abs(copy.frame.midY - remove.frame.midY) < 0.5
                    && metadata.frame.maxX + 8 <= copy.frame.minX
                    && metadata.intrinsicContentSize.width <= metadata.bounds.width,
                    "Video type/time is clipped or does not share the copy/delete row")
        for control in [copy, remove] {
            guard let parent = content.superview else { throw VideoUIFailure(description: "History is detached") }
            let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: parent)
            try require(content.hitTest(center) === control, "Card intercepts the \(String(describing: control.action)) hit target")
        }
        guard let parent = content.superview else { throw VideoUIFailure(description: "History is detached") }
        let captionPoint = metadata.convert(CGPoint(x: metadata.bounds.midX, y: metadata.bounds.midY), to: parent)
        let open = try button(in: content, id: id, action: "pinItem:")
        try require(content.hitTest(captionPoint) === open, "Footer metadata blocks the card's open target")
    }

    @MainActor private static func verify(output: URL, fixture: URL) async throws {
        let files = FileManager.default
        try require(files.isReadableFile(atPath: fixture.path), "Synthetic video fixture is unreadable")
        let run = output.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: run) }
        let ext = fixture.pathExtension.isEmpty ? "mov" : fixture.pathExtension
        let videoURL = run.appendingPathComponent("测试录屏.\(ext)")
        try files.copyItem(at: fixture, to: videoURL)
        guard let capturedAt = Calendar.current.date(byAdding: .year, value: -1, to: Date()) else {
            throw VideoUIFailure(description: "Cannot create cross-year video date")
        }
        let store = RecentContentStore(now: { capturedAt })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = RecentClipboardMonitor(store: store, pasteboard: board)
        monitor.setEnabled(true)
        defer { monitor.setEnabled(false) }
        store.addText("Synthetic text retained beside a video")
        guard let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VideoUIFailure(description: "Cannot create image fixture")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        guard let image = context.makeImage() else { throw VideoUIFailure(description: "Missing synthetic image") }
        store.addImage(image, pixelScale: 2)
        store.addVideo(videoURL)
        let item = try await waitForVideo(store, url: videoURL)
        try require(store.items.count == 3 && !item.isPinnable, "Mixed fixture or video pin eligibility is incorrect")
        var openRequests: [URL] = [], pinned: [UUID] = [], copies = 0, openSucceeds = true
        AppLocalization.language = .simplifiedChinese
        let history = RecentContentWindowController(store: store, pasteboard: board, onCopy: {
            copies += 1; monitor.acknowledgeCopy()
        }, openVideo: { url in
            openRequests.append(url); return openSucceeds
        }, onPin: { pinned.append($0.id) })
        store.onChange = { [weak history] in history?.reload() }
        defer { history.close(); store.onChange = nil; store.clear(); NSApp.appearance = nil }
        guard let window = history.window, let content = window.contentView else {
            throw VideoUIFailure(description: "History window is missing")
        }
        window.setContentSize(CGSize(width: 460, height: 540))
        history.showWindow(nil)
        guard let filter = descendants(content).compactMap({ $0 as? NSSegmentedControl }).first(where: {
            $0.identifier?.rawValue == "history.filter"
        }) else { throw VideoUIFailure(description: "History filter is missing") }
        filter.selectedSegment = RecentContentStore.Filter.videos.rawValue
        filter.sendAction(filter.action, to: filter.target)
        let cards = descendants(content).filter { $0.identifier?.rawValue.hasPrefix("history.card.") == true }
        try require(cards.count == 1 && cards.first?.identifier?.rawValue == "history.card.\(item.id.uuidString)",
                    "Video filter includes text/images or omits video")

        for language in [AppLanguagePreference.simplifiedChinese, .english] {
            AppLocalization.language = language
            for appearance in [AppAppearancePreference.light, .dark] {
                NSApp.appearance = appearance.appearance
                history.reload()
                try await Task.sleep(for: .milliseconds(80))
                content.layoutSubtreeIfNeeded()
                try verifyTargets(content, id: item.id)
                let visible = content.subviews.filter { !$0.isHidden && !($0 is NSScrollView) }
                for first in visible.indices {
                    for second in visible.indices where second > first {
                        try require(!visible[first].frame.intersects(visible[second].frame), "Narrow video toolbar controls overlap")
                    }
                }
                try render(content, to: output.appendingPathComponent("history-video-\(language.rawValue)-\(appearance.rawValue).png"))
            }
        }
        print("PASS: video filtering, narrow light/dark Chinese/English layout and independent copy/delete hit targets")
        AppLocalization.language = .simplifiedChinese
        history.reload()
        let open = try button(in: content, id: item.id, action: "pinItem:")
        open.performClick(nil)
        try require(openRequests == [videoURL] && pinned.isEmpty, "Video click did not use the player callback exclusively")
        openSucceeds = false
        open.performClick(nil)
        try require(openRequests == [videoURL, videoURL] && hasNotice(content,
            text: L("无法打开视频，请检查默认播放器或在 Finder 中打开。")), "Player failure omitted feedback")
        history.reload()
        let beforeCopy = store.items.map(\.id)
        let copy = try button(in: content, id: item.id, action: "copyItem:")
        copy.performClick(nil)
        let copiedURLs = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL]
        let copiedPaths = copiedURLs?.map { ($0 as URL).standardizedFileURL }
        try require(copiedPaths == [videoURL.standardizedFileURL] && copies == 1 && copy.toolTip == L("已复制"),
                    "Video copy mismatch: URLs=\(String(describing: copiedPaths)); copies=\(copies); tooltip=\(String(describing: copy.toolTip))")
        monitor.poll()
        try await Task.sleep(for: .milliseconds(100))
        try require(store.items.map(\.id) == beforeCopy && pinned.isEmpty && openRequests.count == 2,
                    "Video copy reordered/duplicated history, pinned content or opened a player")
        print("PASS: video opening uses injected player, failed opening is reported, file copy preserves history")

        let remove = try button(in: content, id: item.id, action: "removeItem:")
        remove.performClick(nil)
        try require(!store.items.contains { $0.id == item.id } && files.fileExists(atPath: videoURL.path),
                    "Deleting video history deleted its source file or kept the record")
        store.addVideo(videoURL)
        let restored = try await waitForVideo(store, url: videoURL)
        try files.removeItem(at: videoURL)
        let unavailable = L("原视频已移动、删除或无法访问，请重新复制该文件。")
        let boardChange = board.changeCount
        try button(in: content, id: restored.id, action: "pinItem:").performClick(nil)
        try require(openRequests.count == 2 && hasNotice(content, text: unavailable),
                    "Deleted file was opened or omitted the unavailable notice")
        let staleCopy = try button(in: content, id: restored.id, action: "copyItem:")
        staleCopy.performClick(nil)
        try require(board.changeCount == boardChange && copies == 1 && openRequests.count == 2
                    && staleCopy.toolTip == L("复制失败 · 可重试") && hasNotice(content, text: unavailable),
                    "Unavailable file copy modified the clipboard, reported success or omitted its notice")
        try render(content, to: output.appendingPathComponent("history-video-unavailable.png"))
        print("PASS: deleting history preserves source files; unavailable video open/copy preserve clipboard and report failure")
    }
}
