import AppKit
import ServiceManagement
import SwiftUI

/// First-run window. Shown once, when Yon starts with no drives. One screen, no pages:
/// what Yon does in three lines, then the one action that matters.
enum Onboarding {
    private static let key = "onboarded"
    private static var window: NSWindow?

    @MainActor
    static func showIfNeeded(store: Store) {
        let forced = CommandLine.arguments.contains("--welcome")   // `open Yon.app --args --welcome` for screenshots and tests
        guard forced || (!UserDefaults.standard.bool(forKey: key) && store.drives.isEmpty) else { return }
        show(store: store)
    }

    @MainActor
    static func show(store: Store) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = OnboardingView(store: store) { window?.close() }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Welcome to Yon"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
        UserDefaults.standard.set(true, forKey: key)
    }
}

struct OnboardingView: View {
    @ObservedObject var store: Store
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .padding(.bottom, 16)

            Text("Your cloud, as a drive in Finder.")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 12) {
                step("1", "Add a drive and sign in with the provider. The token stays on this Mac.")
                step("2", "It appears in Finder under yon.local and at ~/Yon.")
                step("3", "Files stream as you open them. Nothing fills your disk.")
            }
            .padding(.bottom, 24)

            HStack(spacing: 12) {
                Menu {
                    Button("Google Drive") { add("drive") }
                    Button("OneDrive") { add("onedrive") }
                    Button("Dropbox") { add("dropbox") }
                    Button("Box") { add("box") }
                } label: {
                    Text("Add Drive")
                } primaryAction: {
                    add("drive")
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Add Drive")

                Button("Later") { done() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Later")

                Spacer()
            }
            .padding(.bottom, 16)

            Toggle("Open Yon at login", isOn: loginItem)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .trailing)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(_ type: String) {
        done()
        Task { await store.add(type: type) }
    }

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
}
