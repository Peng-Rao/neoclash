import Foundation
import NeoClashMobileCore
import NetworkExtension
import Observation

@MainActor
@Observable
final class IOSAppCoordinator {
    var isBusy = false
    var tunnelStatus: NEVPNStatus = .invalid
    var tunnelConfigurationState: TunnelConfigurationState = .missing
    var lastTunnelError: String?

    private let runtime: RuntimeStore
    private let paths: ApplicationPaths
    private let profileStore: ProfileStore
    private let subscriptionService: SubscriptionService
    private let tunnelController: IOSTunnelController
    private let configBuilder = RuntimeConfigBuilder()
    private var didBootstrap = false
    private static let dailyTrafficKey = "neoclash.ios.dailyTraffic.v1"

    init(
        runtime: RuntimeStore,
        paths: ApplicationPaths = .defaultPaths(bundleIdentifier: "com.pengrao.NeoClash.iOS"),
        secretStore: SecretStore = KeychainStore()
    ) {
        self.runtime = runtime
        self.paths = paths
        self.profileStore = ProfileStore(rootDirectory: paths.profilesDirectory)
        self.subscriptionService = SubscriptionService(profileStore: profileStore, secretStore: secretStore)
        self.tunnelController = IOSTunnelController(paths: paths)
    }

    func bootstrap() async {
        guard !didBootstrap else {
            return
        }
        didBootstrap = true
        restoreDailyTraffic()
        await loadProfiles()
        await refreshTunnelState(reportsError: false)
    }

    func loadProfiles() async {
        do {
            let profiles = try await profileStore.load()
            runtime.applyProfiles(profiles)
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
            self.runtime.activeProfile = profile
            self.runtime.appendLog(level: .info, "Imported profile \(profile.name)")
        }
    }

    func addSubscription(name: String, urlString: String) async {
        await perform("Add subscription") {
            guard let url = URL(string: urlString),
                  let scheme = url.scheme,
                  ["http", "https"].contains(scheme.lowercased()) else {
                throw IOSCoordinatorError.invalidSubscriptionURL
            }

            let profile = try await self.subscriptionService.addSubscription(name: name, url: url)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.runtime.activeProfile = profile
            self.runtime.appendLog(level: .info, "Added subscription \(profile.name)")
        }
    }

    func updateSelectedSubscription() async {
        await perform("Update subscription") {
            guard let profile = self.runtime.activeProfile else {
                throw IOSCoordinatorError.noActiveProfile
            }
            guard profile.kind == .remoteSubscription else {
                throw IOSCoordinatorError.notSubscription
            }

            let updated = try await self.subscriptionService.update(profile: profile)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.runtime.activeProfile = updated
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
                self.runtime.activeProfile = profiles.first
            }
        }
    }

    func applyProfile(_ profile: ProxyProfile) {
        runtime.activeProfile = profile
        runtime.appendLog(level: .info, "Selected profile \(profile.name)")
    }

    func setMode(_ mode: RoutingMode) {
        guard runtime.mode != mode else {
            return
        }
        runtime.mode = mode
        runtime.appendLog(level: .info, "Set routing mode to \(mode.displayName)")
    }

    func setTUNEnabled(_ enabled: Bool) {
        runtime.isTUNEnabled = enabled
    }

    func prepareTunnel() async {
        await perform("Prepare VPN configuration") {
            let request = try await self.makeTunnelInstallRequest()
            try await self.tunnelController.installOrUpdate(configurationFileURL: request.configurationFileURL)
            self.lastTunnelError = nil
            self.tunnelConfigurationState = .installed
            self.runtime.appendLog(level: .info, "Prepared iOS packet tunnel configuration")
            await self.refreshTunnelState()
        }
    }

    func startTunnel() async {
        await perform("Start VPN") {
            let request = try await self.makeTunnelInstallRequest()
            try await self.tunnelController.installOrUpdate(configurationFileURL: request.configurationFileURL)
            self.tunnelConfigurationState = .installed
            self.runtime.markStarting()
            try await self.tunnelController.start()
            await self.refreshTunnelState()
        }
    }

    func stopTunnel() async {
        await perform("Stop VPN") {
            try await self.tunnelController.stop()
            await self.refreshTunnelState()
        }
    }

    func refreshTunnelState(reportsError: Bool = true) async {
        do {
            tunnelStatus = try await tunnelController.status()
            tunnelConfigurationState = try await tunnelController.configurationState()
            applyTunnelStatus(tunnelStatus)
        } catch {
            tunnelConfigurationState = .unavailable(error.localizedDescription)
            if reportsError {
                lastTunnelError = error.localizedDescription
            }
        }
    }

    private func makeTunnelInstallRequest() async throws -> TunnelInstallRequest {
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
            tun: TUNSettings(isEnabled: true, stack: "gvisor")
        )
        let originalYAML = try await runtimeProfileYAML()
        let runtimeYAML = try configBuilder.build(
            originalYAML: originalYAML,
            overrides: overrides,
            identity: identity
        )
        let profileName = runtime.activeProfile?.name ?? "Direct"
        return try tunnelController.writeConfiguration(
            runtimeYAML: runtimeYAML,
            profileName: profileName,
            ports: ports,
            identity: identity
        )
    }

    private func runtimeProfileYAML() async throws -> String {
        guard let profile = runtime.activeProfile else {
            runtime.appendLog(level: .info, "No profile selected; preparing direct-only iOS config.")
            return RuntimeConfigBuilder.directOnlyProfileYAML
        }
        return try await profileStore.yaml(for: profile)
    }

    private func applyTunnelStatus(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            runtime.status = .running(version: "Network Extension")
            runtime.coreVersion = "Network Extension"
        case .connecting, .reasserting:
            if runtime.status != .starting {
                runtime.status = .starting
            }
        case .disconnecting:
            runtime.status = .stopping
        case .disconnected, .invalid:
            if runtime.status != .stopped {
                runtime.markStopped()
            }
        @unknown default:
            runtime.status = .stopped
        }
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
            let message = "\(label) failed"
            lastTunnelError = error.localizedDescription
            runtime.reportError(message, diagnostics: error.localizedDescription)
            await refreshTunnelState(reportsError: false)
        }
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
            "Enter a valid http or https subscription URL."
        case .noActiveProfile:
            "Select a profile first."
        case .notSubscription:
            "The selected profile is a local YAML file, not a subscription."
        }
    }
}
