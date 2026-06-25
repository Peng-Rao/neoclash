import Foundation

public enum MihomoAPIError: Error, Equatable, LocalizedError {
    case invalidURL
    case badStatus(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Failed to construct Mihomo API URL."
        case .badStatus(let status, let body):
            "Mihomo API returned HTTP \(status): \(Redactor.redact(body))."
        case .invalidResponse:
            "Mihomo API returned an invalid response."
        }
    }
}

public struct MihomoVersion: Codable, Equatable, Sendable {
    public var version: String

    public init(version: String) {
        self.version = version
    }
}

public struct MihomoConfigs: Codable, Equatable, Sendable {
    public var port: Int?
    public var mixedPort: Int?
    public var mode: String?
    public var logLevel: String?

    enum CodingKeys: String, CodingKey {
        case port
        case mixedPort = "mixed-port"
        case mode
        case logLevel = "log-level"
    }
}

public actor MihomoAPIClient {
    public let baseURL: URL
    public let secret: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(host: String, port: Int, secret: String, session: URLSession? = nil) {
        self.baseURL = URL(string: "http://\(host):\(port)")!
        self.secret = secret
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    public func version() async throws -> MihomoVersion {
        try await request(pathSegments: ["version"])
    }

    public func configs() async throws -> MihomoConfigs {
        try await request(pathSegments: ["configs"])
    }

    public func updateMode(_ mode: RoutingMode) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode.mihomoValue])
        _ = try await requestData(pathSegments: ["configs"], method: "PATCH", body: body)
    }

    public func reloadConfig(path: String, force: Bool = true) async throws {
        _ = try await requestData(
            pathSegments: ["configs"],
            queryItems: [
                URLQueryItem(name: "force", value: force ? "true" : "false")
            ],
            method: "PUT",
            body: Data(path.utf8)
        )
    }

    public func proxies() async throws -> [ProxyGroup] {
        let data = try await requestData(pathSegments: ["proxies"])
        return try Self.decodeProxyGroups(from: data)
    }

    public func selectProxy(group: String, proxy: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": proxy])
        _ = try await requestData(pathSegments: ["proxies", group], method: "PUT", body: body)
    }

    public func testDelay(name: String, url: String = "https://www.gstatic.com/generate_204", timeout: Int = 5_000) async -> Int? {
        do {
            let data = try await requestData(
                pathSegments: ["proxies", name, "delay"],
                queryItems: [
                    URLQueryItem(name: "url", value: url),
                    URLQueryItem(name: "timeout", value: String(timeout))
                ]
            )
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["delay"] as? Int
        } catch {
            return nil
        }
    }

    public func rules() async throws -> [RuleEntry] {
        let data = try await requestData(pathSegments: ["rules"])
        return try Self.decodeRules(from: data)
    }

    public func connections() async throws -> [ConnectionEntry] {
        let data = try await requestData(pathSegments: ["connections"])
        return try Self.decodeConnections(from: data)
    }

    public func closeConnection(id: String) async throws {
        _ = try await requestData(pathSegments: ["connections", id], method: "DELETE")
    }

    public func closeAllConnections() async throws {
        _ = try await requestData(pathSegments: ["connections"], method: "DELETE")
    }

    public func providers() async throws -> Data {
        try await requestData(pathSegments: ["providers", "proxies"])
    }

    public func makeURL(pathSegments: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let encodedPath = pathSegments
            .map { Self.percentEncodePathSegment($0) }
            .joined(separator: "/")
        components?.percentEncodedPath = "/" + encodedPath
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw MihomoAPIError.invalidURL
        }
        return url
    }

    private func request<T: Decodable>(
        pathSegments: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        let data = try await requestData(pathSegments: pathSegments, queryItems: queryItems, method: method, body: body)
        return try decoder.decode(T.self, from: data)
    }

    private func requestData(
        pathSegments: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: try makeURL(pathSegments: pathSegments, queryItems: queryItems))
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MihomoAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MihomoAPIError.badStatus(httpResponse.statusCode, body)
        }
        return data
    }

    public static func percentEncodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    public static func decodeProxyGroups(from data: Data) throws -> [ProxyGroup] {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let proxies = object["proxies"] as? [String: [String: Any]]
        else {
            throw MihomoAPIError.invalidResponse
        }

        return proxies.compactMap { name, value in
            guard let all = value["all"] as? [String] else {
                return nil
            }
            let now = value["now"] as? String
            let nodes = all.map { nodeName in
                let node = proxies[nodeName]
                return ProxyNode(
                    name: nodeName,
                    type: node?["type"] as? String,
                    delay: node?["delay"] as? Int,
                    isSelected: nodeName == now
                )
            }
            return ProxyGroup(name: name, type: value["type"] as? String, now: now, nodes: nodes)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func decodeConnections(from data: Data) throws -> [ConnectionEntry] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.invalidResponse
        }
        // Mihomo serialises an empty connection list as `null` (a nil Go slice), so an idle
        // core legitimately returns {"connections": null}. Treat null/missing as empty.
        let connections = object["connections"] as? [[String: Any]] ?? []

        return connections.compactMap { entry in
            guard let id = entry["id"] as? String else {
                return nil
            }
            let metadata = entry["metadata"] as? [String: Any]
            // Mihomo emits absent string fields as "" (not null) and ports as either
            // strings or ints, so read a normalised non-empty value here.
            func meta(_ key: String) -> String? {
                if let value = metadata?[key] as? String { return value.isEmpty ? nil : value }
                if let intValue = metadata?[key] as? Int { return String(intValue) }
                return nil
            }
            // IP-routed flows carry an empty `host`; fall back to the sniffed host,
            // then to destinationIP[:port], so the column is never blank.
            let host: String
            if let domain = meta("host") ?? meta("sniffHost") {
                host = domain
            } else if let ip = meta("destinationIP") {
                host = meta("destinationPort").map { "\(ip):\($0)" } ?? ip
            } else {
                host = "Unknown"
            }
            let chains = entry["chains"] as? [String] ?? []
            let upload = entry["upload"] as? Int ?? 0
            let download = entry["download"] as? Int ?? 0
            return ConnectionEntry(
                id: id,
                host: host,
                rule: entry["rule"] as? String,
                chain: chains,
                upload: upload,
                download: download,
                process: meta("process")
            )
        }
    }

    public static func decodeRules(from data: Data) throws -> [RuleEntry] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.invalidResponse
        }
        let rules = object["rules"] as? [[String: Any]] ?? []

        return rules.map { rule in
            let type = (rule["type"] as? String) ?? (rule["ruleType"] as? String) ?? ""
            let payload = (rule["payload"] as? String) ?? (rule["rule"] as? String) ?? ""
            let proxy = (rule["proxy"] as? String) ?? (rule["adapter"] as? String) ?? ""
            return RuleEntry(type: type, payload: payload, proxy: proxy)
        }
    }
}
