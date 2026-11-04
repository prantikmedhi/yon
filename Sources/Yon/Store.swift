import AppKit
import Foundation

struct Drive: Identifiable, Equatable {
    let name: String       // rclone remote name, also the volume name
    let type: String       // rclone backend holding the bytes: drive, onedrive, dropbox, box, s3 …
    let raw: String?       // for an encrypted drive, the hidden provider remote the crypt remote wraps
    var id: String { name }
    var encrypted: Bool { raw != nil }

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

@MainActor
final class Store: ObservableObject {
    nonisolated static let mountRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Yon")

    @Published var drives: [Drive] = []
    /// Every remote name in the config, including the hidden raw remotes behind encrypted drives.
    @Published var names: Set<String> = []
    @Published var mounted: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var error: String?

    private var processes: [String: Process] = [:]
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
        Onboarding.showIfNeeded(store: self)
        for d in drives where autoMount.contains(d.name) { await mount(d) }
    }

    /// An encrypted drive is a crypt remote wrapping a provider remote. The crypt one is the drive;
    /// the remote it points at is hidden, whatever it is called.
    func refresh() async {
        do {
            let all = try await Rclone.dump()
            names = Set(all.keys)
            func target(_ cfg: [String: String]) -> String? {
                guard cfg["type"] == "crypt", let r = cfg["remote"] else { return nil }
                return String(r.prefix { $0 != ":" })
            }
            let hidden = Set(all.values.compactMap(target))
            drives = all.compactMap { name, cfg in
                guard !hidden.contains(name), let type = cfg["type"] else { return nil }
                guard let raw = target(cfg) else { return Drive(name: name, type: type, raw: nil) }
                return Drive(name: name, type: all[raw]?["type"] ?? type, raw: raw)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Mount

    func mount(_ d: Drive) async {
        error = nil
        guard !mounted.contains(d.name), !busy.contains(d.name) else { return }
        busy.insert(d.name)
        defer { busy.remove(d.name) }
        do {
            try FileManager.default.createDirectory(at: d.mountPoint, withIntermediateDirectories: true)
            // One loopback NFS server per drive, mounted by hostname so Finder shows "yon" as the location
            // instead of "localhost". Volume name in Finder is the mount folder's name.
            // Port 0: rclone picks a free port and reports it in its log, so there is no bind race.
            let p = try Rclone.spawn([
                "serve", "nfs", "\(d.name):",
                "--addr", "127.0.0.1:0",
                "--vfs-cache-mode", "writes",          // reads stream, writes stage locally then upload
                "--vfs-read-chunk-size", "16M",
                "--vfs-read-chunk-streams", "4",
                "--dir-cache-time", "30s",
                "--poll-interval", "30s",
            ], logName: d.name)
            processes[d.name] = p
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.processes[d.name] = nil
                    self?.mounted.remove(d.name)
                }
            }
            // Ask the kernel which loopback port this exact PID is listening on. Nothing else can answer for it.
            var port: Int?
            // Google Drive can take 30 s+ to refresh its token on a slow link before rclone binds, so wait up to 90 s.
            for _ in 0..<360 where port == nil {
                try await Task.sleep(for: .milliseconds(250))
                if !p.isRunning { throw Rclone.Failure(message: "Could not start \(d.name). See ~/Library/Logs/Yon/\(d.name).log") }
                port = Self.listeningPort(pid: p.processIdentifier)
            }
            guard let port else { throw Rclone.Failure(message: "\(d.name) did not start in time. Check your internet connection and try Mount again.") }

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
        } catch {
            // A failed attempt must not leave an rclone server running with nothing mounted on it.
            if !mounted.contains(d.name) {
                processes[d.name]?.terminate()
                processes[d.name] = nil
            }
            self.error = error.localizedDescription
        }
    }

    func unmount(_ d: Drive, forget: Bool = true) async {
        busy.insert(d.name)
        defer { busy.remove(d.name) }
        await unmountPath(d.mountPoint)
        processes[d.name]?.terminate()
        processes[d.name] = nil
        mounted.remove(d.name)
        if forget { autoMount.remove(d.name) }
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
        let attempts: [(String, [String])] = [
            ("/sbin/umount", [url.path]),
            ("/usr/sbin/diskutil", ["umount", "force", url.path]),
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
    private static func listeningPort(pid: Int32) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-F", "n"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").lazy
            .filter { $0.hasPrefix("n127.0.0.1:") }
            .compactMap { Int($0.split(separator: ":").last ?? "") }
            .first
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

    /// True when `name` can be used for a new drive: free, and so is the raw name an encrypted drive would need.
    func available(_ name: String) -> Bool {
        !name.isEmpty && !names.contains(name) && !names.contains(Self.rawName(name))
    }

    private static func rawName(_ name: String) -> String { "\(name) raw" }

    /// OAuth providers: rclone opens the browser, the user signs in, the token lands in Yon's own rclone.conf.
    /// With a password, the provider remote is created under a hidden name and a crypt remote with the
    /// drive's name wraps it; that is the one that gets mounted.
    func add(type: String, password: String? = nil) async {
        error = nil
        // The remote name is what Finder shows as the volume, so use the real product name.
        let base = Drive(name: "", type: type, raw: nil).label
        var name = base
        var n = 2
        while !available(name) { name = "\(base) \(n)"; n += 1 }
        // Own OAuth client per provider (Info.plist YonOAuthClients.<type>.id/secret). Without one,
        // rclone's shared client is used; Google is retiring that during 2026.
        var params: [String] = []
        if let clients = Bundle.main.object(forInfoDictionaryKey: "YonOAuthClients") as? [String: [String: String]],
           let c = clients[type], let id = c["id"], !id.isEmpty {
            params = ["client_id=\(id)", "client_secret=\(c["secret"] ?? "")"]
        }
        await create(name: name, type: type, params: params, password: password)
    }

    func addS3(name: String, provider: String, endpoint: String, key: String, secret: String, password: String? = nil) async {
        error = nil
        var params = ["provider=\(provider)", "access_key_id=\(key)", "secret_access_key=\(secret)"]
        if !endpoint.isEmpty { params.append("endpoint=\(endpoint)") }
        await create(name: name, type: "s3", params: params, password: password)
    }

    private func create(name: String, type: String, params: [String], password: String?) async {
        busy.insert(name)
        let raw = password == nil ? name : Self.rawName(name)
        do {
            try await Rclone.run(["config", "create", raw, type] + params)
            if let password {
                do { try await Rclone.createCrypt(name: name, raw: raw, password: password) }
                catch {
                    // Half an encrypted drive is worse than none: a plain drive the user did not ask for.
                    _ = try? await Rclone.run(["config", "delete", raw])
                    throw error
                }
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
        // mount() refuses a busy drive, so the sign-in must be over before the first mount.
        busy.remove(name)
        if let d = drives.first(where: { $0.name == name }) { await mount(d) }
    }

    /// Removes the remote, and for an encrypted drive the hidden provider remote behind it too.
    func remove(_ d: Drive) async {
        error = nil
        await unmount(d)
        do {
            try await Rclone.run(["config", "delete", d.name])
            if let raw = d.raw { try await Rclone.run(["config", "delete", raw]) }
            try? FileManager.default.removeItem(at: d.mountPoint)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func reveal(_ d: Drive) {
        NSWorkspace.shared.open(d.mountPoint)
    }
}
