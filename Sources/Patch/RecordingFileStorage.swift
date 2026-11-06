// SPDX-FileCopyrightText: 2026 caijyii
// SPDX-License-Identifier: MIT

import Foundation

enum RecordingFileStorage {
    /// A recovery export can omit a damaged or unconfirmed last segment. Never
    /// delete files that were not part of the successfully saved recording.
    static func removeSavedSegments(_ segments: [URL], in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let manager = FileManager.default
        for segment in segments { try? manager.removeItem(at: segment) }
        guard let remaining = try? manager.contentsOfDirectory(atPath: directory.path) else { return directory }
        guard remaining.isEmpty else { return directory }
        try? manager.removeItem(at: directory)
        return manager.fileExists(atPath: directory.path) ? directory : nil
    }

    static func makeWorkingURL() -> URL {
        // A save-panel grant covers the selected file, not arbitrary siblings.
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Patch-\(UUID().uuidString).mp4")
    }

    /// Call off the main actor: exporting a large recording may require a full copy.
    static func saveCompletedRecording(at workingURL: URL, to destination: URL) throws {
        let manager = FileManager.default
        // Foundation supplies a writable staging directory on the destination's
        // volume. replaceItemAt requires both files to be on the same volume.
        let stagingDirectory = try manager.url(for: .itemReplacementDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: destination,
                                               create: true)
        defer { try? manager.removeItem(at: stagingDirectory) }
        let stagedURL = stagingDirectory.appendingPathComponent("Recording.mp4")
        // Keep the recording recoverable if copying or committing the export fails.
        try manager.copyItem(at: workingURL, to: stagedURL)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: stagedURL)
        } else {
            try manager.moveItem(at: stagedURL, to: destination)
        }
        // The destination has committed. Cleanup failure must not report a failed save.
        try? manager.removeItem(at: workingURL)
    }
}
