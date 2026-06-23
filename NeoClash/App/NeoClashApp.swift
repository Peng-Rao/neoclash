import NeoClashCore
import AppKit
import SwiftUI

@main
struct NeoClashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runtime: RuntimeStore
    @State private var coordinator: AppCoordinator
    // Retain the AppKit status item owner for the whole app lifetime. If this object is released,
    // the menu bar item disappears even though the SwiftUI scene is still alive.
    @State private var menuBarController: MenuBarController

    init() {
        let runtime = RuntimeStore()
        let coordinator = AppCoordinator(runtime: runtime)
        _runtime = State(initialValue: runtime)
        _coordinator = State(initialValue: coordinator)
        _menuBarController = State(initialValue: MenuBarController(runtime: runtime, coordinator: coordinator))
        appDelegate.configure(runtime: runtime, coordinator: coordinator)
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
                    coordinator.performLaunchCleanup()
                    coordinator.loadProfiles()
                    coordinator.restoreDailyTraffic()
                    coordinator.startNetworkStatusUpdates()
                }
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: RuntimeStore?
    private var coordinator: AppCoordinator?
    private var isTerminating = false
    private var terminationSignalSource: DispatchSourceSignal?

    func configure(runtime: RuntimeStore, coordinator: AppCoordinator) {
        self.runtime = runtime
        self.coordinator = coordinator
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppTheme.stored.apply()
        installTerminationSignalHandler()
    }

    /// `pkill`, `kill`, and other SIGTERM senders bypass `applicationShouldTerminate`, leaving the
    /// core running and the system proxy set. Catch SIGTERM so we stop the core and restore the proxy
    /// before exiting. (SIGKILL/crashes can't be caught — `performLaunchCleanup` covers those.)
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let coordinator = self?.coordinator else {
                exit(0)
            }
            Task { @MainActor in
                await coordinator.stop()
                exit(0)
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        guard let runtime, runtime.status != .stopped, let coordinator else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            await coordinator.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
