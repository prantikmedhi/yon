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
    /// `stdin` is written to the process and closed, for commands that read their input from a pipe.
    @discardableResult
    static func run(_ args: [String], stdin: String? = nil) async throws -> String {
        guard let binary else { throw Failure(message: "rclone is not installed. Run: brew install rclone") }
        try? FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--config", configFile.path] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = Pipe()
        if stdin != nil { p.standardInput = input }
        try p.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: msg.split(separator: "\n").last.map(String.init) ?? "rclone failed")
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Every remote in the config with its settings, as `rclone config dump` reports them.
    static func dump() async throws -> [String: [String: String]] {
        let out = try await run(["config", "dump"])
        return try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: [String: String]] ?? [:]
    }

    /// Wrap `raw` in a crypt remote called `name`: standard rclone crypt, file names and directory names
    /// encrypted. The plain password reaches rclone over stdin and is never logged; rclone keeps it
    /// obscured in the config, which is the only place it lives. Lose the password, lose the files.
    static func createCrypt(name: String, raw: String, password: String) async throws {
        let obscured = try await run(["obscure", "-"], stdin: password).trimmingCharacters(in: .whitespacesAndNewlines)
        try await run(["config", "create", name, "crypt", "remote=\(raw):", "password=\(obscured)",
                       "filename_encryption=standard", "directory_name_encryption=true"])
    }

    /// Start a long-lived rclone process (nfsmount). Caller owns it.
    static func spawn(_ args: [String], environment: [String: String] = [:], logName: String) throws -> Process {
        guard let binary else { throw Failure(message: "rclone is not installed. Run: brew install rclone") }
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appendingPathComponent("\(logName).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--config", configFile.path] + args
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        return p
    }

    /// rclone's remote-control API of one serve process. The password exists only here and in that
    /// process's environment (RCLONE_RC_PASS), never on its command line where `ps` would show it.
    struct RC {
        static let user = "yon"
        let port: Int
        let pass: String

        func call<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 3
            req.setValue("Basic " + Data("\(Self.user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "rc \(path) failed") }
            return try JSONDecoder().decode(T.self, from: data)
        }

        /// Of a process's listening ports, the one that answers rc. The NFS port does not speak HTTP.
        static func find(among ports: [Int], pass: String) async -> RC? {
            await withTaskGroup(of: RC?.self) { group in
                for port in ports {
                    group.addTask {
                        let rc = RC(port: port, pass: pass)
                        return (try? await rc.call("rc/noop", as: [String: String].self)) == nil ? nil : rc
                    }
                }
                for await rc in group where rc != nil { group.cancelAll(); return rc }
                return nil
            }
        }

        func uploads() async throws -> UploadStatus {
            struct Core: Decodable { let transferring: [Upload]? }
            struct VFS: Decodable { struct Cache: Decodable { let uploadsQueued: Int }; let diskCache: Cache }
            let core: Core = try await call("core/stats")
            let vfs: VFS = try await call("vfs/stats")
            // Finder's AppleDouble sidecars (._name) ride along with every drop; the user did not add them.
            let files = (core.transferring ?? []).filter { !$0.name.split(separator: "/").last!.hasPrefix("._") }
            // Per-file ETAs only. The overall one is nonsense in the first seconds of a transfer.
            return UploadStatus(files: files, queued: vfs.diskCache.uploadsQueued, eta: files.compactMap(\.eta).max())
        }
    }
}
