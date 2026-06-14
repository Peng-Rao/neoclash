import Foundation
import NeoClashCore
import Observation

private struct BundledRuntimeResource: Sendable {
    var sourceName: String
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
    private let configBuilder: RuntimeConfigBuilder
    private let systemProxyController: SystemProxyController
    private let networkStatusProbe: NetworkStatusProbe
    private var apiClient: MihomoAPIClient?
    private var webSocketClient: MihomoWebSocketClient?
    private var streamTasks: [Task<Void, Never>] = []
    private var networkStatusTask: Task<Void, Never>?
    private var runtimeBackend: RuntimeBackend = .stopped
    private var systemProxySnapshot: ProxyServiceSnapshot?
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
        self.configBuilder = RuntimeConfigBuilder()
        self.systemProxyController = SystemProxyController()
        self.networkStatusProbe = NetworkStatusProbe()
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

    func start(mixedPort: Int, controllerPort: Int) async {
        guard !runtime.status.isRunning else {
            return
        }

        runtime.markStarting()

        await perform("Start runtime", markBusy: true, failureCrashes: true) {
            let identity = RuntimeIdentity()
            let overrides = RuntimeOverrides(
                ports: RuntimePorts(mixedPort: mixedPort, controllerHost: "127.0.0.1", controllerPort: controllerPort),
                mode: self.runtime.mode,
                tun: TUNSettings(isEnabled: self.runtime.isTUNEnabled)
            )

            let originalYAML = try await self.runtimeProfileYAML()
            let runtimeYAML = try self.configBuilder.build(originalYAML: originalYAML, overrides: overrides, identity: identity)
            try await self.prepareRuntimeFiles(runtimeYAML: runtimeYAML)

            let result = try await self.processController.start(
                CoreStartRequest(
                    coreURL: self.bundledCoreURL,
                    runtimeDirectory: self.paths.runtimeDirectory,
                    runtimeConfigURL: self.paths.runtimeConfigURL,
                    manifest: self.bundledCoreManifest,
                    ports: overrides.ports,
                    secret: identity.secret
                )
            )

            let apiClient = MihomoAPIClient(
                host: overrides.ports.controllerHost,
                port: overrides.ports.controllerPort,
                secret: identity.secret
            )
            self.apiClient = apiClient
            self.runtimeBackend = .real
            do {
                if self.runtime.isSystemProxyEnabled {
                    try self.enableSystemProxy(port: overrides.ports.mixedPort)
                }
            } catch {
                await self.processController.stop()
                self.restoreSystemProxyIfNeeded()
                self.apiClient = nil
                throw error
            }
            self.runtime.markRunning(version: result.version)
            await self.reloadRuntimeData()
            self.startStreams(host: overrides.ports.controllerHost, port: overrides.ports.controllerPort, secret: identity.secret)
        }
    }

    func stop() async {
        runtime.status = .stopping
        restoreSystemProxyIfNeeded()
        stopStreams()
        apiClient = nil
        if runtimeBackend == .real {
            await processController.stop()
        }
        runtimeBackend = .stopped
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

    func testDelays() async {
        guard let apiClient else {
            runtime.reportError("Delay test failed", diagnostics: "Mihomo API client is not available.")
            return
        }

        var groups = runtime.proxies
        await withTaskGroup(of: (String, String, Int?).self) { group in
            for proxyGroup in groups {
                for node in proxyGroup.nodes {
                    group.addTask {
                        let delay = await apiClient.testDelay(name: node.name)
                        return (proxyGroup.name, node.name, delay)
                    }
                }
            }

            for await result in group {
                guard let groupIndex = groups.firstIndex(where: { $0.name == result.0 }),
                      let nodeIndex = groups[groupIndex].nodes.firstIndex(where: { $0.name == result.1 }) else {
                    continue
                }
                groups[groupIndex].nodes[nodeIndex].delay = result.2
            }
        }
        runtime.update(proxies: groups)
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
        let geoDirectoryURL = bundledGeoDirectoryURL
        let bundledRuntimeResources = Self.bundledRuntimeResources
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            if let geoDirectoryURL {
                for resource in bundledRuntimeResources {
                    let sourceURL = geoDirectoryURL.appendingPathComponent(resource.sourceName)
                    guard fileManager.fileExists(atPath: sourceURL.path) else {
                        continue
                    }
                    for destinationName in resource.destinationNames {
                        let destinationURL = runtimeDirectory.appendingPathComponent(destinationName)
                        if fileManager.fileExists(atPath: destinationURL.path) {
                            try fileManager.removeItem(at: destinationURL)
                        }
                        try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    }
                }
            }
            try AtomicFileWriter.write(runtimeYAML, to: runtimeConfigURL)
        }.value
    }

    private var bundledCoreURL: URL {
        if let resourceURL = bundledResourceURL {
            return resourceURL.appendingPathComponent("Core/mihomo")
        }
        return paths.coresDirectory.appendingPathComponent("mihomo")
    }

    private var bundledCoreManifest: CoreManifest? {
        guard let resourceURL = bundledResourceURL else {
            return nil
        }
        let manifestURL = resourceURL.appendingPathComponent("Core/mihomo-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CoreManifest.self, from: data)
    }

    private var bundledGeoDirectoryURL: URL? {
        bundledResourceURL?.appendingPathComponent("Geo", isDirectory: true)
    }

    private var bundledResourceURL: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.resourceURL
        #else
        Bundle.main.resourceURL
        #endif
    }

    private func enableSystemProxy(port: Int) throws {
        let service = try systemProxyController.selectedService()
        let snapshot = try systemProxyController.snapshot(service: service)
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
            Task { [weak self] in
                let stream = await client.stream(path: "/traffic")
                for await event in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    self?.apply(streamEvent: event)
                }
            },
            Task { [weak self] in
                let stream = await client.stream(path: "/logs")
                for await event in stream {
                    guard !Task.isCancelled else {
                        break
                    }
                    self?.apply(streamEvent: event)
                }
            }
        ]
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

    private func apply(streamEvent: MihomoStreamEvent) {
        switch streamEvent {
        case .traffic(let snapshot):
            runtime.update(traffic: snapshot)
        case .log(let entry):
            runtime.appendLog(level: entry.level, entry.message)
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
                runtime.markCrashed(message, diagnostics: error.localizedDescription)
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

enum AppCoordinatorError: Error, LocalizedError {
    case noActiveProfile
    case invalidSubscriptionURL
    case notSubscription
    case runtimeNotRunning

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            "Select or import a profile first."
        case .invalidSubscriptionURL:
            "Enter a valid HTTP or HTTPS subscription URL."
        case .notSubscription:
            "The selected profile is not a remote subscription."
        case .runtimeNotRunning:
            "Start the runtime before using this action."
        }
    }
}
