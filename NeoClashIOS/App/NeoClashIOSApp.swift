import NeoClashMobileCore
import SwiftUI

@main
struct NeoClashIOSApp: App {
    @State private var runtime: RuntimeStore
    @State private var coordinator: IOSAppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let runtime = RuntimeStore()
        let coordinator = IOSAppCoordinator(runtime: runtime)
        _runtime = State(initialValue: runtime)
        _coordinator = State(initialValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(runtime)
                .environment(coordinator)
                .task {
                    await coordinator.bootstrap()
                }
                .onChange(of: scenePhase) { _, phase in
                    Task { await coordinator.handleScenePhase(phase) }
                }
        }
    }
}
