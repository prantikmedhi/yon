import AppKit
import Foundation

struct Drive: Identifiable, Equatable {
    let name: String       // rclone remote name, also the volume name
    let type: String       // rclone backend: drive, onedrive, dropbox, box, s3 …
    var id: String { name }

    var mountPoint: URL { Store.mountRoot.appendingPathComponent(name) }
    var label: String {
        switch type {
        case "drive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        case "s3": return "S3"
        default: return type
        }
    }
}

/// One file rclone is uploading right now, as `core/stats` reports it.
struct Upload: Decodable, Equatable, Identifiable {
    let name: String       // path inside the drive
    let size: Int64?
    let bytes: Int64?
    let eta: Int?          // seconds, null until rclone has a speed for it
    var id: String { name }
    var percent: Int { size.map { $0 > 0 ? Int((bytes ?? 0) * 100 / $0) : 0 } ?? 0 }
}

struct UploadStatus: Equatable {
    var files: [Upload] = []
    var queued = 0         // written to the cache, waiting for its turn
    var eta: Int?          // seconds, nil when rclone cannot tell yet
    var active: Bool { !files.isEmpty || queued > 0 }
    var count: Int { files.count + queued }
}

@MainActor
final class Store: ObservableObject {
    nonisolated static let mountRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Yon")

    @Published var drives: [Drive] = []
    @Published var mounted: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var error: String?
    @Published var uploads: [String: UploadStatus] = [:]   // mounted drives only
    @Published var menuOpen = false

    var uploading: Bool { uploads.values.contains { $0.active } }

    private var processes: [String: Process] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    private let defaults = UserDefaults.standard

    /// Drives the user wants mounted whenever Yon runs.
    var autoMount: Set<String> {
        get { Set(defaults.stringArray(forKey: "autoMount") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "autoMount") }
    }

    init() {
        Task { await start() }
    }

    func start() async {
        LoopbackHost.publish()
        await unmountStale()
        await refresh()
        for d in drives where autoMount.contains(d.name) { await mount(d) }
    }

