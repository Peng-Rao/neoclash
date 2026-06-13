import NeoClashCore
import SwiftUI

@main
struct NeoClashApp: App {
    @State private var runtime = RuntimeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(runtime)
        }
        .commands {
            ToolbarCommands()
        }

        MenuBarExtra("NeoClash", systemImage: runtime.status.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle") {
            MenuBarPanelView()
                .environment(runtime)
        }

        Settings {
            SettingsView()
                .environment(runtime)
        }
    }
}

