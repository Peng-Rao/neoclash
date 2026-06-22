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
    private var runtimeBackend: RuntimeBackend = .stopped
    private var systemProxySnapshot: ProxyServiceSnapshot?
    private var activeMixedPort: Int?
    private var autoStartedByProxyMode = false
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
    }

    private static let dailyTrafficKey = "neoclash.dailyTraffic.v1"

    /// Restores the persisted rolling daily-traffic totals so the 7-day chart survives relaunches.
    func restoreDailyTraffic() {
        guard let data = UserDefaults.standard.data(forKey: Self.dailyTrafficKey),
              let samples = try? JSONDecoder().decode([DailyTrafficSample].self, from: data) else {
            return
        }
        runtime.seedDailyTraffic(samples)
    }

    private func persistDailyTraffic() {
        guard let data = try? JSONEncoder().encode(runtime.dailyTraffic) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.dailyTrafficKey)
    }

    func loadProfiles() {
        Task {
            do {
                let profiles = try await profileStore.load()
                runtime.applyProfiles(profiles)
            } catch {
                runtime.reportError("Failed to load profiles", diagnostics: error.localizedDescription)
            }
        }
    }

    /// Cleans up leftovers from a previous crash or force-quit: orphaned core processes (which would
    /// hold the controller/mixed ports) and a system proxy left pointing at a now-dead local core
    /// (which would break connectivity). Safe to call once at launch before anything starts.
    func performLaunchCleanup() {
        Task {
            let reaped = await processController.reapOrphans(runtimeDirectoryPath: paths.runtimeDirectory.path)
            if !reaped.isEmpty {
                runtime.appendLog(level: .warning, "Stopped \(reaped.count) leftover core process(es) from a previous run.")
            }
            await healOrphanedSystemProxy()
        }
    }

    /// Clears a leftover loopback system proxy only when nothing is listening on its port — i.e. it
    /// is a dead proxy we left behind, not a live proxy belonging to another app. Runs off the main
    /// actor (networksetup spawns subprocesses) and reports the outcome.
    private func healOrphanedSystemProxy() async {
        let controller = systemProxyController
        let outcome = await Task.detached(priority: .utility) { () -> ProxyHealOutcome in
            do {
                let service = try controller.selectedService()
                let snapshot = try controller.snapshot(service: service)
                guard let port = SystemProxyController.loopbackProxyPort(snapshot) else {
                    return .noLoopbackProxy
                }
                guard PortChecker().isAvailable(host: "127.0.0.1", port: port) else {
                    return .portInUse(port)
                }
                try controller.disableAll(service: service)
                return .cleared(service)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .cleared(let service):
            runtime.appendLog(level: .warning, "Cleared a leftover system proxy on \(service) from a previous run.")
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
            guard let url = URL(string: urlString), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else {
                throw AppCoordinatorError.invalidSubscriptionURL
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
                throw AppCoordinatorError.noActiveProfile
            }
            guard profile.kind == .remoteSubscription else {
                throw AppCoordinatorError.notSubscription
            }
            let updated = try await self.subscriptionService.update(profile: profile)
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
            self.runtime.activeProfile = updated
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
            try await self.profileStore.delete(profileID: profile.id)
            if self.runtime.activeProfile?.id == profile.id {
                self.runtime.activeProfile = nil
            }
            let profiles = await self.profileStore.allProfiles()
            self.runtime.applyProfiles(profiles)
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
            }
            runtime.appendLog(level: .info, "Saved config for \(updated.name)")
            return true
        } catch {
            runtime.reportError("Failed to save config", diagnostics: error.localizedDescription)
            return false
        }
    }

    func start(mixedPort: Int, controllerPort: Int, allowLAN: Bool = false) async {
        await start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLAN, autoStartedByProxyMode: false)
    }

    private func start(
        mixedPort: Int,
        controllerPort: Int,
        allowLAN: Bool,
        autoStartedByProxyMode: Bool
    ) async {
        switch runtime.status {
        case .stopped, .crashed:
            break
        case .starting, .running, .stopping:
            return
        }

        // Capture restart inputs before any async work so a live TUN toggle can stop and start
        // the core with the same public ports and LAN binding.
        lastStartParams = (mixedPort, controllerPort, allowLAN)
        self.autoStartedByProxyMode = autoStartedByProxyMode
        runtime.markStarting()

        await perform("Start runtime", markBusy: true, failureCrashes: true) {
            let identity = RuntimeIdentity()
            let logLevel = Self.preferredCoreLogLevel()
            let tunEnabled = self.runtime.isTUNEnabled
            let overrides = RuntimeOverrides(
                ports: RuntimePorts.sanitizing(mixedPort: mixedPort, controllerPort: controllerPort),
                mode: self.runtime.mode,
                logLevel: logLevel,
                allowLAN: allowLAN,
                tun: TUNSettings(isEnabled: tunEnabled)
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

            let result = try await self.processController.start(request)
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
                    self.runtime.reportError("System proxy setup failed", diagnostics: error.localizedDescription)
                    self.runtime.appendLog(level: .warning, "Mihomo is running, but macOS system proxy setup failed.")
                }
            }
            self.runtime.markRunning(version: result.version)
            await self.reloadRuntimeData()
            self.startCoreResourceUpdates(pid: result.processIdentifier)
            self.startStreams(host: overrides.ports.controllerHost, port: overrides.ports.controllerPort, secret: identity.secret)
        }

        stopIfAutoStartedWithoutProxyModes()
    }

    func stop() async {
        guard runtime.status != .stopped else {
            return
        }
        runtime.status = .stopping
        restoreSystemProxyIfNeeded()
        stopStreams()
        stopCoreResourceUpdates()
        apiClient = nil
        if runtimeBackend == .real {
            await processController.stop()
        }
        runtimeBackend = .stopped
        activeMixedPort = nil
        autoStartedByProxyMode = false
        runtime.markStopped()
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
        guard runtime.status.isRunning, let apiClient else {
            return
        }
        Task {
            do {
                try await apiClient.updateMode(mode)
                self.runtime.appendLog(level: .info, "Switched outbound mode to \(mode.displayName)")
                await self.reloadRuntimeData()
            } catch {
                self.runtime.appendLog(level: .warning, "Failed to switch mode: \(error.localizedDescription)")
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
            }
            return
        }
        if enabled {
            guard let port = activeMixedPort else {
                return
            }
            do {
                try enableSystemProxy(port: port)
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
        guard runtime.status.isRunning, let params = lastStartParams else {
            if enabled {
                startUsingStoredSettings()
            }
            return
        }
        if !enabled, autoStartedByProxyMode, !runtime.isSystemProxyEnabled {
            Task { await self.stop() }
            return
        }
        // TUN changes affect both the generated YAML and the executable privilege state. A full
        // restart keeps the running core aligned with the user's selected mode.
        let shouldRemainAutoStarted = autoStartedByProxyMode
        Task {
            await self.stop()
            await self.start(
                mixedPort: params.mixedPort,
                controllerPort: params.controllerPort,
                allowLAN: params.allowLAN,
                autoStartedByProxyMode: shouldRemainAutoStarted
            )
        }
    }

    private func startUsingStoredSettings() {
        switch runtime.status {
        case .stopped, .crashed:
            let params = Self.storedStartParams()
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

    func closeAllConnections() async {
        await perform("Close connections") {
            guard let apiClient = self.apiClient else {
                throw AppCoordinatorError.runtimeNotRunning
            }
            try await apiClient.closeAllConnections()
            self.runtime.update(connections: [])
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
            // Already granted: reuse as-is (re-copying would need root and re-prompt).
            if privilegeManager.hasRootPrivileges(coreURL: destination) {
                return destination
            }
            // Plain copy: refresh only if the bundled core changed.
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

    private func enableSystemProxy(port: Int) throws {
        let service = try systemProxyController.selectedService()
        // Sanitize loopback entries so a leftover proxy from a previous run (pointing at our own
        // core) is never captured as the state to restore — otherwise stopping would re-enable a
        // dead 127.0.0.1 proxy and break connectivity.
        let snapshot = SystemProxyController.sanitizingLoopback(try systemProxyController.snapshot(service: service))
        try systemProxyController.enable(service: service, host: "127.0.0.1", port: port)
        systemProxySnapshot = snapshot
        runtime.appendLog(level: .info, "Enabled system proxy for \(service)")
    }

    private func restoreSystemProxyIfNeeded() {
        guard let snapshot = systemProxySnapshot else {
            return
        }
        do {
            try systemProxyController.restore(snapshot: snapshot)
            runtime.appendLog(level: .info, "Restored system proxy for \(snapshot.service)")
        } catch {
            runtime.reportError("System proxy restore failed", diagnostics: error.localizedDescription)
        }
        systemProxySnapshot = nil
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
        coreResourceTask = Task { [weak self] in
            var previousSample: CoreResourceSample?
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                if let result = self.coreResourceMonitor.snapshot(pid: pid, previous: previousSample) {
                    previousSample = result.sample
                    self.runtime.update(coreResource: result.snapshot)
                } else {
                    self.runtime.update(coreResource: .empty)
                    return
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
    case cleared(String)
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

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            "Select or import a profile first."
        case .invalidSubscriptionURL:
            "Enter a valid HTTP or HTTPS subscription URL."
        case .missingBundledResource(let name, let searchedPaths):
            "Bundled runtime resource is missing: \(name). Rebuild NeoClash so the Core and Geo resources are copied into the app bundle.\(searchedPaths.isEmpty ? "" : "\nSearched paths:\n" + searchedPaths.joined(separator: "\n"))"
        case .notSubscription:
            "The selected profile is not a remote subscription."
        case .runtimeNotRunning:
            "Start the runtime before using this action."
        }
    }
}
