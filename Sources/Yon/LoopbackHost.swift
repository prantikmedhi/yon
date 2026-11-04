import Darwin
import Foundation

/// The hostname drives are mounted from. Finder labels the sidebar location with it.
///
/// `yon.local` is published by this process over Bonjour, pointing at 127.0.0.1, so no admin rights are needed.
/// If the user has added `127.0.0.1 yon` to /etc/hosts, the plain `yon` resolves and is used instead.
enum LoopbackHost {
    static let bonjourName = "yon.local"
    static let shortName = "yon"

    private static var publisher: Process?

    /// `dns-sd -P` registers a proxy host record (yon.local → 127.0.0.1) for as long as it runs.
    /// The service it also advertises is harmless; the host record is what we need.
    static func publish() {
        guard publisher == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        p.arguments = ["-P", "Yon", "_nfs._tcp", ".", "2049", bonjourName, "127.0.0.1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        publisher = p
    }

    static func unpublish() {
        publisher?.terminate()
        publisher = nil
    }

    /// Prefer the bare alias when it resolves to loopback; otherwise the Bonjour name.
    static var mountName: String {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        defer { if let res { freeaddrinfo(res) } }
        guard getaddrinfo(shortName, nil, &hints, &res) == 0, let addr = res?.pointee.ai_addr else { return bonjourName }
        let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        return ip == inet_addr("127.0.0.1") ? shortName : bonjourName
    }

}
