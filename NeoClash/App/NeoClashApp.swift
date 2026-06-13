import NeoClashCore
import SwiftUI

@main
struct NeoClashApp: App {
    @State private var runtime: RuntimeStore
    @State private var coordinator: AppCoordinator

    init() {
        let runtime = RuntimeStore()
        _runtime = State(initialValue: runtime)
        _coordinator = State(initialValue: AppCoordinator(runtime: runtime))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(runtime)
                .environment(coordinator)
                .task {
                    coordinator.loadProfiles()
                }
        }
        .commands {
            ToolbarCommands()
        }

        MenuBarExtra("NeoClash", systemImage: runtime.status.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle") {
            MenuBarPanelView()
                .environment(runtime)
                .environment(coordinator)
        }

        Settings {
            SettingsView()
                .environment(runtime)
                .environment(coordinator)
        }
    }
}
