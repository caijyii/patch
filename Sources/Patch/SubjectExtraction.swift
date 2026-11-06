// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision

enum SubjectExtractionError: LocalizedError {
    case noSubjects
    case unsupportedMask
    case analysisFailed(Error)
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .noSubjects: return L("没有识别到可提取的主体。可以调整截图范围后再试。")
        case .unsupportedMask: return L("暂时无法读取主体轮廓，请换一个截图范围再试。")
        case .analysisFailed: return L("主体分析未完成，请稍后重试或换一个截图范围。")
        case .renderingFailed: return L("无法生成透明主体图片，请重新分析后再试。")
        }
    }
}

/// Analysis results may cross queues, but their Vision handler is used serially.
/// Point lookup uses a copied label map; image generation is protected by a lock.
// CGImage and the copied label bytes are immutable. The only mutable framework
// state lives in storage and is accessed under its lock after analysis finishes.
struct SubjectExtractionResult: @unchecked Sendable {
    let source: CGImage
    let instances: IndexSet
    private let storage: SubjectExtractionStorage

    fileprivate init(source: CGImage, observation: VNInstanceMaskObservation,
                     handler: VNImageRequestHandler) throws {
        self.source = source
        instances = observation.allInstances.subtracting(IndexSet(integer: 0))
        guard !instances.isEmpty else { throw SubjectExtractionError.noSubjects }
        storage = try SubjectExtractionStorage(source: source, observation: observation, handler: handler)
    }

    /// The point uses the original image's normalized top-left coordinate system.
    /// Both edges, including 1, are accepted; values outside 0...1 return nil.
    func instance(atNormalizedTopLeft point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let x = min(storage.labelWidth - 1, Int(point.x * CGFloat(storage.labelWidth)))
        let y = min(storage.labelHeight - 1, Int(point.y * CGFloat(storage.labelHeight)))
        let value = Int(storage.labels[y * storage.labelWidth + x])
        return value != 0 && instances.contains(value) ? value : nil
    }

    /// Keeps the original canvas size. All unselected pixels have zero alpha.
    func image(selecting selection: IndexSet) throws -> CGImage? {
        let valid = selection.intersection(instances)
        // Vision interprets an empty set as all foreground instances.
        guard !valid.isEmpty else { return nil }
        return try storage.render(selecting: valid, maskOnly: false)
    }

    /// A full-size white silhouette whose alpha is the selected soft mask.
    func maskImage(selecting selection: IndexSet) throws -> CGImage? {
        let valid = selection.intersection(instances)
        guard !valid.isEmpty else { return nil }
        return try storage.render(selecting: valid, maskOnly: true)
    }
}

enum SubjectExtraction {
    /// Call away from the main thread; this performs the system Vision analysis.
    static func analyze(_ image: CGImage) throws -> SubjectExtractionResult {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { throw SubjectExtractionError.analysisFailed(error) }
        guard let observation = request.results?.first else { throw SubjectExtractionError.noSubjects }
        return try SubjectExtractionResult(source: image, observation: observation, handler: handler)
    }
}

// Observation, handler and CIContext never escape this storage. All calls that
// use them after construction are serialized by lock; label reads are immutable.
private final class SubjectExtractionStorage: @unchecked Sendable {
    let labelWidth: Int
    let labelHeight: Int
    let labels: [UInt8]
    private let source: CGImage
    private let observation: VNInstanceMaskObservation
    private let handler: VNImageRequestHandler
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    init(source: CGImage, observation: VNInstanceMaskObservation, handler: VNImageRequestHandler) throws {
        self.source = source
        self.observation = observation
        self.handler = handler
        let buffer = observation.instanceMask
        labelWidth = CVPixelBufferGetWidth(buffer)
        labelHeight = CVPixelBufferGetHeight(buffer)
        let count = labelWidth.multipliedReportingOverflow(by: labelHeight)
        guard labelWidth > 0, labelHeight > 0, !count.overflow,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            throw SubjectExtractionError.unsupportedMask
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw SubjectExtractionError.unsupportedMask
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self),
              CVPixelBufferGetBytesPerRow(buffer) >= labelWidth else {
            throw SubjectExtractionError.unsupportedMask
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var copied: [UInt8] = []
        copied.reserveCapacity(count.partialValue)
        for y in 0..<labelHeight {
            copied.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: y * stride), count: labelWidth))
        }
        labels = copied
    }

    func render(selecting instances: IndexSet, maskOnly: Bool) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        do {
            let buffer: CVPixelBuffer
            if maskOnly {
                buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
            } else {
                buffer = try observation.generateMaskedImage(ofInstances: instances, from: handler,
                                                             croppedToInstancesExtent: false)
            }
            guard CVPixelBufferGetWidth(buffer) == source.width,
                  CVPixelBufferGetHeight(buffer) == source.height else {
                throw SubjectExtractionError.renderingFailed
            }
            var image = CIImage(cvPixelBuffer: buffer)
            if maskOnly {
                guard let filtered = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: image])?.outputImage else {
                    throw SubjectExtractionError.renderingFailed
                }
                image = filtered
            }
            let colorSpace = source.colorSpace?.model == .rgb ? source.colorSpace! : CGColorSpaceCreateDeviceRGB()
            guard let output = context.createCGImage(image,
                    from: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                    format: .RGBA8, colorSpace: colorSpace) else {
                throw SubjectExtractionError.renderingFailed
            }
            return output
        } catch { throw SubjectExtractionError.renderingFailed }
    }
}
