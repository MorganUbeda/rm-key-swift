import SwiftUI

@main
struct RMKeyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: "keyboard")
        }

        Window("Settings", id: "settings") {
            SettingsView(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 380, height: 300)

        Window("Capture", id: "capture") {
            CaptureViewContent(appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 260, height: 130)
    }
}

/// Configures the capture window to float on all spaces.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidUpdate(_ notification: Notification) {
        for window in NSApp.windows where window.title == "Capture" {
            if window.level != .floating {
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
            }
        }
    }
}
