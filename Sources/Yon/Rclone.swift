import Foundation

/// Thin wrapper around the rclone binary. Everything Yon does is an rclone command.
enum Rclone {
    static let binary: URL? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("rclone"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yon/rclone.conf")

    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Yon")

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Run rclone to completion. Returns stdout. Throws with stderr on non-zero exit.
    @discardableResult
    static func run(_ args: [String]) async throws -> String {
        guard let binary else { throw Failure(message: "rclone is not installed. Run: brew install rclone") }
        try? FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--config", configFile.path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: msg.split(separator: "\n").last.map(String.init) ?? "rclone failed")
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Start a long-lived rclone process (nfsmount). Caller owns it.
    static func spawn(_ args: [String], logName: String) throws -> Process {
        guard let binary else { throw Failure(message: "rclone is not installed. Run: brew install rclone") }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appendingPathComponent("\(logName).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--config", configFile.path] + args
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        return p
    }
}
