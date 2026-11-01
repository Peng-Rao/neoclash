import Foundation
import NeoClashMobileCore

/// One running core, seen through its controller. Feeds RuntimeStore and carries out what the UI
/// asks of the core.
@MainActor
final class IOSCoreSession {
    private static let readinessTimeout: Duration = .seconds(10)
    private static let readinessPollInterval: Duration = .milliseconds(250)
    private static let logFlushInterval: Duration = .milliseconds(250)
    private static let maxConcurrentDelayTests = 8

    private let runtime: RuntimeStore
    private let endpoint: ControllerEndpoint
    private let api: MihomoAPIClient
    private var webSocket: MihomoWebSocketClient?
    private var streamTasks: [Task<Void, Never>] = []
    private var pendingLogs: [CoreLogEntry] = []
    private var logFlushTask: Task<Void, Never>?

    init(runtime: RuntimeStore, endpoint: ControllerEndpoint) {
        self.runtime = runtime
        self.endpoint = endpoint
        self.api = MihomoAPIClient(host: endpoint.host, port: endpoint.port, secret: endpoint.secret)
    }

    /// The core opens its controller asynchronously, so a refused connection only means "not yet".
    /// Any HTTP error means something answered, most likely another core holding the port.
    func waitUntilReady() async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.readinessTimeout)
        while true {
            do {
                return try await api.version().version
            } catch let error as MihomoAPIError {
                throw error
            } catch {
                if clock.now >= deadline {
                    throw error
                }
            }
            try await Task.sleep(for: Self.readinessPollInterval)
        }
    }

    var isReachable: Bool {
        get async {
            (try? await api.version()) != nil
        }
    }

    func reload() async {
        if let proxies = try? await api.proxies() {
            runtime.update(proxies: proxies)
        }
        if let rules = try? await api.rules() {
            runtime.update(rules: rules)
        }
    }

    func updateMode(_ mode: RoutingMode) async throws {
        try await api.updateMode(mode)
    }

    /// Updates the UI first so a tap feels instant, and rolls back if the core refuses. Existing
    /// connections are closed so apps move to the new node instead of staying on the old one.
    func selectProxy(group: String, proxy: String) async throws {
        let previous = runtime.proxies
        runtime.update(proxies: previous.map { candidate in
            guard candidate.name == group else {
                return candidate
            }
            var updated = candidate
            updated.now = proxy
            updated.nodes = candidate.nodes.map { node in
                var node = node
                node.isSelected = node.name == proxy
                return node
            }
            return updated
        })

        do {
            try await api.selectProxy(group: group, proxy: proxy)
        } catch {
            runtime.update(proxies: previous)
            throw error
        }
        try? await api.closeAllConnections()
        await reload()
    }

    func testDelays() async {
        guard !runtime.isTestingDelays else {
            return
        }
        // Test each unique node once (a node can appear in several groups) and cap concurrency so
        // a large subscription doesn't fire hundreds of simultaneous requests at the controller.
        var seenNodeNames: Set<String> = []
        let nodeNames = runtime.proxies
            .flatMap { $0.nodes.map(\.name) }
            .filter { seenNodeNames.insert($0).inserted }
        guard !nodeNames.isEmpty else {
            return
        }

        runtime.beginDelayTest(nodeNames: nodeNames)
        defer { runtime.finishDelayTest() }

        let api = api
        await withTaskGroup(of: (String, Int?).self) { group in
            var next = 0
            while next < min(Self.maxConcurrentDelayTests, nodeNames.count) {
                let name = nodeNames[next]
                group.addTask { (name, await api.testDelay(name: name)) }
                next += 1
            }
            while let result = await group.next() {
                runtime.recordDelayTestResult(name: result.0, delay: result.1)
                if next < nodeNames.count {
                    let name = nodeNames[next]
                    group.addTask { (name, await api.testDelay(name: name)) }
                    next += 1
                }
            }
        }
        // Automatic groups may have picked a different node from these results.
        await reload()
    }

    func closeConnection(id: String) async throws {
        try await api.closeConnection(id: id)
    }

    func closeAllConnections() async throws {
        try await api.closeAllConnections()
    }

    func startStreams() {
        stopStreams()
        let client = MihomoWebSocketClient(host: endpoint.host, port: endpoint.port, secret: endpoint.secret)
        webSocket = client
        streamTasks = ["/traffic", "/logs", "/connections"].map { makeStreamTask(path: $0, client: client) }
    }

    func stopStreams() {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        logFlushTask?.cancel()
        logFlushTask = nil
        flushLogs()
        if let webSocket {
            Task {
                await webSocket.stop()
            }
        }
        webSocket = nil
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
                    self?.apply(event)
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

    private func apply(_ event: MihomoStreamEvent) {
        switch event {
        case .traffic(let snapshot):
            runtime.update(traffic: snapshot)
        case .log(let entry):
            enqueue(entry)
        case .connections(let entries):
            runtime.update(connections: entries)
        case .raw:
            break
        }
    }

    /// A busy core logs in bursts, and rendering each line separately makes scrolling stutter.
    private func enqueue(_ entry: CoreLogEntry) {
        pendingLogs.append(entry)
        guard logFlushTask == nil else {
            return
        }
        logFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.logFlushInterval)
            guard let self, !Task.isCancelled else {
                return
            }
            self.logFlushTask = nil
            self.flushLogs()
        }
    }

    private func flushLogs() {
        for entry in pendingLogs {
            runtime.appendLog(level: entry.level, entry.message)
        }
        pendingLogs.removeAll()
    }
}
