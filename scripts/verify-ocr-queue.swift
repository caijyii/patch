// Concatenated with ImageTools.swift; all images and OCR outputs are generated fixtures.
import Darwin

private final class OCRProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [Int] = []
    private var active = 0
    private var maximum = 0
    private var cancelCalls = 0
    func begin(_ id: Int) { lock.lock(); started.append(id); active += 1; maximum = max(maximum, active); lock.unlock() }
    func end() { lock.lock(); active -= 1; lock.unlock() }
    func cancelled() { lock.lock(); cancelCalls += 1; lock.unlock() }
    var snapshot: (started: [Int], maximum: Int, cancelCalls: Int) {
        lock.lock(); defer { lock.unlock() }
        return (started, maximum, cancelCalls)
    }
}

private final class OCRProbeRequest: VNRecognizeTextRequest {
    let state: OCRProbeState
    init(_ state: OCRProbeState) { self.state = state; super.init(completionHandler: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func cancel() { state.cancelled(); super.cancel() }
}

@MainActor
extension ImageToolsCoordinator {
    fileprivate func probeSetQueue(_ queue: ImageToolsOCRQueue) { ocrQueue = queue }
    fileprivate var probeOCRController: ImageToolsOCRController? { windows.values.compactMap { $0 as? ImageToolsOCRController }.first }
    fileprivate var probeWindowCount: Int { windows.count }
    fileprivate var probeJobCount: Int { ocrJobs.count }
}

@MainActor
extension ImageToolsOCRController {
    fileprivate var probeHasResult: Bool { hasResult }
}

private enum OCRProbeFailure: Error { case failed(String) }

@main
private struct OCRQueueProbe {
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw OCRProbeFailure.failed(message) }
        print("PASS: \(message)")
    }

    @MainActor private static func spin(until condition: () -> Bool, seconds: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        if !condition() { throw OCRProbeFailure.failed("Timed out waiting for asynchronous state") }
    }

