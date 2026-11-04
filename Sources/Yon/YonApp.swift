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

        Window("Add S3 drive", id: "s3") {
            S3Form().environmentObject(store)
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
        if store.drives.isEmpty {
            Text("No drives yet")
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
                    Image(systemName: store.busy.contains(d.name) ? "circle.dotted" : (on ? "circle.fill" : "circle"))
                }
            }
        }
        Divider()
        Menu("Add Drive") {
            Button("Google Drive") { Task { await store.add(type: "drive") } }
            Button("OneDrive") { Task { await store.add(type: "onedrive") } }
            Button("Dropbox") { Task { await store.add(type: "dropbox") } }
            Button("Box") { Task { await store.add(type: "box") } }
            Divider()
            Button("S3, R2, B2…") { openWindow(id: "s3"); NSApp.activate() }
        }
        if let e = store.error {
            Divider()
            Text(e).foregroundStyle(.secondary)
            Button("Dismiss") { store.error = nil }
        }
        Divider()
        Button("Settings…") { openSettings(); NSApp.activate() }
            .keyboardShortcut(",")
        Button("Quit Yon") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func confirmRemove(_ d: Drive) {
        let a = NSAlert()
        a.messageText = "Remove \(d.name) from Yon?"
        a.informativeText = "Your files stay in \(d.label). Only the sign-in on this Mac is removed."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Task { await store.remove(d) } }
    }
}

// Command Line Tools ship no SwiftUI macro plugin, so forms keep state in plain ObservableObjects instead of @State.
final class S3Fields: ObservableObject {
    @Published var name = ""
    @Published var provider = "Cloudflare"
    @Published var endpoint = ""
    @Published var key = ""
    @Published var secret = ""
}

struct S3Form: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var f = S3Fields()

    private let providers = ["Cloudflare", "AWS", "Backblaze", "Wasabi", "DigitalOcean", "Minio", "Other"]
    private var valid: Bool { !f.name.isEmpty && !f.key.isEmpty && !f.secret.isEmpty && !store.drives.contains { $0.name == f.name } }

    var body: some View {
        Form {
            TextField("Name", text: $f.name, prompt: Text("R2"))
            Picker("Provider", selection: $f.provider) {
                ForEach(providers, id: \.self) { Text($0) }
            }
            TextField("Endpoint", text: $f.endpoint, prompt: Text("https://<account>.r2.cloudflarestorage.com"))
            TextField("Access key", text: $f.key)
            SecureField("Secret key", text: $f.secret)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Drive") {
                    Task { await store.addS3(name: f.name, provider: f.provider, endpoint: f.endpoint, key: f.key, secret: f.secret) }
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
            Toggle("Open Yon at login", isOn: loginItem)
            LabeledContent("Drives mount at", value: Store.mountRoot.path)
            LabeledContent("rclone", value: Rclone.binary?.path ?? "Not installed")
            LabeledContent("Logs", value: Rclone.logDir.path)
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
