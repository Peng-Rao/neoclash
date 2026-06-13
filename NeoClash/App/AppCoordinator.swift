import Foundation
import NeoClashCore
import Observation

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
    private var apiClient: MihomoAPIClient?
    private var webSocketClient: MihomoWebSocketClient?
    private var streamTasks: [Task<Void, Never>] = []

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
            guard let profile = self.runtime.activeProfile else {
                throw AppCoordinatorError.noActiveProfile
            }

            let identity = RuntimeIdentity()
            let overrides = RuntimeOverrides(
                ports: RuntimePorts(mixedPort: mixedPort, controllerHost: "127.0.0.1", controllerPort: controllerPort),
                mode: self.runtime.mode,
                tun: TUNSettings(isEnabled: self.runtime.isTUNEnabled)
            )

            let originalYAML = try await self.profileStore.yaml(for: profile)
            let runtimeYAML = try self.configBuilder.build(originalYAML: originalYAML, overrides: overrides, identity: identity)
            try await self.prepareRuntimeFiles(runtimeYAML: runtimeYAML)

            let result = try await self.processController.start(
                CoreStartRequest(
                    coreURL: self.bundledCoreURL,
                    runtimeDirectory: self.paths.runtimeDirectory,
                    runtimeConfigURL: self.paths.runtimeConfigURL,
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
            self.runtime.markRunning(version: result.version)
            await self.reloadRuntimeData()
            self.startStreams(host: overrides.ports.controllerHost, port: overrides.ports.controllerPort, secret: identity.secret)
        }
    }

    func stop() async {
        runtime.status = .stopping
        stopStreams()
        apiClient = nil
        await processController.stop()
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

    private func prepareRuntimeFiles(runtimeYAML: String) async throws {
        let runtimeDirectory = paths.runtimeDirectory
        let runtimeConfigURL = paths.runtimeConfigURL
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            try AtomicFileWriter.write(runtimeYAML, to: runtimeConfigURL)
        }.value
    }

    private var bundledCoreURL: URL {
        if let resourceURL = Bundle.module.resourceURL {
            return resourceURL.appendingPathComponent("Core/mihomo")
        }
        return paths.coresDirectory.appendingPathComponent("mihomo")
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
