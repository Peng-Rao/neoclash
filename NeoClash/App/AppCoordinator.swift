import Foundation
import NeoClashCore
import Observation

private struct BundledRuntimeResource: Sendable {
    var sourceName: String
    var destinationNames: [String]
}

private struct ResolvedBundledRuntimeResource: Sendable {
    var sourceURL: URL
    var destinationNames: [String]
}

@MainActor
@Observable
final class AppCoordinator {
    var isBusy = false

    private let runtime: RuntimeStore
    private let paths: ApplicationPaths
    private let profileStore: ProfileStore
    private let subscriptionService: SubscriptionService
    private let processController: CoreProcessController
    private let privilegeManager: CorePrivilegeManager
    private let configBuilder: RuntimeConfigBuilder
    private let systemProxyController: SystemProxyController
    private let networkStatusProbe: NetworkStatusProbe
    private let coreResourceMonitor: CoreResourceMonitor
    private var apiClient: MihomoAPIClient?
    private var webSocketClient: MihomoWebSocketClient?
    private var streamTasks: [Task<Void, Never>] = []
    private var networkStatusTask: Task<Void, Never>?
    private var coreResourceTask: Task<Void, Never>?
    // Watches the running core for an unexpected exit or an unresponsive controller and recovers,
    // so a core that dies/hangs "after a while" (e.g. a gvisor TUN crash) no longer silently
    // blackholes traffic with the UI still showing "running".
    private var coreWatchdogTask: Task<Void, Never>?
    private var coreAutoRestartCount = 0
    private var lastCoreRestartAt: Date?
    private static let maxCoreAutoRestarts = 3
    // Reset the auto-restart budget once a recovered core has stayed healthy this long, so a rare
    // flap hours apart never permanently exhausts the budget while a tight crash loop still stops.
    private static let coreHealthyResetInterval: TimeInterval = 120
    private var runtimeBackend: RuntimeBackend = .stopped
    private var systemProxySnapshots: [String: ProxyServiceSnapshot]
    // Snapshots loaded from disk are untrusted until the live service still matches NeoClash's
    // exact loopback port. Current-session captures are verified at creation time.
    private var verifiedSystemProxySnapshotServices: Set<String> = []
    private var neoClashProxyEnabledServices: Set<String> = []
    private var inFlightStart: Task<Void, Never>?
    private var inFlightStop: Task<Void, Never>?
    private var configurationReconciliationTask: Task<Void, Never>?
    private var modeUpdateTask: Task<Void, Never>?
    private var modeUpdateGeneration = 0
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap = false
    private var desiredRunning = false
    private var runtimeConfigurationGeneration = 0
    private var appliedRuntimeConfigurationGeneration = -1
    private var previewEndpoints: [String: ProfileProxyPreview.Endpoint] = [:]
    private let tcpProber = TCPLatencyProber()
    private var activeMixedPort: Int?
    private var autoStartedByProxyMode = false
    // True while the OS proxy has been turned off because the active Wi-Fi network is on the
    // user's "disable proxy" list, even though the user still intends the proxy to be on.
    private var proxySuppressedForWiFi = false
    // The last start request is reused when toggling settings that require a core
    // restart, such as TUN. Keep this limited to user-provided launch parameters; the controller
    // secret and generated config must be recreated on every start.
    private var lastStartParams: (mixedPort: Int, controllerPort: Int, allowLAN: Bool)?
    private static let bundledRuntimeResources: [BundledRuntimeResource] = [
        BundledRuntimeResource(sourceName: "geoip.dat", destinationNames: ["geoip.dat"]),
        BundledRuntimeResource(sourceName: "geosite.dat", destinationNames: ["geosite.dat"]),
        BundledRuntimeResource(sourceName: "country.mmdb", destinationNames: ["country.mmdb", "Country.mmdb"])
    ]

    init(
        runtime: RuntimeStore,
        paths: ApplicationPaths = .defaultPaths(),
        secretStore: SecretStore = KeychainStore()
    ) {
        self.runtime = runtime
        self.paths = paths
        self.profileStore = ProfileStore(rootDirectory: paths.profilesDirectory)
        self.subscriptionService = SubscriptionService(profileStore: profileStore, secretStore: secretStore)
        self.processController = CoreProcessController()
        self.privilegeManager = CorePrivilegeManager()
        self.configBuilder = RuntimeConfigBuilder()
        self.systemProxyController = SystemProxyController()
        self.networkStatusProbe = NetworkStatusProbe()
        self.coreResourceMonitor = CoreResourceMonitor()
        self.systemProxySnapshots = Self.loadSystemProxySnapshots(from: paths.systemProxySnapshotsURL)
    }

    private static let dailyTrafficKey = "neoclash.dailyTraffic.v1"
    private static let hourlyTrafficKey = "neoclash.hourlyTraffic.v1"

    /// Restores the persisted rolling traffic totals so the Overview charts survive relaunches.
    func restoreDailyTraffic() {
        if let data = UserDefaults.standard.data(forKey: Self.dailyTrafficKey),
           let samples = try? JSONDecoder().decode([DailyTrafficSample].self, from: data) {
            runtime.seedDailyTraffic(samples)
        }
        if let data = UserDefaults.standard.data(forKey: Self.hourlyTrafficKey),
           let samples = try? JSONDecoder().decode([HourlyTrafficSample].self, from: data) {
            runtime.seedHourlyTraffic(samples)
        }
    }

    private func persistDailyTraffic() {
        if let data = try? JSONEncoder().encode(runtime.dailyTraffic) {
            UserDefaults.standard.set(data, forKey: Self.dailyTrafficKey)
        }
        if let data = try? JSONEncoder().encode(runtime.hourlyTraffic) {
            UserDefaults.standard.set(data, forKey: Self.hourlyTrafficKey)
        }
    }

    /// Performs process/proxy recovery and restores persisted state exactly once for the app
    /// lifetime. A WindowGroup can create ContentView more than once; attaching these launch-only
    /// operations directly to each view races core startup and can overwrite live traffic state.
    func bootstrap() async {
        if didBootstrap {
            return
        }
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { await self.performBootstrap() }
        bootstrapTask = task
        await task.value
        didBootstrap = true
        bootstrapTask = nil
    }

    private func performBootstrap() async {
        restoreDailyTraffic()
        await performLaunchCleanup()
        do {
            let profiles = try await profileStore.load()
            runtime.applyProfiles(profiles)
            await refreshProxyPreview()
        } catch {
            runtime.reportError("Failed to load profiles", diagnostics: error.localizedDescription)
        }
        startNetworkStatusUpdates()
    }

    /// Populates the Proxies UI from the active profile's YAML while the core is stopped, so
    /// nodes are browsable and TCP-testable without starting (or restarting) the core. Live
    /// data replaces the preview wholesale on the next start.
    func refreshProxyPreview() async {
        guard !runtime.status.isRunning else {
            return
        }
        guard let profile = runtime.activeProfile else {
            previewEndpoints = [:]
            runtime.updatePreviewProxies([])
            return
        }
        guard let yaml = try? await profileStore.yaml(for: profile) else {
            return
        }
        // Subscription YAML can run to megabytes; parse off the main actor.
        let preview = await Task.detached(priority: .utility) {
            ProfileProxyPreview.parse(yaml: yaml)
        }.value
        previewEndpoints = preview.endpoints
        runtime.updatePreviewProxies(preview.groups)
    }

