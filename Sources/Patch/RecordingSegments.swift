// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import AVFoundation
import Foundation

/// Only recorded media is concatenated. Wall-clock pauses never enter this timeline.
enum RecordingSegments {
    static func assemble(_ files: [URL], at output: URL) async throws -> CMTime {
        guard !files.isEmpty else { throw PatchError(message: L("没有可保存的录屏片段。")) }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PatchError(message: L("无法创建录屏导出轨道。"))
        }
        var audio: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        let assets = files.map { AVURLAsset(url: $0) }
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw PatchError(message: L("录屏片段缺少画面，原文件已保留。"))
            }
            let range = try await sourceVideo.load(.timeRange)
            guard range.isValid, range.duration.isNumeric, range.duration > .zero else {
                throw PatchError(message: L("录屏片段为空，原文件已保留。"))
            }
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            if index == 0 { video.preferredTransform = try await sourceVideo.load(.preferredTransform) }
            let sourceAudio = try await asset.loadTracks(withMediaType: .audio)
            for (trackIndex, track) in sourceAudio.enumerated() {
                while audio.count <= trackIndex {
                    guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw PatchError(message: L("无法创建录屏音轨，原文件已保留。"))
                    }
                    audio.append(target)
                }
                // Preserve audio's position relative to the video within each segment.
                // Trim encoder pre-roll/tails so neither audio nor pauses extend the output.
                let intersection = CMTimeRangeGetIntersection(range, otherRange: try await track.load(.timeRange))
                if intersection.isValid, intersection.duration > .zero {
                    try audio[trackIndex].insertTimeRange(intersection, of: track,
                        at: cursor + intersection.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw PatchError(message: L("无法准备录屏导出，原文件已保留。"))
        }
        if audio.count > 1 {
            // A file with independent audio tracks is not mixed by every player.
            // Flatten system sound and microphone into the exported soundtrack.
            let mix = AVMutableAudioMix()
            mix.inputParameters = audio.map { track in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(1, at: .zero)
                return parameters
            }
            exporter.audioMix = mix
        }
        exporter.timeRange = CMTimeRange(start: .zero, duration: cursor)
        try await exporter.export(to: output, as: .mp4)
        withExtendedLifetime(assets) {}
        return cursor
    }
}
