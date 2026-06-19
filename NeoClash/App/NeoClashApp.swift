import NeoClashCore
import SwiftUI

@main
struct NeoClashApp: App {
    @State private var runtime: RuntimeStore
    @State private var coordinator: AppCoordinator
    @State private var menuBarController: MenuBarController

    init() {
        let runtime = RuntimeStore()
        let coordinator = AppCoordinator(runtime: runtime)
        _runtime = State(initialValue: runtime)
        _coordinator = State(initialValue: coordinator)
        _menuBarController = State(initialValue: MenuBarController(runtime: runtime, coordinator: coordinator))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(runtime)
                .environment(coordinator)
                .onAppear {
                    menuBarController.install()
                }
                .task {
                    coordinator.loadProfiles()
                    coordinator.restoreDailyTraffic()
                    coordinator.startNetworkStatusUpdates()
                }
        }
        .commands {
            ToolbarCommands()
        }

        Settings {
            SettingsView()
                .environment(runtime)
                .environment(coordinator)
        }
    }
}
