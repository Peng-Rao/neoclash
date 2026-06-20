import Foundation

public enum MihomoStreamEvent: Equatable, Sendable {
    case traffic(TrafficSnapshot)
    case log(CoreLogEntry)
    case connections([ConnectionEntry])
    case raw(Data)
}

public actor MihomoWebSocketClient {
    private let baseURL: URL
    private let secret: String
    private let session: URLSession
    private var tasks: [URLSessionWebSocketTask] = []

    public init(host: String, port: Int, secret: String, session: URLSession? = nil) {
        self.baseURL = URL(string: "ws://\(host):\(port)")!
        self.secret = secret
        self.session = session ?? URLSession(configuration: .default)
    }

    public func stop() {
        tasks.forEach { $0.cancel(with: .goingAway, reason: nil) }
        tasks.removeAll()
    }

    public func stream(path: String) -> AsyncStream<MihomoStreamEvent> {
        AsyncStream { continuation in
            self.open(path: path, continuation: continuation)
        }
    }

    private func open(path: String, continuation: AsyncStream<MihomoStreamEvent>.Continuation) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = path.hasPrefix("/") ? path : "/" + path
        guard let url = components?.url else {
            continuation.finish()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        tasks.append(task)
        task.resume()
        receive(task: task, continuation: continuation)
    }

    private func receive(task: URLSessionWebSocketTask, continuation: AsyncStream<MihomoStreamEvent>.Continuation) {
        task.receive { [weak task] result in
            guard let task else {
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
                Task { await self.receive(task: task, continuation: continuation) }
            case .failure:
                continuation.finish()
            }
        }
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
