import AppKit
import ServiceManagement
import SwiftUI

@main
struct YonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
                .onAppear { delegate.store = store }
        } label: {
            Image(systemName: store.mounted.isEmpty ? "arrow.right" : "arrow.right.circle.fill")
                .accessibilityLabel("Yon")
        }

        // One window per provider type (the value), so Add Drive → Google Drive and Add Drive → S3 do not share one.
        WindowGroup("Add Drive", for: String.self) { type in
            AddForm(type: type.wrappedValue ?? "drive").environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

/// Unmount everything on quit so no stale NFS mounts are left behind.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.mounted.isEmpty else { return .terminateNow }
        Task { @MainActor in
            await store.unmountAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if store.drives.isEmpty && store.busy.isEmpty {
            Text("Add a drive to begin")
        }
        // A drive being signed in is not in `drives` yet; show where it will appear.
        ForEach(store.busy.subtracting(store.drives.map(\.name)).sorted(), id: \.self) { name in
            Label("Signing in to \(name)…", systemImage: "circle.dotted")
        }
        ForEach(store.drives) { d in
            let on = store.mounted.contains(d.name)
            Menu {
                Button(on ? "Eject" : "Mount") {
                    Task { on ? await store.unmount(d) : await store.mount(d) }
                }
                Button("Show in Finder") { store.reveal(d) }.disabled(!on)
                Divider()
                Button("Remove from Yon…") { confirmRemove(d) }
            } label: {
                Label {
                    Text(d.name)
                } icon: {
                    // Encrypted drives wear a lock; filled means mounted, as for the plain circle.
                    Image(systemName: store.busy.contains(d.name) ? "circle.dotted"
                          : d.encrypted ? (on ? "lock.circle.fill" : "lock.circle")
                          : (on ? "circle.fill" : "circle"))
                }
            }
        }
        Divider()
        Menu("Add Drive") {
            Button("Google Drive…") { add("drive") }
            Button("OneDrive…") { add("onedrive") }
            Button("Dropbox…") { add("dropbox") }
            Button("Box…") { add("box") }
            Divider()
            Button("S3, R2, B2…") { add("s3") }
        }
        if let e = store.error {
            Divider()
            Label(e, systemImage: "exclamationmark.triangle")
            Button("Dismiss") { store.error = nil }
        }
        Divider()
        Button("Settings…") { openSettings(); NSApp.activate() }
            .keyboardShortcut(",")
        Button("Quit Yon") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func add(_ type: String) {
        openWindow(value: type)
        NSApp.activate()
    }

    private func confirmRemove(_ d: Drive) {
        let a = NSAlert()
        a.messageText = "Remove \(d.name) from Yon?"
        a.informativeText = d.encrypted
            ? "Your files stay in \(d.label), encrypted. Only the sign-in and the password on this Mac are removed. Without the password they cannot be read again."
            : "Your files stay in \(d.label). Only the sign-in on this Mac is removed."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Task { await store.remove(d) } }
    }
}

// Command Line Tools ship no SwiftUI macro plugin, so forms keep state in plain ObservableObjects instead of @State.
final class AddFields: ObservableObject {
    @Published var name = ""
    @Published var provider = "Cloudflare"
    @Published var endpoint = ""
    @Published var key = ""
    @Published var secret = ""
    @Published var encrypt = false
    @Published var password = ""
    @Published var confirm = ""
}

/// Everything about a new drive that must be decided before its remote exists: S3 settings, and whether
/// it is encrypted. rclone cannot rename a remote, so the encryption choice cannot come after sign-in.
struct AddForm: View {
    let type: String
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var f = AddFields()

    private let providers = ["Cloudflare", "AWS", "Backblaze", "Wasabi", "DigitalOcean", "Minio", "Other"]
    private var s3: Bool { type == "s3" }
    private var label: String { Drive(name: "", type: type, raw: nil).label }
    private var taken: Bool { !f.name.isEmpty && !store.available(f.name) }
    private var passwordOK: Bool { !f.encrypt || (!f.password.isEmpty && f.password == f.confirm) }
    private var valid: Bool { passwordOK && (!s3 || (!f.name.isEmpty && !f.key.isEmpty && !f.secret.isEmpty && !taken)) }

    private var endpointHint: String {
        switch f.provider {
        case "Cloudflare": return "https://<account id>.r2.cloudflarestorage.com"
        case "Backblaze": return "https://s3.<region>.backblazeb2.com"
        case "Wasabi": return "https://s3.<region>.wasabisys.com"
        case "DigitalOcean": return "https://<region>.digitaloceanspaces.com"
        case "AWS": return "Leave empty for AWS"
        default: return "https://…"
        }
    }

    var body: some View {
        Form {
            if s3 {
                Section {
                    TextField("Name", text: $f.name, prompt: Text("Shown in Finder"))
                    if taken { Text("A drive named \(f.name) already exists.").font(.callout).foregroundStyle(.secondary) }
                    Picker("Provider", selection: $f.provider) {
                        ForEach(providers, id: \.self) { Text($0) }
                    }
                    TextField("Endpoint", text: $f.endpoint, prompt: Text(endpointHint))
                }
                Section {
                    TextField("Access key", text: $f.key)
                    SecureField("Secret key", text: $f.secret)
                } footer: {
                    Text("Keys are stored in Yon's rclone config on this Mac and sent only to the endpoint above.")
                }
            } else {
                Section {
                    LabeledContent("Provider", value: label)
                } footer: {
                    Text("Your browser opens to sign in with \(label). The token stays on this Mac.")
                }
            }
            Section {
                Toggle("Encrypt this drive", isOn: $f.encrypt)
                if f.encrypt {
                    SecureField("Password", text: $f.password)
                    SecureField("Confirm", text: $f.confirm)
                    if !f.confirm.isEmpty && f.password != f.confirm {
                        Text("Passwords do not match.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("File names and contents are encrypted on this Mac before upload. The password is the only key: it cannot be recovered or reset, and without it the files cannot be read.")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(s3 ? "Add Drive" : "Sign In") {
                    let password = f.encrypt ? f.password : nil
                    Task {
                        if s3 {
                            await store.addS3(name: f.name, provider: f.provider, endpoint: f.endpoint, key: f.key, secret: f.secret, password: password)
                        } else {
                            await store.add(type: type, password: password)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(.top, 8)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.bottom, 4)
        .navigationTitle("Add \(label)")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: Store

    private var loginItem: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                catch { store.error = error.localizedDescription }
                store.objectWillChange.send()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open Yon at login", isOn: loginItem)
            }
            Section {
                row("Drives", Store.mountRoot)
                row("Logs", Rclone.logDir)
                row("Config", Rclone.configFile.deletingLastPathComponent())
                LabeledContent("rclone", value: Rclone.binary?.path ?? "Not installed. Run: brew install rclone")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private func row(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
        }
    }
}
