import SwiftUI

@main
struct UniFiRebootManagerApp: App {
    @State private var manager = DeviceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .task {
                    if !manager.host.isEmpty && !manager.apiKey.isEmpty && !manager.siteID.isEmpty {
                        await manager.loadDevices()
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environment(manager)
        }
    }
}
