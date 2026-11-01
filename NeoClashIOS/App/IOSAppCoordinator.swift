import Foundation
import NeoClashMobileCore
import Observation
import SwiftUI

@MainActor
@Observable
final class IOSAppCoordinator {
    var isBusy = false
    var lastError: String?

    @ObservationIgnored let engine: any EngineHost

    private let runtime: RuntimeStore
    private let profileStore: ProfileStore
    private let subscriptionService: SubscriptionService
    private let configBuilder = RuntimeConfigBuilder()
    private var session: IOSCoreSession?
    private var didBootstrap = false
    private static let dailyTrafficKey = "neoclash.ios.dailyTraffic.v1"
    private static let activeProfileKey = "neoclash.ios.activeProfileID"
    private static let routingModeKey = "neoclash.ios.routingMode"

    init(
        runtime: RuntimeStore,
        paths: ApplicationPaths = .defaultPaths(bundleIdentifier: "com.pengrao.NeoClash.iOS"),
        secretStore: SecretStore = KeychainStore()
    ) {
        self.runtime = runtime
        self.profileStore = ProfileStore(rootDirectory: paths.profilesDirectory)
        self.subscriptionService = SubscriptionService(profileStore: profileStore, secretStore: secretStore)
        #if NEOCLASH_LOCAL_ENGINE
        self.engine = LocalEngineHost(paths: paths)
        #else
        self.engine = TunnelEngineHost()
        #endif
    }

    func bootstrap() async {
        guard !didBootstrap else {
            return
        }
        didBootstrap = true
        restoreRoutingMode()
        restoreDailyTraffic()
        engine.onUnexpectedStop = { [weak self] reason in
            self?.handleUnexpectedStop(reason)
        }
        await loadProfiles()
        await attachToRunningEngine()
    }

    func loadProfiles() async {
        do {
            let profiles = try await profileStore.load()
            runtime.applyProfiles(profiles)
            restoreActiveProfile()
        } catch {
            runtime.reportError("Failed to load profiles", diagnostics: error.localizedDescription)
        }
    }

    func restoreDailyTraffic() {
        guard let data = UserDefaults.standard.data(forKey: Self.dailyTrafficKey),
              let samples = try? JSONDecoder().decode([DailyTrafficSample].self, from: data) else {
            return
        }
        runtime.seedDailyTraffic(samples)
    }