    func refresh() async {
        do {
            let out = try await Rclone.run(["listremotes", "--long"])
            drives = out.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { return nil }
                return Drive(name: parts[0], type: parts[1])
            }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Mount

    func mount(_ d: Drive) async {
        guard !mounted.contains(d.name), !busy.contains(d.name) else { return }
        busy.insert(d.name)
        defer { busy.remove(d.name) }
        do {
            try FileManager.default.createDirectory(at: d.mountPoint, withIntermediateDirectories: true)
            // One loopback NFS server per drive, mounted by hostname so Finder shows "yon" as the location
            // instead of "localhost". Volume name in Finder is the mount folder's name.
            // Port 0: rclone picks a free port and reports it in its log, so there is no bind race.
            // The rc API (upload stats) gets the same treatment; its password is random per launch.
            let pass = UUID().uuidString
            let p = try Rclone.spawn([
                "serve", "nfs", "\(d.name):",
                "--addr", "127.0.0.1:0",
                "--rc", "--rc-addr", "127.0.0.1:0", "--rc-user", Rclone.RC.user,
                "--vfs-cache-mode", "writes",          // reads stream, writes stage locally then upload
                "--vfs-read-chunk-size", "16M",
                "--vfs-read-chunk-streams", "4",
                "--dir-cache-time", "30s",
                "--poll-interval", "30s",
            ], environment: ["RCLONE_RC_PASS": pass], logName: d.name)
            processes[d.name] = p
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.processes[d.name] = nil
                    self?.mounted.remove(d.name)
                    self?.stopPolling(d.name)
                }
            }
            // Ask the kernel which loopback ports this exact PID is listening on: one NFS, one rc.
            // Nothing else can answer for it. Only the rc one answers HTTP, which tells them apart.
            // Up to 60 s: rclone restores pending uploads from its cache before the NFS server starts.
            var ports: [Int] = []
            for _ in 0..<240 where ports.count < 2 {
                try await Task.sleep(for: .milliseconds(250))
                if !p.isRunning { throw Rclone.Failure(message: "Could not start \(d.name). See ~/Library/Logs/Yon/\(d.name).log") }
                ports = Self.listeningPorts(pid: p.processIdentifier)
            }
            guard ports.count == 2, let rc = await Rclone.RC.find(among: ports, pass: pass),
                  let port = ports.first(where: { $0 != rc.port }) else {
                throw Rclone.Failure(message: "\(d.name) did not start in time.")
            }

            let m = Process()
            m.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
            m.arguments = ["-o", "port=\(port),mountport=\(port),tcp,nolocks,locallocks,noresvport,nfc",
                           "\(LoopbackHost.mountName):/", d.mountPoint.path]
            let err = Pipe()
            m.standardError = err
            m.standardOutput = FileHandle.nullDevice
            try m.run()
            m.waitUntilExit()
            guard m.terminationStatus == 0, isMounted(d.mountPoint) else {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw Rclone.Failure(message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // mount_nfs resolved the hostname itself. Anyone on the network can answer for a .local name,
            // so refuse the mount unless the kernel is actually talking to loopback.
            guard Self.isLoopbackMount(d.mountPoint) else {
                await unmountPath(d.mountPoint)
                throw Rclone.Failure(message: "Refused \(d.name): \(LoopbackHost.mountName) resolved to another computer. Something on this network is impersonating it.")
            }
            mounted.insert(d.name)
            autoMount.insert(d.name)
            poll(d.name, rc: rc)
        } catch {
            self.error = error.localizedDescription
            processes[d.name]?.terminate()   // no mount, no reason to keep the server
        }
    }

    func unmount(_ d: Drive, forget: Bool = true) async {
        busy.insert(d.name)
        defer { busy.remove(d.name) }
        await unmountPath(d.mountPoint)
        processes[d.name]?.terminate()
        processes[d.name] = nil
        mounted.remove(d.name)
        stopPolling(d.name)
        if forget { autoMount.remove(d.name) }
    }

    // MARK: Upload stats

    /// Every 2 s while the menu is open, every 10 s otherwise. Nothing here blocks the main actor:
    /// the rc calls are awaited and the result is only assigned when it changed.
    /// Each tick also notices when the mount went away under us (Finder eject, "Disconnect All" on the
    /// server-interrupted dialog): the server is stopped and the drive shows as ejected. autoMount is
    /// left alone, so the drive comes back on the next launch.
    private func poll(_ name: String, rc: Rclone.RC) {
        pollers[name]?.cancel()
        pollers[name] = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !isMounted(Self.mountRoot.appendingPathComponent(name)) {
                    processes[name]?.terminate()
                    processes[name] = nil
                    mounted.remove(name)
                    stopPolling(name)
                    return
                }
                if tick % 5 == 0 || menuOpen, let s = try? await rc.uploads(), s != uploads[name] {
                    uploads[name] = s
                }
                tick += 1
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopPolling(_ name: String) {
        pollers[name]?.cancel()
        pollers[name] = nil
        uploads[name] = nil
    }

    func unmountAll() async {
        for d in drives where mounted.contains(d.name) { await unmount(d, forget: false) }
        LoopbackHost.unpublish()
    }

    /// Mounts left over from a crash are stale NFS mounts; force them off before anything else.
    private func unmountStale() async {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: Self.mountRoot, includingPropertiesForKeys: nil) else { return }
        for url in entries where isMounted(url) { await unmountPath(url) }
    }

    private func unmountPath(_ url: URL) async {
        // diskutil first: it goes through DiskArbitration, which closes Finder windows cleanly and
        // avoids the "Server connections interrupted" dialog that a bare umount can leave behind.
        let attempts: [(String, [String])] = [
            ("/usr/sbin/diskutil", ["unmount", url.path]),
            ("/sbin/umount", [url.path]),
            ("/usr/sbin/diskutil", ["unmount", "force", url.path]),
        ]
        for (bin, args) in attempts {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if !isMounted(url) { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// `lsof -F n` prints one `n127.0.0.1:PORT` line per listening socket of the process.
    private static func listeningPorts(pid: Int32) -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "n"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n")
            .filter { $0.hasPrefix("n127.0.0.1:") }
            .compactMap { Int($0.split(separator: ":").last ?? "") }
    }

    /// `nfsstat -m` prints the address the mount is currently using, e.g. "/ @ yon.local (127.0.0.1)".
    private static func isLoopbackMount(_ url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nfsstat")
        p.arguments = ["-m", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let addrs: [String] = text.components(separatedBy: "Current location:").dropFirst().compactMap { part in
            guard let r = part.range(of: #"\(([0-9a-fA-F:.]+)\)"#, options: .regularExpression) else { return nil }
            return String(part[r].dropFirst().dropLast())
        }
        return !addrs.isEmpty && addrs.allSatisfy { $0 == "127.0.0.1" || $0 == "::1" }
    }

    private func isMounted(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        return withUnsafePointer(to: &st.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        } == url.path
    }

    // MARK: Add / remove

    /// OAuth providers: rclone opens the browser, the user signs in, the token lands in Yon's own rclone.conf.
    func add(type: String) async {
        // The remote name is what Finder shows as the volume, so use the real product name.
        let base = Drive(name: "", type: type).label
        var name = base
        var n = 2
        while drives.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            // Own OAuth client per provider (Info.plist YonOAuthClients.<type>.id/secret). Without one,
            // rclone's shared client is used; Google is retiring that during 2026.
            var args = ["config", "create", name, type]
            if let clients = Bundle.main.object(forInfoDictionaryKey: "YonOAuthClients") as? [String: [String: String]],
               let c = clients[type], let id = c["id"], !id.isEmpty {
                args += ["client_id=\(id)", "client_secret=\(c["secret"] ?? "")"]
            }
            try await Rclone.run(args)
            await refresh()
            if let d = drives.first(where: { $0.name == name }) { await mount(d) }
        } catch { self.error = error.localizedDescription }
    }

    func addS3(name: String, provider: String, endpoint: String, key: String, secret: String) async {
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            var args = ["config", "create", name, "s3", "provider=\(provider)", "access_key_id=\(key)", "secret_access_key=\(secret)"]
            if !endpoint.isEmpty { args.append("endpoint=\(endpoint)") }
            try await Rclone.run(args)
            await refresh()
            if let d = drives.first(where: { $0.name == name }) { await mount(d) }
        } catch { self.error = error.localizedDescription }
    }

    func remove(_ d: Drive) async {
        await unmount(d)
        do {
            try await Rclone.run(["config", "delete", d.name])
            try? FileManager.default.removeItem(at: d.mountPoint)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func reveal(_ d: Drive) {
        NSWorkspace.shared.open(d.mountPoint)
    }
}
