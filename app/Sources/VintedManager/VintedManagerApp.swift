import AppKit
import SwiftUI

@main
struct VintedManagerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Vinted Manager") {
            ContentView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Library…") { store.createLibrary() }
                Button("Open Library…") { store.chooseRepository() }
                    .keyboardShortcut("o")
                Button("Reload") { store.reload() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            AgentSettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started via `swift run` (no .app bundle): show a Dock icon and focus the window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
