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

@MainActor
final class Store: ObservableObject {
    nonisolated static let mountRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Yon")

    @Published var drives: [Drive] = []
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
            let p = try Rclone.spawn([
                "nfsmount", "\(d.name):", d.mountPoint.path,
                "--volname", d.name,
                "--vfs-cache-mode", "writes",          // reads stream, writes stage locally then upload
                "--vfs-read-chunk-size", "16M",
                "--vfs-read-chunk-streams", "4",
                "--dir-cache-time", "30s",
                "--poll-interval", "30s",
                "--noappledouble",
            ], logName: d.name)
            processes[d.name] = p
            p.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.processes[d.name] = nil
                    self?.mounted.remove(d.name)
                }
            }
            // Wait until the mount shows up (rclone nfsmount takes ~1 s).
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                if isMounted(d.mountPoint) { break }
                if !p.isRunning { throw Rclone.Failure(message: "Could not mount \(d.name). See ~/Library/Logs/Yon/\(d.name).log") }
            }
            guard isMounted(d.mountPoint) else { throw Rclone.Failure(message: "\(d.name) did not mount in time.") }
            mounted.insert(d.name)
            autoMount.insert(d.name)
        } catch {
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
    }

    /// Mounts left over from a crash are stale NFS mounts; force them off before anything else.
    private func unmountStale() async {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: Self.mountRoot, includingPropertiesForKeys: nil) else { return }
        for url in entries where isMounted(url) { await unmountPath(url) }
    }

    private func unmountPath(_ url: URL) async {
        for args in [["umount", url.path], ["umount", "-f", url.path]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/umount")
            p.arguments = Array(args.dropFirst())
            try? p.run()
            p.waitUntilExit()
            if !isMounted(url) { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
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
        let base = Drive(name: "", type: type).label.replacingOccurrences(of: " ", with: "")
        var name = base
        var n = 2
        while drives.contains(where: { $0.name == name }) { name = "\(base)\(n)"; n += 1 }
        busy.insert(name)
        defer { busy.remove(name) }
        do {
            try await Rclone.run(["config", "create", name, type])
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
