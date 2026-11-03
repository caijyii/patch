import Foundation

@main
enum RecordingFileVerification {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw NSError(domain: "RecordingFileVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let manager = FileManager.default
        // An optional directory on a mounted test volume exercises cross-volume exports.
        let root = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? manager.temporaryDirectory
        let directory = root.appendingPathComponent("PatchRecordingTests-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var workingURLs: [URL] = []
        defer {
            try? manager.removeItem(at: directory)
            for url in workingURLs { try? manager.removeItem(at: url) }
        }
        let oldBytes = Data("Existing file must survive an unsuccessful export.".utf8)
        let videoBytes = Data((0..<65_536).map { UInt8($0 % 251) })
        func recording() throws -> URL {
            let url = RecordingFileStorage.makeWorkingURL()
            workingURLs.append(url)
            try require(url.deletingLastPathComponent().standardizedFileURL
                        == manager.temporaryDirectory.standardizedFileURL,
                        "Recording must be staged in the application's temporary directory")
            try videoBytes.write(to: url)
            return url
        }

        let freshTarget = directory.appendingPathComponent("new.mp4")
        let first = try recording()
        try require(!manager.fileExists(atPath: freshTarget.path), "Recording touched its destination early")
        try RecordingFileStorage.saveCompletedRecording(at: first, to: freshTarget)
        try require(Data(contentsOf: freshTarget) == videoBytes, "New export bytes differ")
        try require(!manager.fileExists(atPath: first.path), "Successful export left its recording behind")
        print("PASS: new recording export")

        let existingTarget = directory.appendingPathComponent("existing.mp4")
        try oldBytes.write(to: existingTarget)
        let second = try recording()
        try require(Data(contentsOf: existingTarget) == oldBytes, "Recording overwrote its destination early")
        try require(first != second, "Recordings must have unique paths")
        try RecordingFileStorage.saveCompletedRecording(at: second, to: existingTarget)
        try require(Data(contentsOf: existingTarget) == videoBytes, "Replacement bytes differ")
        try require(!manager.fileExists(atPath: second.path), "Successful replacement left its recording behind")
        print("PASS: existing file preserved until replacement")

        let failedRecording = try recording()
        let missingTarget = directory.appendingPathComponent("missing-parent/new.mp4")
        do {
            try RecordingFileStorage.saveCompletedRecording(at: failedRecording, to: missingTarget)
            throw NSError(domain: "UnexpectedSaveSuccess", code: 1)
        } catch {
            try require((error as NSError).domain != "UnexpectedSaveSuccess", "Export to a missing parent succeeded")
        }
        try require(Data(contentsOf: failedRecording) == videoBytes, "Failed export lost the recording")
        try require(!manager.fileExists(atPath: missingTarget.path), "Failed export left a partial destination")
        print("PASS: failed new export retains recording")

        let lockedDirectory = directory.appendingPathComponent("locked")
        try manager.createDirectory(at: lockedDirectory, withIntermediateDirectories: false)
        let lockedTarget = lockedDirectory.appendingPathComponent("existing.mp4")
        try oldBytes.write(to: lockedTarget)
        let lockedRecording = try recording()
        try manager.setAttributes([.immutable: true], ofItemAtPath: lockedTarget.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: lockedTarget.path) }
        do {
            try RecordingFileStorage.saveCompletedRecording(at: lockedRecording, to: lockedTarget)
            throw NSError(domain: "UnexpectedSaveSuccess", code: 2)
        } catch {
            try require((error as NSError).domain != "UnexpectedSaveSuccess", "Export replaced a locked file")
        }
        try require(Data(contentsOf: lockedRecording) == videoBytes, "Failed replacement lost recording")
        try require(Data(contentsOf: lockedTarget) == oldBytes, "Failed replacement changed existing file")
        print("PASS: failed replacement retains both files")
        print("Recording file checks passed: \(directory.path)")
    }
}