    func persistDailyTraffic() {
        guard let data = try? JSONEncoder().encode(runtime.dailyTraffic) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.dailyTrafficKey)
    }

    func importLocalYAML(from url: URL) async {
        await perform("Import local profile") {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let profile = try await self.profileStore.importLocalYAML(name: name, yamlData: data)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.activate(profile)
            self.runtime.appendLog(level: .info, "Imported profile \(profile.name)")
        }
    }

    func addSubscription(name: String, urlString: String) async {
        await perform("Add subscription") {
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
                throw IOSCoordinatorError.invalidSubscriptionURL
            }

            let profile = try await self.subscriptionService.addSubscription(name: name, url: url)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.activate(profile)
            self.runtime.appendLog(level: .info, "Added subscription \(profile.name)")
        }
    }

    func updateSelectedSubscription() async {
        guard let profile = runtime.activeProfile else {
            runtime.reportError("Update subscription failed", diagnostics: IOSCoordinatorError.noActiveProfile.localizedDescription)
            return
        }
        await updateSubscription(profile)
    }

    func updateSubscription(_ profile: ProxyProfile) async {
        await perform("Update subscription") {
            guard profile.kind == .remoteSubscription else {
                throw IOSCoordinatorError.notSubscription
            }

            let wasActive = self.runtime.activeProfile?.id == profile.id
            let updated = try await self.subscriptionService.update(profile: profile)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            if wasActive {
                self.activate(updated)
            }
            self.runtime.appendLog(level: .info, "Updated subscription \(updated.name)")
        }
    }

    func deleteProfiles(at offsets: IndexSet) async {
        let ids = offsets.compactMap { runtime.profiles.indices.contains($0) ? runtime.profiles[$0].id : nil }
        guard !ids.isEmpty else {
            return
        }

        await perform("Delete profile") {
            for id in ids {
                try await self.profileStore.delete(profileID: id)
                try? await self.subscriptionService.removeStoredURL(profileID: id)
            }
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            if let active = self.runtime.activeProfile, ids.contains(active.id) {
                self.activate(profiles.first)
            }
        }
    }

    /// The core reads its profile at start, so changing it while running means restarting.
    func applyProfile(_ profile: ProxyProfile) async {
        guard runtime.activeProfile?.id != profile.id else {
            return
        }
        activate(profile)
        runtime.appendLog(level: .info, "Selected profile \(profile.name)")
        if runtime.status.isRunning {
            await stopEngine()
            await startEngine()
        }
    }

    private func activate(_ profile: ProxyProfile?) {
        runtime.activeProfile = profile
        UserDefaults.standard.set(profile?.id.uuidString, forKey: Self.activeProfileKey)
    }

    private func restoreActiveProfile() {
        guard let stored = UserDefaults.standard.string(forKey: Self.activeProfileKey),
              let profile = runtime.profiles.first(where: { $0.id.uuidString == stored }) else {
            return
        }
        runtime.activeProfile = profile
    }

    private func restoreRoutingMode() {
        guard let stored = UserDefaults.standard.string(forKey: Self.routingModeKey),
              let mode = RoutingMode(rawValue: stored) else {
            return
        }
        runtime.mode = mode
    }

    /// Takes effect immediately in the UI and is pushed to a running core; a refusal rolls it back.
    func setMode(_ mode: RoutingMode) async {
        let previous = runtime.mode
        guard previous != mode else {
            return
        }
        runtime.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.routingModeKey)
        guard let session else {
            return
        }
        do {
            try await session.updateMode(mode)
            runtime.appendLog(level: .info, "Set routing mode to \(mode.displayName)")
        } catch {
            runtime.mode = previous
            UserDefaults.standard.set(previous.rawValue, forKey: Self.routingModeKey)
            report("Set routing mode failed", error)
        }
    }

    func toggleEngine() async {
        if runtime.status.isRunning {
            await stopEngine()
        } else {
            await startEngine()
        }
    }

    func startEngine() async {
        await perform("Start") {
            self.lastError = nil
            self.runtime.markStarting()
            do {
                let endpoint = try await self.engine.start(try await self.makeStartRequest())
                try await self.attach(to: endpoint)
            } catch {
                // The core may be up even though it never became usable, as with a port clash.
                self.session = nil
                try? await self.engine.stop()
                self.runtime.markCrashed(error.localizedDescription)
                throw error
            }
        }
    }

    func stopEngine() async {
        await perform("Stop") {
            self.runtime.status = .stopping
            self.session?.stopStreams()
            self.session = nil
            self.persistDailyTraffic()
            defer { self.runtime.markStopped() }
            try await self.engine.stop()
        }
    }

    func selectProxy(group: String, proxy: String) async {
        guard let session else {
            return
        }
        do {
            try await session.selectProxy(group: group, proxy: proxy)
        } catch {
            report("Select proxy failed", error)
        }
    }

    func testDelays() async {
        await session?.testDelays()
    }

    func closeConnection(id: String) async {
        do {
            try await session?.closeConnection(id: id)
        } catch {
            report("Close connection failed", error)
        }
    }

    func closeAllConnections() async {
        do {
            try await session?.closeAllConnections()
        } catch {
            report("Close connections failed", error)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await resumeInForeground()
        case .background:
            session?.stopStreams()
            persistDailyTraffic()
        default:
            break
        }
    }

    /// iOS can reclaim an app's listening sockets while it is suspended, so a local core may come
    /// back deaf. A tunnel may also have been started or stopped from Settings in the meantime.
    private func resumeInForeground() async {
        guard let session else {
            await attachToRunningEngine()
            return
        }
        if await session.isReachable {
            session.startStreams()
            await session.reload()
        } else if engine.routesDeviceTraffic {
            handleUnexpectedStop(nil)
        } else {
            await stopEngine()
            await startEngine()
        }
    }

    private func attachToRunningEngine() async {
        guard session == nil, !isBusy, let endpoint = await engine.runningEndpoint() else {
            return
        }
        try? await attach(to: endpoint)
    }

    private func attach(to endpoint: ControllerEndpoint) async throws {
        let session = IOSCoreSession(runtime: runtime, endpoint: endpoint)
        let version = try await session.waitUntilReady()
        runtime.markRunning(version: version)
        self.session = session
        await session.reload()
        session.startStreams()
    }

    private func handleUnexpectedStop(_ reason: String?) {
        session?.stopStreams()
        session = nil
        persistDailyTraffic()
        if let reason {
            lastError = reason
            runtime.markCrashed(reason)
        } else {
            runtime.markStopped()
        }
    }

    private func makeStartRequest() async throws -> EngineStartRequest {
        let params = Self.storedStartParams()
        let ports = RuntimePorts.sanitizing(
            mixedPort: params.mixedPort,
            controllerPort: params.controllerPort
        )
        let identity = RuntimeIdentity()
        let overrides = RuntimeOverrides(
            ports: ports,
            mode: runtime.mode,
            logLevel: Self.preferredCoreLogLevel(),
            allowLAN: params.allowLAN,
            platform: engine.platform
        )
        let originalYAML = try await runtimeProfileYAML()
        let runtimeYAML = try configBuilder.build(
            originalYAML: originalYAML,
            overrides: overrides,
            identity: identity
        )
        return EngineStartRequest(
            runtimeYAML: runtimeYAML,
            profileName: runtime.activeProfile?.name ?? "Direct",
            ports: ports,
            identity: identity
        )
    }

    private func runtimeProfileYAML() async throws -> String {
        guard let profile = runtime.activeProfile else {
            runtime.appendLog(level: .info, "No profile selected; starting with a direct-only config.")
            return RuntimeConfigBuilder.directOnlyProfileYAML
        }
        return try await profileStore.yaml(for: profile)
    }

    private func perform(_ label: String, operation: @escaping () async throws -> Void) async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }

        do {
            try await operation()
        } catch {
            report("\(label) failed", error)
        }
    }

    private func report(_ message: String, _ error: Error) {
        lastError = error.localizedDescription
        runtime.reportError(message, diagnostics: error.localizedDescription)
    }

    private static func preferredCoreLogLevel() -> String {
        guard let stored = UserDefaults.standard.string(forKey: "coreLogLevel"),
              let level = CoreLogLevel(rawValue: stored) else {
            return CoreLogLevel.error.rawValue
        }
        return level.rawValue
    }

    private static func storedStartParams() -> (mixedPort: Int, controllerPort: Int, allowLAN: Bool) {
        let defaults = UserDefaults.standard
        let fallback = RuntimePorts()
        let mixedPort = defaults.object(forKey: "mixedPort") == nil ? fallback.mixedPort : defaults.integer(forKey: "mixedPort")
        let controllerPort = defaults.object(forKey: "controllerPort") == nil ? fallback.controllerPort : defaults.integer(forKey: "controllerPort")
        let ports = RuntimePorts.sanitizing(
            mixedPort: mixedPort,
            controllerPort: controllerPort,
            fallback: fallback
        )
        return (ports.mixedPort, ports.controllerPort, defaults.bool(forKey: "allowLan"))
    }
}

enum IOSCoordinatorError: Error, LocalizedError {
    case invalidSubscriptionURL
    case noActiveProfile
    case notSubscription

    var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            "Enter a valid HTTPS subscription URL."
        case .noActiveProfile:
            "Select a profile first."
        case .notSubscription:
            "The selected profile is a local YAML file, not a subscription."
        }
    }
}