    /// Cleans up leftovers from a previous crash or force-quit: orphaned core processes (which would
    /// hold the controller/mixed ports) and a system proxy left pointing at a now-dead local core
    /// (which would break connectivity). Safe to call once at launch before anything starts.
    private func performLaunchCleanup() async {
        let reaped = await processController.reapOrphans(runtimeDirectoryPath: paths.runtimeDirectory.path)
        if !reaped.isEmpty {
            runtime.appendLog(level: .warning, "Stopped \(reaped.count) leftover core process(es) from a previous run.")
            // SIGKILL is asynchronous; give the old listener a moment to release before deciding
            // whether a loopback system proxy still has a live owner.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        restorePersistedSystemProxySnapshots()
        await healOrphanedSystemProxy()
    }

    /// Clears a leftover loopback system proxy only when nothing is listening on its port — i.e. it
    /// is a dead proxy we left behind, not a live proxy belonging to another app. Runs off the main
    /// actor (networksetup spawns subprocesses) and reports the outcome.
    private func healOrphanedSystemProxy() async {
        let controller = systemProxyController
        let expectedMixedPort = Self.storedStartParams().mixedPort
        let outcome = await Task.detached(priority: .utility) { () -> ProxyHealOutcome in
            do {
                var affectedServices: [String] = []
                for service in try controller.availableServices() {
                    let snapshot = try controller.snapshot(service: service)
                    guard SystemProxyController.hasEnabledManagedEndpoint(snapshot, port: expectedMixedPort) else {
                        continue
                    }
                    affectedServices.append(service)
                }
                guard !affectedServices.isEmpty else {
                    return .noLoopbackProxy
                }
                guard PortChecker().isAvailable(host: "127.0.0.1", port: expectedMixedPort) else {
                    return .portInUse(expectedMixedPort)
                }
                var clearedServices: [String] = []
                for service in affectedServices {
                    if try controller.disableMatchingLoopback(service: service, port: expectedMixedPort) {
                        clearedServices.append(service)
                    }
                }
                return clearedServices.isEmpty ? .noLoopbackProxy : .cleared(clearedServices)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .cleared(let services):
            runtime.appendLog(
                level: .warning,
                "Cleared leftover system proxy settings on \(services.joined(separator: ", ")) from a previous run."
            )
        case .portInUse(let port):
            runtime.appendLog(level: .info, "Kept the existing system proxy; a service is still listening on port \(port).")
        case .failed(let message):
            runtime.appendLog(level: .warning, "System proxy cleanup skipped: \(message)")
        case .noLoopbackProxy:
            break
        }
    }

    func startNetworkStatusUpdates() {
        guard networkStatusTask == nil else {
            return
        }

        networkStatusTask = Task { [weak self] in
            await self?.refreshNetworkStatus()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else {
                    break
                }
                await self?.refreshNetworkStatus()
            }
        }
    }

    func refreshNetworkStatus() async {
        let snapshot = await networkStatusProbe.snapshot()
        runtime.update(networkStatus: snapshot)
        applyWiFiProxyPolicy(ssid: snapshot.wifiSSID)
    }

    /// Re-evaluates the per-Wi-Fi proxy rule against the last known network, e.g. after the user
    /// edits the disabled-network list in Settings.
    func applyWiFiPolicyNow() {
        applyWiFiProxyPolicy(ssid: runtime.networkStatus.wifiSSID)
    }

    /// Turns the macOS system proxy off while connected to a network the user listed under
    /// "Disable Proxy on Specific Wi-Fi", and turns it back on after leaving. The user's intent
    /// flag (`isSystemProxyEnabled`) is preserved throughout so the toggle still reads as on.
    private func applyWiFiProxyPolicy(ssid: String?) {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "wifiDisableEnabled")
        let blocked = Set((defaults.string(forKey: "wifiDisableSSIDs") ?? "")
            .split(separator: "\n").map(String.init))

        // Only manage the proxy while the user wants it on and the core is running. A disabled
        // Wi-Fi policy means "ensure enabled," which is important if the preference is turned off
        // while the proxy is currently suppressed.
        guard runtime.status.isRunning,
              runtime.isSystemProxyEnabled,
              activeMixedPort != nil else {
            proxySuppressedForWiFi = false
            return
        }

        do {
            let service = try systemProxyController.selectedService()
            let onBlockedNetwork = enabled && (ssid.map { blocked.contains($0) } ?? false)
            if onBlockedNetwork {
                // Do not disable an unrelated proxy on a newly selected service. Only suppress a
                // service NeoClash enabled during this run.
                guard neoClashProxyEnabledServices.contains(service) else {
                    proxySuppressedForWiFi = true
                    return
                }
                guard let port = activeMixedPort else { return }
                _ = try systemProxyController.disableMatchingLoopback(service: service, port: port)
                neoClashProxyEnabledServices.remove(service)
                proxySuppressedForWiFi = true
                runtime.appendLog(level: .info, "Disabled system proxy on Wi-Fi \(ssid ?? "network")")
            } else {
                guard !neoClashProxyEnabledServices.contains(service), let port = activeMixedPort else {
                    proxySuppressedForWiFi = false
                    return
                }
                try enableSystemProxy(port: port)
                if proxySuppressedForWiFi {
                    runtime.appendLog(level: .info, "Restored system proxy after leaving the network")
                }
                proxySuppressedForWiFi = false
            }
        } catch {
            runtime.appendLog(level: .warning, "Wi-Fi proxy rule skipped: \(error.localizedDescription)")
        }
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
            self.activateProfile(profile, configurationChanged: true)
            self.runtime.appendLog(level: .info, "Imported profile \(profile.name)")
            await self.refreshProxyPreview()
        }
    }

    func addSubscription(name: String, urlString: String) async {
        await perform("Add subscription") {
            guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else {
                throw AppCoordinatorError.invalidSubscriptionURL
            }
            let profile = try await self.subscriptionService.addSubscription(name: name, url: url)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.activateProfile(profile, configurationChanged: true)
            self.runtime.appendLog(level: .info, "Added subscription \(profile.name)")
        }
    }

    func updateSelectedSubscription() async {
        guard let profile = runtime.activeProfile else {
            runtime.reportError("Update subscription failed", diagnostics: AppCoordinatorError.noActiveProfile.localizedDescription)
            return
        }
        await updateSubscription(profile)
    }

    /// Refreshes the requested subscription without silently changing the active profile. If the
    /// refreshed profile is active, the running core is reconciled with its new YAML.
    func updateSubscription(_ profile: ProxyProfile) async {
        await perform("Update subscription") {
            guard profile.kind == .remoteSubscription else {
                throw AppCoordinatorError.notSubscription
            }
            let wasActive = self.runtime.activeProfile?.id == profile.id
            let updated = try await self.subscriptionService.update(profile: profile)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            if wasActive {
                self.runtime.activeProfile = updated
                self.requestRuntimeConfigurationRestart()
            }
            self.runtime.appendLog(level: .info, "Updated subscription \(updated.name)")
        }
    }

    /// Renames a profile and keeps the active selection pointed at the updated record.
    func renameProfile(_ profile: ProxyProfile, to name: String) async {
        await perform("Rename profile") {
            try await self.profileStore.rename(profileID: profile.id, to: name)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            if self.runtime.activeProfile?.id == profile.id {
                self.runtime.activeProfile = profiles.first { $0.id == profile.id }
            }
            self.runtime.appendLog(level: .info, "Renamed profile to \(name)")
        }
    }

    /// Deletes a profile and its on-disk files, falling back to the first remaining profile when
    /// the deleted one was active.
    func deleteProfile(_ profile: ProxyProfile) async {
        await perform("Delete profile") {
            let wasActive = self.runtime.activeProfile?.id == profile.id
            try await self.profileStore.delete(profileID: profile.id)
            if profile.kind == .remoteSubscription {
                do {
                    try await self.subscriptionService.removeStoredURL(profileID: profile.id)
                } catch {
                    self.runtime.appendLog(level: .warning, "Deleted the profile, but its stored subscription URL could not be removed: \(error.localizedDescription)")
                }
            }
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            if wasActive {
                self.requestRuntimeConfigurationRestart()
            }
            self.runtime.appendLog(level: .info, "Deleted profile \(profile.name)")
        }
    }

    /// Reads the raw YAML for a profile so it can be shown in the config editor.
    func configYAML(for profile: ProxyProfile) async -> String? {
        do {
            return try await profileStore.yaml(for: profile)
        } catch {
            runtime.reportError("Failed to read config", diagnostics: error.localizedDescription)
            return nil
        }
    }

    /// Validates and writes edited YAML back to a profile, keeping a last-known-good backup.
    /// Returns `true` when the save succeeded so the editor can dismiss.
    @discardableResult
    func saveConfigYAML(_ yaml: String, for profile: ProxyProfile) async -> Bool {
        do {
            let updated = try await profileStore.replaceProfileYAML(profileID: profile.id, yamlData: Data(yaml.utf8))
            let profiles = await profileStore.allProfiles()
            runtime.applyProfiles(profiles)
            if runtime.activeProfile?.id == updated.id {
                runtime.activeProfile = updated
                requestRuntimeConfigurationRestart()
                if !runtime.status.isRunning {
                    await refreshProxyPreview()
                }
            }
            runtime.appendLog(level: .info, "Saved config for \(updated.name)")
            return true
        } catch {
            runtime.reportError("Failed to save config", diagnostics: error.localizedDescription)
            return false
        }
    }

    func start(mixedPort: Int, controllerPort: Int, allowLAN: Bool = false) async {
        // A user-initiated start is a fresh intent: clear the watchdog's auto-restart budget so an
        // earlier crash loop doesn't suppress recovery for this run.
        desiredRunning = true
        coreAutoRestartCount = 0
        lastCoreRestartAt = nil
        await start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLAN, autoStartedByProxyMode: false)
    }

    private func start(
        mixedPort: Int,
        controllerPort: Int,
        allowLAN: Bool,
        autoStartedByProxyMode: Bool
    ) async {
        // Starting while launch recovery is inspecting a crash snapshot can overwrite the very
        // proxy state recovery is deciding whether it still owns.
        await bootstrap()
        guard desiredRunning else {
            return
        }
        switch runtime.status {
        case .stopped, .crashed:
            break
        case .starting:
            if let inFlightStart {
                await inFlightStart.value
            }
            return
        case .running:
            return
        case .stopping:
            if let inFlightStop {
                await inFlightStop.value
            }
            guard desiredRunning else { return }
        }

        // Capture restart inputs before any async work so a live TUN toggle can stop and start
        // the core with the same public ports and LAN binding.
        lastStartParams = (mixedPort, controllerPort, allowLAN)
        self.autoStartedByProxyMode = autoStartedByProxyMode
        let configurationGeneration = runtimeConfigurationGeneration
        runtime.markStarting()

        // Startup runs as a tracked task so stop() can await it: the unwind guard below only
        // helps if the process is still alive when the suspended startup resumes, and the
        // quit paths (Cmd+Q, SIGTERM) call exit right after stop() returns. Without this
        // handshake a quit during startup exits before the guard runs and orphans the core.
        let startup = Task {
            await self.performStartup(
                mixedPort: mixedPort,
                controllerPort: controllerPort,
                allowLAN: allowLAN,
                configurationGeneration: configurationGeneration
            )
        }
        inFlightStart = startup
        await startup.value
        inFlightStart = nil

        stopIfAutoStartedWithoutProxyModes()
        scheduleConfigurationReconciliationIfNeeded()
    }

    private func performStartup(
        mixedPort: Int,
        controllerPort: Int,
        allowLAN: Bool,
        configurationGeneration: Int
    ) async {
        await perform("Start runtime", markBusy: true, failureCrashes: true) {
            let identity = RuntimeIdentity()
            let logLevel = Self.preferredCoreLogLevel()
            let tunEnabled = self.runtime.isTUNEnabled
            let overrides = RuntimeOverrides(
                ports: RuntimePorts.sanitizing(mixedPort: mixedPort, controllerPort: controllerPort),
                mode: self.runtime.mode,
                logLevel: logLevel,
                allowLAN: allowLAN,
                tun: Self.storedTUNSettings(isEnabled: tunEnabled)
            )

            let originalYAML = try await self.runtimeProfileYAML()
            let runtimeYAML = try self.configBuilder.build(originalYAML: originalYAML, overrides: overrides, identity: identity)
            try await self.prepareRuntimeFiles(runtimeYAML: runtimeYAML)

            // TUN needs the core to run as root (utun device + routing table). Stage a copy of the
            // core outside the app bundle and make it setuid-root, then launch it as a normal child
            // process so the controller can manage its lifecycle as usual.
            let coreURL: URL
            if tunEnabled {
                coreURL = try self.stageTUNCore()
                if !self.privilegeManager.hasRootPrivileges(coreURL: coreURL) {
                    self.runtime.appendLog(level: .info, "Enabling TUN mode — administrator authorization required.")
                }
                try self.privilegeManager.ensureTUNPrivileges(coreURL: coreURL)
            } else {
                coreURL = self.bundledCoreURL
            }

            let request = CoreStartRequest(
                coreURL: coreURL,
                runtimeDirectory: self.paths.runtimeDirectory,
                runtimeConfigURL: self.paths.runtimeConfigURL,
                manifest: self.bundledCoreManifest,
                ports: overrides.ports,
                secret: identity.secret
            )

            // A stop that landed while config prep or privilege staging was suspended has
            // already moved the status out of `.starting` — skip launching entirely rather
            // than launch a core just to unwind it below.
            guard self.desiredRunning, self.runtime.status == .starting else {
                return
            }

            let result = try await self.processController.start(request)

            // A stop or app-quit issued while startup was suspended (config prep, privilege
            // staging, and the core launch itself are all `await` points) moves the status out of
            // `.starting`. Because `runtimeBackend` was still `.stopped` at that instant, stop()
            // couldn't tear the core down — so we unwind the process we just launched instead of
            // leaving it orphaned (root + TUN in the worst case) with the system proxy still
            // pointed at it after the app has exited.
            guard self.desiredRunning, self.runtime.status == .starting else {
                await self.processController.stop()
                self.runtimeBackend = .stopped
                return
            }

            self.runtimeBackend = .real

            let apiClient = MihomoAPIClient(
                host: overrides.ports.controllerHost,
                port: overrides.ports.controllerPort,
                secret: identity.secret
            )
            self.apiClient = apiClient
            self.activeMixedPort = overrides.ports.mixedPort
            if self.runtime.isSystemProxyEnabled {
                do {
                    try self.enableSystemProxy(port: overrides.ports.mixedPort)
                } catch {
                    self.runtime.isSystemProxyEnabled = false
                    self.runtime.reportError("System proxy setup failed", diagnostics: error.localizedDescription)
                    self.runtime.appendLog(level: .warning, "Mihomo is running, but macOS system proxy setup failed.")
                }
            }
            self.runtime.markRunning(version: result.version)
            self.appliedRuntimeConfigurationGeneration = configurationGeneration
            self.applyWiFiProxyPolicy(ssid: self.runtime.networkStatus.wifiSSID)
            await self.reloadRuntimeData()
            self.startCoreResourceUpdates(pid: result.processIdentifier)
            self.startStreams(host: overrides.ports.controllerHost, port: overrides.ports.controllerPort, secret: identity.secret)
            self.startCoreWatchdog()
        }
    }

    func stop() async {
        desiredRunning = false
        coreAutoRestartCount = 0
        lastCoreRestartAt = nil
        // A quit/SIGTERM can arrive before the first WindowGroup task runs. Verify any disk-loaded
        // recovery snapshot before stopRuntime is allowed to restore it.
        await bootstrap()
        await stopRuntime()
        autoStartedByProxyMode = false
    }

    /// Serializes teardown so two stop→start workflows cannot interleave and let an older stop
    /// clobber a newer startup. Public stop changes user intent; internal restarts call this helper
    /// while preserving that intent.
    private func stopRuntime() async {
        if let inFlightStop {
            await inFlightStop.value
            return
        }

        if runtime.status == .stopped, runtimeBackend == .stopped {
            restoreSystemProxyIfNeeded()
            return
        }

        runtime.status = .stopping
        let teardown = Task { await self.performRuntimeTeardown() }
        inFlightStop = teardown
        await teardown.value
        inFlightStop = nil
    }

    private func performRuntimeTeardown() async {
        // Let an in-flight startup reach its unwind guard before tearing anything down: the
        // status change above is what trips the guard, and awaiting here keeps quit paths
        // from exiting the process while the just-launched core is still unaccounted for.
        if let startup = inFlightStart {
            await startup.value
        }
        stopCoreWatchdog()
        if let modeTask = modeUpdateTask {
            modeTask.cancel()
            await modeTask.value
            modeUpdateTask = nil
        }
        restoreSystemProxyIfNeeded()
        stopStreams()
        stopCoreResourceUpdates()
        apiClient = nil
        if runtimeBackend == .real {
            await processController.stop()
        }
        runtimeBackend = .stopped
        appliedRuntimeConfigurationGeneration = -1
        activeMixedPort = nil
        proxySuppressedForWiFi = false
        runtime.markStopped()
        await refreshProxyPreview()
    }

    var hasPendingSystemProxyRestore: Bool {
        !systemProxySnapshots.isEmpty
    }

    func reloadRuntimeData() async {
        guard let apiClient else {
            runtime.reportError("Runtime data refresh failed", diagnostics: "Mihomo API client is not available.")
            return
        }

        async let proxies = apiClient.proxies()
        async let connections = apiClient.connections()
        async let rules = apiClient.rules()

        do {
            runtime.update(proxies: try await proxies)
        } catch {
            runtime.appendLog(level: .warning, "Failed to refresh proxies: \(error.localizedDescription)")
        }

        do {
            runtime.update(connections: try await connections)
        } catch {
            runtime.appendLog(level: .warning, "Failed to refresh connections: \(error.localizedDescription)")
        }

        do {
            runtime.update(rules: try await rules)
        } catch {
            runtime.appendLog(level: .warning, "Failed to refresh rules: \(error.localizedDescription)")
        }
    }

    func selectProxy(group: String, proxy: String, closeConnections: Bool) async {
        await perform("Select proxy") {
            guard let apiClient = self.apiClient else {
                throw AppCoordinatorError.runtimeNotRunning
            }
            try await apiClient.selectProxy(group: group, proxy: proxy)
            if closeConnections {
                try await apiClient.closeAllConnections()
            }
            await self.reloadRuntimeData()
        }
    }

    /// Updates the outbound routing mode and pushes it to the running core via the controller API.
    func setMode(_ mode: RoutingMode) {
        guard runtime.mode != mode else {
            return
        }
        runtime.mode = mode
        modeUpdateGeneration &+= 1
        guard runtime.status.isRunning, apiClient != nil else {
            if runtime.status != .stopped {
                requestRuntimeConfigurationRestart()
            }
            return
        }

        scheduleModeUpdateIfNeeded()
    }

    private func scheduleModeUpdateIfNeeded() {
        guard modeUpdateTask == nil, runtime.status.isRunning, apiClient != nil else {
            return
        }
        modeUpdateTask = Task { await self.reconcileModeUpdates() }
    }

    /// Sends mode changes in order and keeps applying the newest generation. Independent Tasks can
    /// finish PATCH requests out of order (Rule → Global → Direct), leaving the UI and core on
    /// different modes even though every request succeeded.
    private func reconcileModeUpdates() async {
        defer { modeUpdateTask = nil }

        while !Task.isCancelled, runtime.status.isRunning, let client = apiClient {
            let generation = modeUpdateGeneration
            let mode = runtime.mode
            do {
                try await client.updateMode(mode)
            } catch {
                guard !Task.isCancelled, generation == modeUpdateGeneration,
                      runtime.status.isRunning, apiClient === client else {
                    continue
                }
                runtime.appendLog(level: .warning, "Failed to switch mode: \(error.localizedDescription)")
                // The UI already reflects the requested mode. Rebuild the runtime if the live API
                // update failed so UI and routing cannot remain permanently divergent.
                requestRuntimeConfigurationRestart()
                return
            }

            guard !Task.isCancelled, runtime.status.isRunning, apiClient === client else {
                return
            }
            guard generation == modeUpdateGeneration else {
                continue
            }
            runtime.appendLog(level: .info, "Switched outbound mode to \(mode.displayName)")
            await reloadRuntimeData()
            if generation == modeUpdateGeneration {
                return
            }
        }
    }

    /// Toggles the macOS system proxy, starting the core first when the user enables proxy mode
    /// from a stopped state.
    func setSystemProxyEnabled(_ enabled: Bool) {
        guard runtime.isSystemProxyEnabled != enabled else {
            return
        }
        runtime.isSystemProxyEnabled = enabled
        guard runtime.status.isRunning else {
            if enabled {
                startUsingStoredSettings()
            } else {
                restoreSystemProxyIfNeeded()
            }
            return
        }
        if enabled {
            guard let port = activeMixedPort else {
                return
            }
            do {
                try enableSystemProxy(port: port)
                applyWiFiProxyPolicy(ssid: runtime.networkStatus.wifiSSID)
            } catch {
                runtime.reportError("System proxy setup failed", diagnostics: error.localizedDescription)
                runtime.isSystemProxyEnabled = false
            }
        } else {
            restoreSystemProxyIfNeeded()
            stopIfAutoStartedWithoutProxyModes()
        }
    }

    /// Toggles TUN mode. Because TUN is baked into the runtime config and needs elevated
    /// privileges, enabling from a stopped state starts the core and changing a running core
    /// restarts it.
    func setTUNEnabled(_ enabled: Bool) {
        guard runtime.isTUNEnabled != enabled else {
            return
        }
        runtime.isTUNEnabled = enabled
        requestRuntimeConfigurationRestart()
        if !enabled, autoStartedByProxyMode, !runtime.isSystemProxyEnabled {
            Task { await self.stop() }
            return
        }
        if enabled, (runtime.status == .stopped || runtime.status.isCrashed) {
            startUsingStoredSettings()
        }
    }

    /// Activates a profile and, when the core is already running, restarts it with the new
    /// config — the active-profile YAML is only read at startup, so without the restart every
    /// surface would report the new profile while the core keeps routing with the old one.
    func applyProfile(_ profile: ProxyProfile) {
        activateProfile(profile, configurationChanged: false)
    }

    func restartForTUNSettingsChange() {
        guard runtime.isTUNEnabled else {
            return
        }
        requestRuntimeConfigurationRestart()
    }

    func restartForPortSettingsChange() {
        // Port fields persist immediately. Keep restart inputs aligned with the newest values so
        // reconciliation cannot relaunch with a stale controller or mixed port.
        lastStartParams = Self.storedStartParams()
        guard desiredRunning else {
            return
        }
        requestRuntimeConfigurationRestart()
    }

    private func activateProfile(_ profile: ProxyProfile, configurationChanged: Bool) {
        let selectionChanged = runtime.activeProfile?.id != profile.id
        runtime.activeProfile = profile
        guard selectionChanged || configurationChanged else {
            return
        }

        runtime.appendLog(level: .info, "Selected profile \(profile.name)")
        requestRuntimeConfigurationRestart()
        if runtime.status == .stopped || runtime.status.isCrashed {
            Task { await self.refreshProxyPreview() }
        }
    }

    private func requestRuntimeConfigurationRestart() {
        runtimeConfigurationGeneration &+= 1
        scheduleConfigurationReconciliationIfNeeded()
    }

    private func scheduleConfigurationReconciliationIfNeeded() {
        guard desiredRunning,
              appliedRuntimeConfigurationGeneration != runtimeConfigurationGeneration,
              configurationReconciliationTask == nil else {
            return
        }

        configurationReconciliationTask = Task { await self.reconcileRuntimeConfiguration() }
    }

    private func reconcileRuntimeConfiguration() async {
        defer { configurationReconciliationTask = nil }

        while desiredRunning,
              appliedRuntimeConfigurationGeneration != runtimeConfigurationGeneration {
            if let inFlightStart, runtime.status == .starting {
                await inFlightStart.value
            }
            if let inFlightStop, runtime.status == .stopping {
                await inFlightStop.value
            }

            guard desiredRunning, runtime.status.isRunning, lastStartParams != nil else {
                return
            }

            let shouldRemainAutoStarted = autoStartedByProxyMode
            runtime.appendLog(level: .info, "Runtime settings changed — restarting core")
            await stopRuntime()
            // Settings can change again while teardown is suspended. Relaunch with the newest
            // inputs so the generation applied by start() actually describes these parameters.
            guard desiredRunning, let params = lastStartParams else { return }
            await start(
                mixedPort: params.mixedPort,
                controllerPort: params.controllerPort,
                allowLAN: params.allowLAN,
                autoStartedByProxyMode: shouldRemainAutoStarted
            )

            guard runtime.status.isRunning else {
                return
            }
        }
    }

    private func startUsingStoredSettings() {
        switch runtime.status {
        case .stopped, .crashed:
            let params = Self.storedStartParams()
            desiredRunning = true
            Task {
                await self.start(
                    mixedPort: params.mixedPort,
                    controllerPort: params.controllerPort,
                    allowLAN: params.allowLAN,
                    autoStartedByProxyMode: true
                )
            }
        case .starting, .running, .stopping:
            return
        }
    }

    private func stopIfAutoStartedWithoutProxyModes() {
        guard autoStartedByProxyMode,
              runtime.status.isRunning,
              !runtime.isSystemProxyEnabled,
              !runtime.isTUNEnabled else {
            return
        }
        Task {
            await self.stop()
        }
    }

    func testDelays() async {
        guard !runtime.isTestingDelays else {
            return
        }

        if apiClient == nil, runtime.isProxyPreview {
            await testPreviewDelays()
            return
        }

        guard let apiClient else {
            runtime.reportError("Delay test failed", diagnostics: "Mihomo API client is not available.")
            return
        }

        // Test each unique node once (a node can appear in several groups) and cap concurrency so a
        // large subscription doesn't fire hundreds of simultaneous requests at the controller.
        var seenNodeNames: Set<String> = []
        let nodeNames = runtime.proxies
            .flatMap { $0.nodes.map(\.name) }
            .filter { seenNodeNames.insert($0).inserted }
        guard !nodeNames.isEmpty else { return }

        runtime.beginDelayTest(nodeNames: nodeNames)
        defer {
            runtime.finishDelayTest()
        }

        let maxConcurrent = min(8, nodeNames.count)

        await withTaskGroup(of: (String, Int?).self) { group in
            var next = 0
            while next < maxConcurrent {
                let name = nodeNames[next]
                group.addTask { (name, await apiClient.testDelay(name: name)) }
                next += 1
            }
            while let result = await group.next() {
                runtime.recordDelayTestResult(name: result.0, delay: result.1)
                if next < nodeNames.count {
                    let name = nodeNames[next]
                    group.addTask { (name, await apiClient.testDelay(name: name)) }
                    next += 1
                }
            }
        }
    }

    /// Offline latency: TCP connect time to each node's server endpoint. This measures
    /// reachability rather than a proxied round-trip, but it ranks nodes without the core.
    private func testPreviewDelays() async {
        var seenNodeNames: Set<String> = []
        let nodeNames = runtime.proxies
            .flatMap { $0.nodes.map(\.name) }
            .filter { previewEndpoints[$0] != nil && seenNodeNames.insert($0).inserted }
        guard !nodeNames.isEmpty else {
            return
        }

        runtime.beginDelayTest(nodeNames: nodeNames)
        defer {
            runtime.finishDelayTest()
        }

        let endpoints = previewEndpoints
        let prober = tcpProber
        let maxConcurrent = min(8, nodeNames.count)

        await withTaskGroup(of: (String, Int?).self) { group in
            func probe(_ name: String) {
                guard let endpoint = endpoints[name] else {
                    return
                }
                group.addTask { (name, await prober.latencyMS(host: endpoint.host, port: endpoint.port)) }
            }
            var next = 0
            while next < maxConcurrent {
                probe(nodeNames[next])
                next += 1
            }
            while let result = await group.next() {
                runtime.recordDelayTestResult(name: result.0, delay: result.1)
                if next < nodeNames.count {
                    probe(nodeNames[next])
                    next += 1
                }
            }
        }
    }

    func closeAllConnections() async {
        await perform("Close connections") {
            guard let apiClient = self.apiClient else {
                throw AppCoordinatorError.runtimeNotRunning
            }
            try await apiClient.closeAllConnections()
            self.runtime.update(connections: [])
        }
    }

    func closeConnections(ids: [String]) async {
        await perform("Close connections") {
            guard let apiClient = self.apiClient else {
                throw AppCoordinatorError.runtimeNotRunning
            }
            for id in ids {
                try await apiClient.closeConnection(id: id)
            }
            let closed = Set(ids)
            self.runtime.update(connections: self.runtime.connections.filter { !closed.contains($0.id) })
        }
    }

    private func runtimeProfileYAML() async throws -> String {
        guard let profile = runtime.activeProfile else {
            runtime.appendLog(level: .info, "No profile selected; starting real Mihomo with a direct-only config.")
            return RuntimeConfigBuilder.directOnlyProfileYAML
        }
        return try await profileStore.yaml(for: profile)
    }

    private func prepareRuntimeFiles(runtimeYAML: String) async throws {
        let runtimeDirectory = paths.runtimeDirectory
        let runtimeConfigURL = paths.runtimeConfigURL
        let bundledRuntimeResources = try bundledRuntimeResourceCopies()
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            for resource in bundledRuntimeResources {
                for destinationName in resource.destinationNames {
                    let destinationURL = runtimeDirectory.appendingPathComponent(destinationName)
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: resource.sourceURL, to: destinationURL)
                }
            }
            try AtomicFileWriter.write(runtimeYAML, to: runtimeConfigURL)
        }.value
    }

    private var bundledCoreURL: URL {
        if let coreURL = bundledResourceFileURL(named: "mihomo", directory: "Core") {
            return coreURL
        }
        return paths.coresDirectory.appendingPathComponent("mihomo")
    }

    /// Stages a copy of the core under Application Support so it can be made setuid-root for TUN
    /// without modifying (and invalidating the signature of) the app bundle. The copy persists
    /// across rebuilds; it is refreshed only when the bundled core changes.
    private func stageTUNCore() throws -> URL {
        let fileManager = FileManager.default
        let source = bundledCoreURL
        let destination = paths.coresDirectory.appendingPathComponent("mihomo")

        if source.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }

        if fileManager.fileExists(atPath: destination.path) {
            // Reuse the staged copy only while it still matches the bundled core. A previously
            // granted setuid-root copy is reused as-is so TUN does not re-prompt every launch,
            // but if the bundled core changed (an app/core upgrade) the stale copy would fail
            // checksum validation at launch — so it must be re-staged. Re-copying drops the
            // setuid bit, and the caller then re-requests privileges for the fresh binary.
            let sameContents = (try? CoreBinaryValidator.sha256(of: destination))
                == (try? CoreBinaryValidator.sha256(of: source))
            if sameContents {
                return destination
            }
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: paths.coresDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    private var bundledCoreManifest: CoreManifest? {
        guard let manifestURL = bundledResourceFileURL(named: "mihomo-manifest.json", directory: "Core"),
              let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CoreManifest.self, from: data)
    }

    private func bundledRuntimeResourceCopies() throws -> [ResolvedBundledRuntimeResource] {
        try Self.bundledRuntimeResources.map { resource in
            let candidates = bundledResourceFileCandidates(named: resource.sourceName, directory: "Geo")
            guard let sourceURL = existingFileURL(in: candidates) else {
                throw AppCoordinatorError.missingBundledResource(resource.sourceName, candidates.map(\.path))
            }
            return ResolvedBundledRuntimeResource(
                sourceURL: sourceURL,
                destinationNames: resource.destinationNames
            )
        }
    }

    private func bundledResourceFileURL(named name: String, directory: String) -> URL? {
        existingFileURL(in: bundledResourceFileCandidates(named: name, directory: directory))
    }

    private func bundledResourceFileCandidates(named name: String, directory: String) -> [URL] {
        var candidates: [URL] = []
        var seenPaths: Set<String> = []

        for bundle in resourceBundles {
            append(bundle.url(forResource: name, withExtension: nil, subdirectory: directory), to: &candidates, seenPaths: &seenPaths)
            append(bundle.url(forResource: name, withExtension: nil), to: &candidates, seenPaths: &seenPaths)
            if let resourceURL = bundle.resourceURL {
                append(
                    resourceURL.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(name),
                    to: &candidates,
                    seenPaths: &seenPaths
                )
                append(
                    resourceURL
                        .appendingPathComponent("Resources", isDirectory: true)
                        .appendingPathComponent(directory, isDirectory: true)
                        .appendingPathComponent(name),
                    to: &candidates,
                    seenPaths: &seenPaths
                )
                append(resourceURL.appendingPathComponent(name), to: &candidates, seenPaths: &seenPaths)
            }
        }

        #if DEBUG
        if let resourceURL = developmentResourceRootURL {
            append(resourceURL.appendingPathComponent(directory, isDirectory: true).appendingPathComponent(name), to: &candidates, seenPaths: &seenPaths)
        }
        #endif

        return candidates
    }

    private var resourceBundles: [Bundle] {
        #if SWIFT_PACKAGE
        var bundles: [Bundle] = [Bundle.module]
        #else
        var bundles: [Bundle] = [Bundle.main]
        #endif
        bundles.append(contentsOf: Bundle.allBundles)
        bundles.append(contentsOf: Bundle.allFrameworks)
        return bundles
    }

    private func append(_ url: URL?, to candidates: inout [URL], seenPaths: inout Set<String>) {
        guard let url else {
            return
        }
        let path = url.standardizedFileURL.path
        guard seenPaths.insert(path).inserted else {
            return
        }
        candidates.append(url)
    }

    private func existingFileURL(in candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    #if DEBUG
    private var developmentResourceRootURL: URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let appDirectory = sourceFileURL.deletingLastPathComponent()
        let projectSourceDirectory = appDirectory.deletingLastPathComponent()
        let resourceURL = projectSourceDirectory.appendingPathComponent("Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resourceURL.path) else {
            return nil
        }
        return resourceURL
    }
    #endif

    private static func loadSystemProxySnapshots(from url: URL) -> [String: ProxyServiceSnapshot] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: ProxyServiceSnapshot].self, from: data) else {
            return [:]
        }
        return decoded.filter { service, snapshot in
            !service.isEmpty && service == snapshot.service
        }
    }

    /// Persists the recovery record before the corresponding OS mutation. Updating the in-memory
    /// copy only after the durable write succeeds keeps both views transactional.
    private func replaceSystemProxySnapshots(with snapshots: [String: ProxyServiceSnapshot]) throws {
        if snapshots.isEmpty {
            if FileManager.default.fileExists(atPath: paths.systemProxySnapshotsURL.path) {
                try FileManager.default.removeItem(at: paths.systemProxySnapshotsURL)
            }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicFileWriter.write(try encoder.encode(snapshots), to: paths.systemProxySnapshotsURL)
        }
        systemProxySnapshots = snapshots
    }

    private func managedPort(for snapshot: ProxyServiceSnapshot) -> Int {
        snapshot.managedLoopbackPort ?? Self.storedStartParams().mixedPort
    }

    private func liveSystemProxyIsOwned(
        service: String,
        original: ProxyServiceSnapshot
    ) throws -> Bool {
        let current = try systemProxyController.snapshot(service: service)
        return SystemProxyController.canRestorePersistedSnapshot(
            original,
            from: current,
            neoClashPort: managedPort(for: original)
        )
    }

    /// Forgets a recovery record without changing macOS proxy state. Once ownership validation
    /// fails, the live user/third-party settings are authoritative and must never be overwritten.
    private func discardSystemProxySnapshot(service: String, errorLabel: String) {
        var updated = systemProxySnapshots
        updated[service] = nil
        verifiedSystemProxySnapshotServices.remove(service)
        neoClashProxyEnabledServices.remove(service)
        do {
            try replaceSystemProxySnapshots(with: updated)
        } catch {
            // Keep the stale disk file for inspection on the next launch, but make it ineligible
            // for any mutation during this app session.
            systemProxySnapshots = updated
            runtime.reportError(errorLabel, diagnostics: error.localizedDescription)
        }
    }

    private func restorePersistedSystemProxySnapshots() {
        guard !systemProxySnapshots.isEmpty else {
            return
        }
        runtime.appendLog(level: .warning, "Restoring system proxy settings left by an interrupted NeoClash session.")
        var servicesToRestore: Set<String> = []
        for service in Array(systemProxySnapshots.keys) {
            do {
                guard let original = systemProxySnapshots[service] else {
                    continue
                }
                if try liveSystemProxyIsOwned(service: service, original: original) {
                    verifiedSystemProxySnapshotServices.insert(service)
                    servicesToRestore.insert(service)
                    continue
                }

                // The user or another app changed this service after NeoClash was interrupted.
                // Its newer state is authoritative; discard our stale recovery record without
                // mutating the OS configuration.
                discardSystemProxySnapshot(
                    service: service,
                    errorLabel: "Stale system proxy recovery record cleanup failed"
                )
                runtime.appendLog(level: .info, "Kept newer system proxy settings for \(service).")
            } catch {
                verifiedSystemProxySnapshotServices.remove(service)
                runtime.reportError(
                    "System proxy recovery inspection failed",
                    diagnostics: "\(service): \(error.localizedDescription)"
                )
            }
        }
        restoreSystemProxyIfNeeded(services: servicesToRestore)
    }

    private func enableSystemProxy(port: Int) throws {
        let service = try systemProxyController.selectedService()
        // Capture-once per service: only snapshot the user's pre-NeoClash proxy state the first
        // time we enable on a given service in a session, before we overwrite it with our
        // loopback proxy. A later re-enable on the same service — e.g. rejoining the proxy after
        // leaving a "disable on this Wi-Fi" network, where the live config is our own
        // suppressed/loopback state — must NOT re-snapshot, or it would permanently lose the
        // user's real settings (a corporate proxy, custom bypass domains) when we later restore
        // on stop. The selected service can change mid-session (Wi-Fi → Ethernet dock), so each
        // service we touch gets its own snapshot and every one is restored on stop.
        let originalSnapshot: ProxyServiceSnapshot
        if let existing = systemProxySnapshots[service] {
            guard verifiedSystemProxySnapshotServices.contains(service) else {
                throw AppCoordinatorError.unverifiedSystemProxyRecovery(service)
            }
            guard try liveSystemProxyIsOwned(service: service, original: existing) else {
                discardSystemProxySnapshot(
                    service: service,
                    errorLabel: "Changed system proxy recovery record cleanup failed"
                )
                throw AppCoordinatorError.systemProxyOwnershipChanged(service)
            }
            if existing.managedLoopbackPort == port {
                originalSnapshot = existing
            } else {
                var updatedSnapshot = existing
                updatedSnapshot.managedLoopbackPort = port
                var updated = systemProxySnapshots
                updated[service] = updatedSnapshot
                try replaceSystemProxySnapshots(with: updated)
                originalSnapshot = updatedSnapshot
            }
        } else {
            var snapshot = try systemProxyController.snapshot(service: service)
            try SystemProxyController.validateCanOverwrite(snapshot)
            snapshot.managedLoopbackPort = port
            var updated = systemProxySnapshots
            updated[service] = snapshot
            try replaceSystemProxySnapshots(with: updated)
            verifiedSystemProxySnapshotServices.insert(service)
            originalSnapshot = snapshot
        }

        do {
            try systemProxyController.enable(service: service, host: "127.0.0.1", port: port)
            neoClashProxyEnabledServices.insert(service)
            runtime.appendLog(level: .info, "Enabled system proxy for \(service)")
        } catch {
            let setupError = error
            neoClashProxyEnabledServices.remove(service)

            do {
                // Even an existing recovery snapshot must be used here: networksetup applies
                // several commands, so a later command can fail after earlier proxy kinds changed.
                try systemProxyController.restore(snapshot: originalSnapshot)
            } catch let rollbackError {
                // Disable only endpoints still carrying NeoClash's exact signature. A restore may
                // already have reapplied another proxy kind before a later command failed.
                _ = try? systemProxyController.disableMatchingLoopback(
                    service: service,
                    port: managedPort(for: originalSnapshot)
                )
                throw AppCoordinatorError.systemProxyRollbackFailed(
                    setup: setupError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }

            // OS rollback succeeded. Clean the durable record separately; a failure here must not
            // fall into disableAll and turn off the corporate proxy we just restored.
            var updated = systemProxySnapshots
            updated[service] = nil
            verifiedSystemProxySnapshotServices.remove(service)
            do {
                try replaceSystemProxySnapshots(with: updated)
            } catch {
                // The OS is already back to the user's original settings. Forget the in-memory
                // record so a later toggle cannot replay it over newer changes; the stale disk
                // record is checked against the live loopback signature on the next launch.
                systemProxySnapshots = updated
                runtime.reportError(
                    "System proxy recovery record cleanup failed",
                    diagnostics: error.localizedDescription
                )
            }
            throw setupError
        }
    }

    private func restoreSystemProxyIfNeeded(services: Set<String>? = nil) {
        let snapshots = systemProxySnapshots.filter { service, _ in
            verifiedSystemProxySnapshotServices.contains(service)
                && (services?.contains(service) ?? true)
        }
        guard !snapshots.isEmpty else {
            if services == nil {
                neoClashProxyEnabledServices.removeAll()
            }
            return
        }
        for (service, snapshot) in snapshots {
            do {
                guard try liveSystemProxyIsOwned(service: service, original: snapshot) else {
                    discardSystemProxySnapshot(
                        service: service,
                        errorLabel: "Changed system proxy recovery record cleanup failed"
                    )
                    runtime.appendLog(
                        level: .info,
                        "Kept newer system proxy settings for \(service)."
                    )
                    continue
                }
            } catch {
                runtime.reportError(
                    "System proxy ownership verification failed",
                    diagnostics: "\(service): \(error.localizedDescription)"
                )
                continue
            }

            do {
                try systemProxyController.restore(snapshot: snapshot)
            } catch {
                // Preserve any original endpoint already reapplied before the failure; only exact
                // NeoClash loopback remnants are safe to turn off.
                _ = try? systemProxyController.disableMatchingLoopback(
                    service: service,
                    port: managedPort(for: snapshot)
                )
                neoClashProxyEnabledServices.remove(service)
                runtime.reportError("System proxy restore failed", diagnostics: error.localizedDescription)
                continue
            }

            var updated = systemProxySnapshots
            updated[service] = nil
            verifiedSystemProxySnapshotServices.remove(service)
            do {
                try replaceSystemProxySnapshots(with: updated)
                neoClashProxyEnabledServices.remove(service)
                runtime.appendLog(level: .info, "Restored system proxy for \(snapshot.service)")
            } catch {
                // The OS has been restored successfully. Do not replay this snapshot during the
                // current session: the user may change proxy settings before the next cleanup.
                // The stale disk record remains recoverable and will be validated on next launch.
                systemProxySnapshots = updated
                neoClashProxyEnabledServices.remove(service)
                runtime.reportError("System proxy recovery record cleanup failed", diagnostics: error.localizedDescription)
            }
        }
    }

    private func startStreams(host: String, port: Int, secret: String) {
        stopStreams()
        let client = MihomoWebSocketClient(host: host, port: port, secret: secret)
        webSocketClient = client

        streamTasks = [
            makeStreamTask(path: "/traffic", client: client),
            makeStreamTask(path: "/logs", client: client),
            makeStreamTask(path: "/connections", client: client)
        ]
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

    private static func storedTUNSettings(isEnabled: Bool) -> TUNSettings {
        let defaults = UserDefaults.standard
        let storedStack = defaults.string(forKey: "tunStack") ?? TUNSettings.defaultStack
        let autoRoute = defaults.object(forKey: "autoRoute") == nil ? true : defaults.bool(forKey: "autoRoute")
        return TUNSettings(isEnabled: isEnabled, stack: storedStack, autoRoute: autoRoute)
    }

    /// Consumes a Mihomo WebSocket stream, reconnecting with exponential backoff while the core runs.
    private func makeStreamTask(path: String, client: MihomoWebSocketClient) -> Task<Void, Never> {
        Task { [weak self] in
            let minBackoff: UInt64 = 500_000_000
            let maxBackoff: UInt64 = 5_000_000_000
            var backoff = minBackoff

            while !Task.isCancelled {
                var receivedEvent = false
                let stream = await client.stream(path: path)
                for await event in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    receivedEvent = true
                    self?.apply(streamEvent: event)
                }

                guard !Task.isCancelled, let self, self.runtime.status.isRunning else {
                    break
                }
                // Reset backoff after a healthy connection; otherwise grow it.
                backoff = receivedEvent ? minBackoff : min(backoff * 2, maxBackoff)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    private func stopStreams() {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        if let webSocketClient {
            Task {
                await webSocketClient.stop()
            }
        }
        webSocketClient = nil
    }

    private func startCoreResourceUpdates(pid: Int32) {
        stopCoreResourceUpdates()
        coreResourceTask = Task { [weak self, coreResourceMonitor] in
            var previousSample: CoreResourceSample?
            while !Task.isCancelled {
                // Sample off the main actor: the TUN fallback inside the monitor shells
                // out to `ps` and blocks on the child process.
                let previous = previousSample
                let result = await Task.detached(priority: .utility) {
                    coreResourceMonitor.snapshot(pid: pid, previous: previous)
                }.value
                guard let self, !Task.isCancelled else {
                    return
                }
                if let result {
                    previousSample = result.sample
                    self.runtime.update(coreResource: result.snapshot)
                } else {
                    // A sample can fail transiently; keep polling — the watchdog owns
                    // death detection, and stop() cancels this task.
                    previousSample = nil
                    self.runtime.update(coreResource: .empty)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopCoreResourceUpdates() {
        coreResourceTask?.cancel()
        coreResourceTask = nil
        runtime.update(coreResource: .empty)
    }

    /// Polls the running core for liveness (the child process) and responsiveness (the controller
    /// API). A core that exits or stops answering is recovered: the dead routing/system-proxy state
    /// is torn down and, within a bounded budget, the core is relaunched with the same parameters.
    /// This is the safety net for "the site stops loading after a while" — typically a TUN core that
    /// crashed or hung, which previously left the app showing "running" while traffic blackholed.
    private func startCoreWatchdog() {
        stopCoreWatchdog()
        coreWatchdogTask = Task { [weak self] in
            let interval: UInt64 = 5_000_000_000
            // Require several consecutive unanswered probes before declaring a live core "hung", so a
            // brief stall (sleep/wake, a burst of load) doesn't trigger an unnecessary restart.
            let unhealthyThreshold = 3
            var consecutiveUnhealthy = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                guard self.runtime.status.isRunning, self.runtimeBackend == .real else { continue }

                let alive = await self.processController.isCoreRunning()
                if !alive {
                    await self.recoverFromCoreFailure(reason: "the core process exited unexpectedly")
                    return
                }

                let responsive = await self.isCoreResponsive()
                if responsive {
                    consecutiveUnhealthy = 0
                    // Clear the restart budget once a recovered core has been healthy long enough that
                    // the failure looks resolved rather than a tight loop.
                    if let last = self.lastCoreRestartAt,
                       Date().timeIntervalSince(last) >= Self.coreHealthyResetInterval {
                        self.coreAutoRestartCount = 0
                        self.lastCoreRestartAt = nil
                    }
                    continue
                }

                consecutiveUnhealthy += 1
                if consecutiveUnhealthy >= unhealthyThreshold {
                    await self.recoverFromCoreFailure(reason: "the core stopped responding on its control port")
                    return
                }
            }
        }
    }

    private func stopCoreWatchdog() {
        coreWatchdogTask?.cancel()
        coreWatchdogTask = nil
    }

    /// A lightweight liveness probe against the controller API. Loopback, so it is unaffected by the
    /// proxy/TUN data path — it reflects whether the core itself is still servicing requests.
    private func isCoreResponsive() async -> Bool {
        guard let apiClient else {
            return false
        }
        return (try? await apiClient.version()) != nil
    }

    /// Tears down a failed core and recovers connectivity. The system proxy is restored first (so the
    /// OS is not left pointing at a dead local port) and the process is force-stopped so a hung core
    /// releases its `utun` device and auto-route entries. Within the restart budget the core is then
    /// relaunched with the last user-supplied parameters; once exhausted it is left in a visible
    /// crashed state instead of looping.
    private func recoverFromCoreFailure(reason: String) async {
        // Bail out if an intentional stop/restart already took over since the probe failed.
        guard runtime.status.isRunning, runtimeBackend == .real else {
            return
        }

        let diagnostics = await processController.capturedOutput
        runtime.appendLog(level: .error, "Core watchdog: \(reason). Recovering…")

        // This method runs from the watchdog task itself. Clear the stored handle before teardown
        // so stopRuntime() does not cancel the task that must finish the recovery sequence.
        coreWatchdogTask = nil
        let params = lastStartParams
        let shouldRemainAutoStarted = autoStartedByProxyMode
        await stopRuntime()

        // A user stop can race the watchdog while teardown is suspended. User intent wins: never
        // resurrect a core after Stop or Quit has taken ownership of the lifecycle.
        guard desiredRunning else {
            return
        }

        guard coreAutoRestartCount < Self.maxCoreAutoRestarts, let params else {
            desiredRunning = false
            autoStartedByProxyMode = false
            runtime.markCrashed(
                "The core stopped unexpectedly and automatic restart was exhausted. Start it again to reconnect.",
                diagnostics: diagnostics
            )
            return
        }

        coreAutoRestartCount += 1
        lastCoreRestartAt = Date()
        runtime.appendLog(
            level: .warning,
            "Restarting the core (attempt \(coreAutoRestartCount) of \(Self.maxCoreAutoRestarts))."
        )
        // Move out of `.running` so the (private) start path's in-progress guard lets the relaunch
        // proceed; `start` immediately transitions to `.starting`.
        runtime.status = .crashed(message: "The core stopped unexpectedly — restarting…")
        await start(
            mixedPort: params.mixedPort,
            controllerPort: params.controllerPort,
            allowLAN: params.allowLAN,
            autoStartedByProxyMode: shouldRemainAutoStarted
        )
    }

    private func apply(streamEvent: MihomoStreamEvent) {
        switch streamEvent {
        case .traffic(let snapshot):
            runtime.update(traffic: snapshot)
            persistDailyTraffic()
        case .log(let entry):
            runtime.appendLog(level: entry.level, entry.message)
        case .connections(let entries):
            runtime.update(connections: entries)
        case .raw:
            break
        }
    }

    private func perform(
        _ label: String,
        markBusy: Bool = false,
        failureCrashes: Bool = false,
        operation: @escaping () async throws -> Void
    ) async {
        if markBusy {
            isBusy = true
        }
        defer {
            if markBusy {
                isBusy = false
            }
        }

        do {
            try await operation()
        } catch {
            let message = "\(label) failed"
            if failureCrashes {
                let diagnostics = error.localizedDescription
                runtime.markCrashed(diagnostics.isEmpty ? message : diagnostics, diagnostics: diagnostics)
            } else {
                runtime.reportError(message, diagnostics: error.localizedDescription)
            }
        }
    }
}

private enum RuntimeBackend {
    case stopped
    case real
}

private enum ProxyHealOutcome: Sendable {
    case cleared([String])
    case portInUse(Int)
    case failed(String)
    case noLoopbackProxy
}

enum AppCoordinatorError: Error, LocalizedError {
    case noActiveProfile
    case invalidSubscriptionURL
    case missingBundledResource(String, [String])
    case notSubscription
    case runtimeNotRunning
    case systemProxyRollbackFailed(setup: String, rollback: String)
    case unverifiedSystemProxyRecovery(String)
    case systemProxyOwnershipChanged(String)

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            "Select or import a profile first."
        case .invalidSubscriptionURL:
            "Enter a valid HTTPS subscription URL."
        case .missingBundledResource(let name, let searchedPaths):
            "Bundled runtime resource is missing: \(name). Rebuild NeoClash so the Core and Geo resources are copied into the app bundle.\(searchedPaths.isEmpty ? "" : "\nSearched paths:\n" + searchedPaths.joined(separator: "\n"))"
        case .notSubscription:
            "The selected profile is not a remote subscription."
        case .runtimeNotRunning:
            "Start the runtime before using this action."
        case .systemProxyRollbackFailed(let setup, let rollback):
            "System proxy setup failed (\(setup)), and restoring the previous settings also failed (\(rollback)). NeoClash disabled the proxy and will retry recovery later."
        case .unverifiedSystemProxyRecovery(let service):
            "NeoClash could not verify the pending system proxy recovery record for \(service). Restart the app after the network service becomes available."
        case .systemProxyOwnershipChanged(let service):
            "The \(service) proxy settings changed outside NeoClash, so the newer settings were kept."
        }
    }
}
