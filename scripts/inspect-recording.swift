import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Darwin

private struct InspectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private enum Expectation {
    case none, audio, silent
}

private struct Options {
    let fileURL: URL
    let expectation: Expectation
    let thresholdDBFS: Double

    static let usage = """
    Usage: inspect-recording.sh TEST.mp4 [--expect-audio | --expect-silent] [--threshold-dbfs -60]

    Reads only the explicitly supplied file. It never plays or exports audio.
    --expect-audio   Require an audio track whose decoded buffer RMS exceeds the threshold.
    --expect-silent  Require no audio tracks, or every track's buffer RMS below the threshold.
    The default signal threshold is -60 dBFS; it is a test heuristic, not a source classifier.
    Exit 1: invalid/unreadable media, missing video, zero duration, or failed assertion.
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var file: String?
        var expectation: Expectation = .none
        var thresholdDBFS = -60.0
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--expect-audio":
                guard expectation == .none else {
                    throw InspectionError("Choose only one audio expectation.")
                }
                expectation = .audio
            case "--expect-silent":
                guard expectation == .none else {
                    throw InspectionError("Choose only one audio expectation.")
                }
                expectation = .silent
            case "--threshold-dbfs":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      value.isFinite, (-160...0).contains(value) else {
                    throw InspectionError("--threshold-dbfs requires a finite number from -160 to 0.")
                }
                thresholdDBFS = value
            default:
                guard !arguments[index].hasPrefix("-"), file == nil else {
                    throw InspectionError("Unexpected argument: \(arguments[index])")
                }
                file = arguments[index]
            }
            index += 1
        }
        guard let file else { throw InspectionError("Specify one test MP4 path.") }
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard fileURL.pathExtension.lowercased() == "mp4" else {
            throw InspectionError("The explicit input must be a test .mp4 file.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw InspectionError("The supplied file does not exist or cannot be read: \(fileURL.path)")
        }
        return Options(fileURL: fileURL, expectation: expectation, thresholdDBFS: thresholdDBFS)
    }
}

private struct AudioStatistics {
    var sampleCount = 0
    var squareSum = 0.0
    var absolutePeak = 0.0
    var maximumBufferRMS = 0.0

    var rms: Double { sampleCount == 0 ? 0 : sqrt(squareSum / Double(sampleCount)) }

    mutating func consume(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var bufferSquareSum = 0.0
        for value in samples {
            let sample = Double(value)
            guard sample.isFinite else { throw InspectionError("Decoded audio contains non-finite samples.") }
            bufferSquareSum += sample * sample
            absolutePeak = max(absolutePeak, abs(sample))
        }
        sampleCount += samples.count
        squareSum += bufferSquareSum
        maximumBufferRMS = max(maximumBufferRMS, sqrt(bufferSquareSum / Double(samples.count)))
    }
}

private func fourCC(_ value: FourCharCode) -> String {
    let bytes: [UInt8] = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                         UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    if bytes.allSatisfy({ (32...126).contains($0) }), let text = String(bytes: bytes, encoding: .ascii) {
        return text
    }
    return String(format: "0x%08x", value)
}

private func dbFS(_ amplitude: Double) -> String {
    amplitude <= 0 ? "-inf" : String(format: "%.2f", 20 * log10(amplitude))
}

private func verifyVideoIsDecodable(asset: AVAsset, track: AVAssetTrack) throws {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    guard reader.canAdd(output) else { throw InspectionError("Cannot configure video decoding.") }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? InspectionError("Cannot start reading video.")
    }
    defer { reader.cancelReading() }
    guard let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
        throw reader.error ?? InspectionError("The video track contains no decodable frame.")
    }
}

private func measureAudio(asset: AVAsset, track: AVAssetTrack) throws -> AudioStatistics {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    guard reader.canAdd(output) else { throw InspectionError("Cannot configure audio decoding.") }
    reader.add(output)
    guard reader.startReading() else {
        throw reader.error ?? InspectionError("Cannot start reading audio.")
    }
    var statistics = AudioStatistics()
    while let sample = output.copyNextSampleBuffer() {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else {
            throw InspectionError("An audio sample has no PCM data buffer.")
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount % MemoryLayout<Float>.size == 0 else {
            throw InspectionError("Decoded PCM has an invalid byte length.")
        }
        var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        if byteCount > 0 {
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount,
                                           destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else {
                throw InspectionError("Cannot read decoded audio bytes (status \(status)).")
            }
            try statistics.consume(samples)
        }
    }
    guard reader.status == .completed else {
        throw reader.error ?? InspectionError("Audio reading did not finish successfully.")
    }
    return statistics
}

@main
private enum RecordingInspection {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(Options.usage)
            return
        }
        do {
            let options = try Options.parse(arguments)
            try await inspect(options)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func inspect(_ options: Options) async throws {
        let asset = AVURLAsset(url: options.fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard try await asset.load(.isReadable) else { throw InspectionError("The MP4 is not readable by AVFoundation.") }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw InspectionError("The recording duration must be greater than zero.") }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw InspectionError("The recording has no video track.") }
        print("File: \(options.fileURL.path)")
        print(String(format: "Duration: %.3f s; video tracks: %d; audio tracks: %d", duration, videoTracks.count, audioTracks.count))
        for (index, track) in videoTracks.enumerated() {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let displaySize = size.applying(transform)
            guard size.width > 0, size.height > 0 else { throw InspectionError("Video has invalid pixel dimensions.") }
            let frameRate = try await track.load(.nominalFrameRate)
            let descriptions = try await track.load(.formatDescriptions)
            let codecs = descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }.joined(separator: ",")
            try verifyVideoIsDecodable(asset: asset, track: track)
            print(String(format: "Video %d: %.0f x %.0f pixels; display %.0f x %.0f; %.2f fps; codec %@; first frame decodes",
                         index + 1, size.width, size.height, abs(displaySize.width), abs(displaySize.height), frameRate, codecs))
        }

        let threshold = pow(10, options.thresholdDBFS / 20)
        var signalTracks = 0
        for (index, track) in audioTracks.enumerated() {
            let descriptions = try await track.load(.formatDescriptions)
            let formats = descriptions.map { description -> String in
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    return fourCC(CMFormatDescriptionGetMediaSubType(description))
                }
                return "\(fourCC(basic.mFormatID)), \(Int(basic.mSampleRate)) Hz, \(basic.mChannelsPerFrame) channel(s)"
            }.joined(separator: "; ")
            let statistics = try measureAudio(asset: asset, track: track)
            let hasSignal = statistics.maximumBufferRMS > threshold
            if hasSignal { signalTracks += 1 }
            print("Audio \(index + 1): \(formats); decoded samples \(statistics.sampleCount)")
            print("  RMS \(dbFS(statistics.rms)) dBFS; maximum buffer RMS \(dbFS(statistics.maximumBufferRMS)) dBFS; absolute peak \(dbFS(statistics.absolutePeak)) dBFS; \(hasSignal ? "signal" : "below threshold")")
        }
        print(String(format: "Signal threshold: %.2f dBFS (maximum decoded buffer RMS)", options.thresholdDBFS))
        switch options.expectation {
        case .none:
            print("PASS: readable video with positive duration; audio summarized without an assertion.")
        case .audio:
            guard signalTracks > 0 else {
                throw InspectionError("Expected audio signal above \(options.thresholdDBFS) dBFS; none was found.")
            }
            print("PASS: an audio track contains a signal above the threshold.")
        case .silent:
            guard signalTracks == 0 else {
                throw InspectionError("Expected silent audio; \(signalTracks) track(s) exceed the threshold.")
            }
            print("PASS: no audio tracks, or all tracks are below the signal threshold.")
        }
    }
}