    private static func image(_ width: Int) -> CGImage {
        CGContext(data: nil, width: width, height: 12, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    @MainActor private static func serialAndQueuedCancellation() throws {
        let state = OCRProbeState()
        let releaseFirst = DispatchSemaphore(value: 0)
        let queue = ImageToolsOCRQueue { image, cancellation in
            state.begin(image.width)
            defer { state.end() }
            if image.width == 11 { _ = releaseFirst.wait(timeout: .now() + 5) }
            try cancellation.checkCancellation()
            return "fixture \(image.width)"
        }
        var results: [String] = []
        let first = queue.enqueue(image(11)) { if case .success(let text) = $0 { results.append(text) } }
        try spin { state.snapshot.started == [11] }
        weak var queuedImage: CGImage?
        var cancelledCompletion = false
        let cancelled: ImageToolsOCRJob = autoreleasepool {
            let input = image(12)
            queuedImage = input
            return queue.enqueue(input) { _ in cancelledCompletion = true }
        }
        try expect(queuedImage != nil, "queued job retains input until cancellation")
        let next = queue.enqueue(image(13)) { if case .success(let text) = $0 { results.append(text) } }
        cancelled.cancel()
        try expect(queuedImage == nil, "queued cancellation immediately releases image before active task finishes")
        try expect(state.snapshot.started == [11], "serial queue leaves later work waiting")
        releaseFirst.signal()
        try spin { results.count == 2 }
        try expect(state.snapshot.maximum == 1, "OCR concurrency never exceeds one")
        try expect(state.snapshot.started == [11, 13], "cancelled queued task never starts and later task still runs")
        try expect(results == ["fixture 11", "fixture 13"] && !cancelledCompletion, "independent requests preserve FIFO results and suppress cancelled callback")
        withExtendedLifetime([first, cancelled, next]) {}
    }

    @MainActor private static func activeCancellation() throws {
        let state = OCRProbeState()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queue = ImageToolsOCRQueue { image, cancellation in
            state.begin(image.width)
            defer { state.end() }
            if image.width == 21 {
                let request = OCRProbeRequest(state)
                try cancellation.register(request)
                defer { cancellation.finishRequest() }
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                try cancellation.checkCancellation()
            }
            return "fixture \(image.width)"
        }
        var cancelledCompletion = false
        let first = queue.enqueue(image(21)) { _ in cancelledCompletion = true }
        try expect(started.wait(timeout: .now() + 3) == .success, "active request registered before cancellation")
        first.cancel()
        first.cancel()
        try expect(state.snapshot.cancelCalls == 1, "active cancellation invokes VNRequest.cancel once and is idempotent")
        var nextCompleted = false
        let next = queue.enqueue(image(22)) { if case .success = $0 { nextCompleted = true } }
        release.signal()
        try spin { nextCompleted }
        try expect(!cancelledCompletion && state.snapshot.started == [21, 22], "cancelled active work cannot write back and successor completes")
        let alreadyCancelled = ImageToolsOCRCancellation()
        alreadyCancelled.cancel()
        do {
            try alreadyCancelled.register(OCRProbeRequest(state))
            throw OCRProbeFailure.failed("pre-registration cancellation accepted a request")
        } catch is CancellationError {}
        try expect(state.snapshot.cancelCalls == 2, "cancellation before registration cancels newly registered request")
        let finished = ImageToolsOCRCancellation()
        try finished.register(OCRProbeRequest(state))
        finished.finishRequest()
        finished.cancel()
        try expect(state.snapshot.cancelCalls == 2, "completed request is detached before later cancellation")
        withExtendedLifetime([first, next]) {}
    }

    @MainActor private static func completionCancellation() throws {
        let finished = DispatchSemaphore(value: 0)
        let queue = ImageToolsOCRQueue { _, _ in finished.signal(); return "fixture" }
        var completed = false
        let job = queue.enqueue(image(31)) { _ in completed = true }
        try expect(finished.wait(timeout: .now() + 3) == .success, "worker result ready before main-thread delivery")
        job.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(!completed, "cancellation after recognition suppresses pending UI completion")
    }

    @MainActor private static func failureAndSuccessor() throws {
        let state = OCRProbeState()
        let queue = ImageToolsOCRQueue { image, _ in
            state.begin(image.width)
            defer { state.end() }
            if image.width == 35 { throw ScreenLeafError(message: "generated fixture failure") }
            return "generated fixture success"
        }
        var errorMessage: String?
        var resultText: String?
        let failing = queue.enqueue(image(35)) {
            if case .failure(let error) = $0 { errorMessage = (error as? ScreenLeafError)?.message }
        }
        let next = queue.enqueue(image(36)) {
            if case .success(let text) = $0 { resultText = text }
        }
        try spin { errorMessage != nil && resultText != nil }
        try expect(errorMessage == "generated fixture failure", "ordinary failure reaches its own completion with original error")
        try expect(resultText == "generated fixture success" && state.snapshot.started == [35, 36], "failed task does not prevent later request completion")
        withExtendedLifetime([failing, next]) {}
    }

    @MainActor private static func windowLifecycle() throws {
        let state = OCRProbeState()
        let release = DispatchSemaphore(value: 0)
        var coordinator: ImageToolsCoordinator? = ImageToolsCoordinator()
        coordinator?.probeSetQueue(ImageToolsOCRQueue { image, cancellation in
            state.begin(image.width)
            defer { state.end() }
            let request = OCRProbeRequest(state)
            try cancellation.register(request)
            defer { cancellation.finishRequest() }
            _ = release.wait(timeout: .now() + 5)
            try cancellation.checkCancellation()
            return "fixture \(image.width)"
        })
        weak var closedController: ImageToolsOCRController?
        autoreleasepool {
            coordinator?.recognize(image(41))
            closedController = coordinator?.probeOCRController
        }
        try spin { state.snapshot.started == [41] }
        autoreleasepool { coordinator?.probeOCRController?.close() }
        try expect(coordinator?.probeJobCount == 0 && coordinator?.probeWindowCount == 0, "closing result window removes and cancels its task")
        try spin { closedController == nil }
        try expect(closedController == nil, "active OCR does not retain a closed result controller")
        release.signal()
        autoreleasepool { coordinator?.recognize(image(42)) }
        try spin { state.snapshot.started == [41, 42] }
        weak var queuedImage: CGImage?
        autoreleasepool {
            let input = image(43)
            queuedImage = input
            coordinator?.recognize(input)
        }
        try expect(coordinator?.probeJobCount == 2, "multiple OCR windows keep independent jobs")
        let remainingControllers = NSHashTable<ImageToolsOCRController>.weakObjects()
        // Keep an independent weak reference to one of the two result windows.
        if let current = coordinator?.probeOCRController { remainingControllers.add(current) }
        autoreleasepool { coordinator?.closeAll() }
        try expect(coordinator?.probeJobCount == 0 && coordinator?.probeWindowCount == 0, "closeAll clears all OCR job and controller ownership")
        try expect(queuedImage == nil, "closeAll releases queued input immediately")
        release.signal()
        try spin { remainingControllers.allObjects.isEmpty }
        try expect(state.snapshot.cancelCalls == 2 && state.snapshot.started == [41, 42], "closeAll cancels active work and prevents queued work from starting")
        weak var weakCoordinator: ImageToolsCoordinator?
        weakCoordinator = coordinator
        coordinator = nil
        try expect(weakCoordinator == nil, "OCR lifecycle closures do not retain coordinator")
    }

    @MainActor static func main() {
        do {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            try serialAndQueuedCancellation()
            try activeCancellation()
            try completionCancellation()
            try failureAndSuccessor()
            try windowLifecycle()
            if CommandLine.arguments.contains("--ocr") {
                let coordinator = ImageToolsCoordinator()
                coordinator.recognize(DemoImage.make())
                try spin(until: { coordinator.probeJobCount == 0 }, seconds: 20)
                try expect(coordinator.probeOCRController?.probeHasResult == true, "real background OCR delivers recognized fixture to its result window")
                coordinator.closeAll()
                let context = CGContext(data: nil, width: 158, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 158, height: 90))
                let blank = context.makeImage()!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSAttributedString(string: "Patch", attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
                    .draw(at: CGPoint(x: 15, y: 32))
                NSGraphicsContext.restoreGraphicsState()
                coordinator.recognize(context.makeImage()!)
                try spin(until: { coordinator.probeJobCount == 0 }, seconds: 20)
                try expect(coordinator.probeOCRController?.probeHasResult == true, "158x90 background OCR completes with text")
                coordinator.closeAll()
                coordinator.recognize(blank)
                try spin(until: { coordinator.probeJobCount == 0 }, seconds: 20)
                try expect(coordinator.probeOCRController?.probeHasResult == false, "158x90 blank background OCR completes with an empty-result error")
                coordinator.closeAll()
                let text = try ImageToolsOCRWorker.read(DemoImage.make())
                try expect(text.contains("Patch"), "unchanged synchronous OCR API recognizes generated DemoImage")
            }
            print("PASS: OCR queue and lifecycle regression probe")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
