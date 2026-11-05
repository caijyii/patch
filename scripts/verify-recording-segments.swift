import AVFoundation
import AppKit
import Darwin

private struct SegmentFailure: Error, CustomStringConvertible { let description: String }
@main struct RecordingSegmentsVerification {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SegmentFailure(description: message) }
    }
    static func video(at url: URL, seconds: Int, red: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 128, AVVideoHeightKey: 80])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 80])
        writer.add(input)
        try require(writer.startWriting(), "Cannot start synthetic video writer")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 128, 80, kCVPixelFormatType_32ARGB, nil, &pixel)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<80 { for x in 0..<128 {
                let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                pointer[offset] = 255; pointer[offset + 1] = red ? 240 : 10
                pointer[offset + 2] = 10; pointer[offset + 3] = red ? 10 : 240
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)), "Cannot append video frame")
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Synthetic video writing failed")
    }
    static func audio(at url: URL, frequency: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 3)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 48000) * 0.3) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    static func segment(video: URL, audio: [URL], at output: URL, delay: Double, seconds: Int) async throws {
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: video)
        let sounds = audio.map { AVURLAsset(url: $0) }
        let videoTrack = try await source.loadTracks(withMediaType: .video).first!
        let full = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(seconds), preferredTimescale: 48000))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(full, of: videoTrack, at: .zero)
        for sound in sounds {
            let audioTrack = try await sound.loadTracks(withMediaType: .audio).first!
            let start = CMTime(seconds: delay, preferredTimescale: 48000)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                .insertTimeRange(CMTimeRange(start: .zero, duration: full.duration - start), of: audioTrack, at: start)
        }
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await exporter.export(to: output, as: .mp4)
        withExtendedLifetime([source] + sounds) {}
    }
    static func samples(_ asset: AVAsset, at second: Double) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: second, preferredTimescale: 48000), duration: CMTime(seconds: 0.04, preferredTimescale: 48000))
        try require(reader.startReading(), "Cannot decode synthetic audio")
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let bytes = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: bytes / 4)
            values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            result.append(contentsOf: values)
        }
        try require(reader.status == .completed, "Audio decode failed")
        return result
    }
    static func rms(_ asset: AVAsset, at second: Double) async throws -> Double {
        let values = try await samples(asset, at: second)
        return values.isEmpty ? 0 : sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count))
    }
    static func amplitude(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (index, value) in samples.enumerated() {
            let angle = Double(index) * 2 * .pi * frequency / 48000
            real += Double(value) * cos(angle); imaginary += Double(value) * sin(angle)
        }
        return samples.isEmpty ? 0 : 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let firstVideo = root.appendingPathComponent("red.mov"), secondVideo = root.appendingPathComponent("blue.mov")
            let sound = root.appendingPathComponent("system.wav"), microphone = root.appendingPathComponent("microphone.wav")
            let first = root.appendingPathComponent("first.mp4"), second = root.appendingPathComponent("second.mp4")
            try await video(at: firstVideo, seconds: 1, red: true)
            try await video(at: secondVideo, seconds: 2, red: false)
            try audio(at: sound, frequency: 440); try audio(at: microphone, frequency: 880)
            try await segment(video: firstVideo, audio: [sound, microphone], at: first, delay: 0.2, seconds: 1)
            try await segment(video: secondVideo, audio: [sound, microphone], at: second, delay: 0, seconds: 2)
            let inputAudioCount = try await AVURLAsset(url: first).loadTracks(withMediaType: .audio).count
            try require(inputAudioCount == 2, "Synthetic fixture did not retain its two independent audio tracks")
            let output = root.appendingPathComponent("joined.mp4")
            let duration = try await RecordingSegments.assemble([first, second], at: output)
            let result = AVURLAsset(url: output)
            let exportedAudio = try await result.loadTracks(withMediaType: .audio)
            try require(exportedAudio.count == 1, "Export must mix microphone and system sound into one universally playable audio track; got \(exportedAudio.count)")
            let actualDuration = try await result.load(.duration)
            try require(abs(duration.seconds - 3) < 0.01 && abs(actualDuration.seconds - 3) < 0.06,
                        "Paused wall time or audio tails leaked into the joined duration")
            let generator = AVAssetImageGenerator(asset: result)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let red = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 30)).image
            let blue = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 30)).image
            let firstColor = NSBitmapImageRep(cgImage: red).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!
            let secondColor = NSBitmapImageRep(cgImage: blue).colorAt(x: 40, y: 40)!.usingColorSpace(.deviceRGB)!
            try require(firstColor.redComponent > 0.7 && secondColor.blueComponent > 0.7, "Segment order or frames changed at the join")
            let silent = try await rms(result, at: 0.03), audible = try await rms(result, at: 0.3)
            let before = try await rms(result, at: 0.94), after = try await rms(result, at: 1.02)
            try require(silent < 0.01 && audible > 0.1 && before > 0.1 && after > 0.1,
                        "Audio/video offset was lost or an artificial silence appeared at the pause boundary")
            let mixed = try await samples(result, at: 1.3)
            try require(amplitude(mixed, frequency: 440) > 0.15 && amplitude(mixed, frequency: 880) > 0.15,
                        "The exported soundtrack lost system audio or microphone audio")
            try require(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                        "Assembly removed original segments before destination commit")
            let destination = root.appendingPathComponent("saved.mp4")
            try RecordingFileStorage.saveCompletedRecording(at: output, to: destination)
            try require(FileManager.default.fileExists(atPath: destination.path), "Combined file did not commit")
            let recovery = root.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let savedSegment = recovery.appendingPathComponent("saved.mp4"), unconfirmed = recovery.appendingPathComponent("unconfirmed.mp4")
            try FileManager.default.copyItem(at: first, to: savedSegment)
            try FileManager.default.copyItem(at: second, to: unconfirmed)
            let remaining = RecordingFileStorage.removeSavedSegments([savedSegment], in: recovery)
            try require(remaining == recovery && FileManager.default.fileExists(atPath: unconfirmed.path)
                        && !FileManager.default.fileExists(atPath: savedSegment.path),
                        "Recovery cleanup deleted an unconfirmed segment not included in the saved file")
            try require(RecordingFileStorage.removeSavedSegments([unconfirmed], in: recovery) == nil,
                        "Successful cleanup did not remove an empty session directory")
            print("PASS: synthetic multi-audio segments concatenate without pause gaps, retain A/V offsets and frame order, preserve originals until commit")
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
