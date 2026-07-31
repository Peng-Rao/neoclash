import Foundation

public enum MihomoStreamEvent: Equatable, Sendable {
    case traffic(TrafficSnapshot)
    case log(CoreLogEntry)
    case connections([ConnectionEntry])
    case raw(Data)
}

public actor MihomoWebSocketClient {
    /// Keeps slow consumers from retaining an unbounded number of traffic snapshots or log lines.
    /// Newest events are more useful for the live UI than an arbitrarily old backlog.
    static let streamBufferLimit = 64

    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    private var tasks: [UUID: URLSessionWebSocketTask] = [:]
    private var isStopped = false

    public init(host: String, port: Int, secret: String, session: URLSession? = nil) {
        let endpoint = RuntimePorts.controllerEndpoint(host: host, port: port)
        guard let baseURL = URL(string: "ws://\(endpoint)") else {
            preconditionFailure("Invalid Mihomo WebSocket endpoint")
        }
        self.baseURL = baseURL
        self.secret = secret
        self.session = session ?? URLSession(configuration: .default)
    }

    public func stop() {
        isStopped = true
        tasks.values.forEach { $0.cancel(with: .goingAway, reason: nil) }
        tasks.removeAll()
    }

    public func stream(path: String) -> AsyncStream<MihomoStreamEvent> {
        let streamID = UUID()
        let (stream, continuation) = Self.makeBufferedStream()
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.closeStream(id: streamID)
            }
        }
        open(id: streamID, path: path, continuation: continuation)
        return stream
    }

    static func makeBufferedStream() -> (
        stream: AsyncStream<MihomoStreamEvent>,
        continuation: AsyncStream<MihomoStreamEvent>.Continuation
    ) {
        AsyncStream.makeStream(
            of: MihomoStreamEvent.self,
            bufferingPolicy: .bufferingNewest(streamBufferLimit)
        )
    }

    private func open(
        id: UUID,
        path: String,
        continuation: AsyncStream<MihomoStreamEvent>.Continuation
    ) {
        guard !isStopped else {
            continuation.finish()
            return
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = components?.url else {
            continuation.finish()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        tasks[id] = task
        task.resume()
        receive(id: id, task: task, continuation: continuation)
    }

    private func receive(
        id: UUID,
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<MihomoStreamEvent>.Continuation
    ) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else {
                continuation.finish()
                return
            }
            Task {
                await self.handle(
                    result,
                    id: id,
                    task: task,
                    continuation: continuation
                )
            }
        }
    }

    private func handle(
        _ result: Result<URLSessionWebSocketTask.Message, Error>,
        id: UUID,
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<MihomoStreamEvent>.Continuation
    ) {
        guard !isStopped, tasks[id] === task else {
            continuation.finish()
            return
        }

        switch result {
        case .success(let message):
            switch message {
            case .data(let data):
                continuation.yield(.raw(data))
            case .string(let text):
                if let event = Self.decodeEvent(text: text) {
                    continuation.yield(event)
                } else {
                    continuation.yield(.raw(Data(text.utf8)))
                }
            @unknown default:
                break
            }
            receive(id: id, task: task, continuation: continuation)
        case .failure:
            tasks[id] = nil
            continuation.finish()
        }
    }

    private func closeStream(id: UUID) {
        guard let task = tasks.removeValue(forKey: id) else {
            return
        }
        task.cancel(with: .goingAway, reason: nil)
    }

    private static func decodeEvent(text: String) -> MihomoStreamEvent? {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        // The /connections snapshot carries a `connections` array (serialised as `null` when idle).
        // Match on the key's presence so an idle core clears stale rows instead of leaving them.
        if object.keys.contains("connections") {
            let entries = (try? MihomoAPIClient.decodeConnections(from: data)) ?? []
            return .connections(entries)
        }

        if let up = object["up"] as? Int, let down = object["down"] as? Int {
            return .traffic(TrafficSnapshot(uploadPerSecond: up, downloadPerSecond: down))
        }

        if let payload = object["payload"] as? String {
            let level = CoreLogLevel(rawValue: (object["type"] as? String ?? "info").lowercased()) ?? .info
            return .log(CoreLogEntry(level: level, message: Redactor.redact(payload)))
        }
        return nil
    }
}
