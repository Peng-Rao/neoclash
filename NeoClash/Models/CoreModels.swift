import Foundation

public enum ProfileKind: String, Codable, CaseIterable, Sendable {
    case localYAML
    case remoteSubscription
}

public struct ProxyProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: ProfileKind
    public var localFileURL: URL
    public var lastUpdatedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProfileKind,
        localFileURL: URL,
        lastUpdatedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localFileURL = localFileURL
        self.lastUpdatedAt = lastUpdatedAt
        self.createdAt = createdAt
    }
}

public enum RoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case rule
    case global
    case direct

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rule: "Rule"
        case .global: "Global"
        case .direct: "Direct"
        }
    }

    public var mihomoValue: String {
        switch self {
        case .rule: "rule"
        case .global: "global"
        case .direct: "direct"
        }
    }
}

public enum NetworkInterfaceKind: String, Codable, Sendable {
    case wifi
    case ethernet
    case tunnel
    case loopback
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .tunnel: "Tunnel"
        case .loopback: "Loopback"
        case .other: "Network"
        case .unknown: "Unknown"
        }
    }
}

public struct NetworkStatusSnapshot: Codable, Equatable, Sendable {
    public var internetLatencyMS: Int?
    public var dnsLatencyMS: Int?
    public var routerLatencyMS: Int?
    public var interfaceName: String?
    public var interfaceKind: NetworkInterfaceKind
    public var serviceName: String?
    public var wifiSSID: String?
    public var wifiBand: String?
    public var localIPAddress: String?
    public var routerIPAddress: String?
    public var egressIPAddress: String?
    public var egressCountryCode: String?
    public var updatedAt: Date?

    public init(
        internetLatencyMS: Int? = nil,
        dnsLatencyMS: Int? = nil,
        routerLatencyMS: Int? = nil,
        interfaceName: String? = nil,
        interfaceKind: NetworkInterfaceKind = .unknown,
        serviceName: String? = nil,
        wifiSSID: String? = nil,
        wifiBand: String? = nil,
        localIPAddress: String? = nil,
        routerIPAddress: String? = nil,
        egressIPAddress: String? = nil,
        egressCountryCode: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.internetLatencyMS = internetLatencyMS
        self.dnsLatencyMS = dnsLatencyMS
        self.routerLatencyMS = routerLatencyMS
        self.interfaceName = interfaceName
        self.interfaceKind = interfaceKind
        self.serviceName = serviceName
        self.wifiSSID = wifiSSID
        self.wifiBand = wifiBand
        self.localIPAddress = localIPAddress
        self.routerIPAddress = routerIPAddress
        self.egressIPAddress = egressIPAddress
        self.egressCountryCode = egressCountryCode
        self.updatedAt = updatedAt
    }

    public static let empty = NetworkStatusSnapshot()
}

public enum CoreStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(version: String)
    case stopping
    case crashed(message: String)

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    public var isCrashed: Bool {
        if case .crashed = self {
            return true
        }
        return false
    }

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .crashed: "Crashed"
        }
    }
}

public struct TrafficSnapshot: Codable, Equatable, Sendable {
    public var uploadPerSecond: Int
    public var downloadPerSecond: Int
    public var timestamp: Date

    public init(uploadPerSecond: Int = 0, downloadPerSecond: Int = 0, timestamp: Date = Date()) {
        self.uploadPerSecond = uploadPerSecond
        self.downloadPerSecond = downloadPerSecond
        self.timestamp = timestamp
    }

    public static let zero = TrafficSnapshot(uploadPerSecond: 0, downloadPerSecond: 0)
}

public struct DailyTrafficSample: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var downloadBytes: Int
    public var uploadBytes: Int
    public var directBytes: Int
    public var proxyBytes: Int

    public var id: Date { date }

    public init(date: Date, downloadBytes: Int = 0, uploadBytes: Int = 0, directBytes: Int = 0, proxyBytes: Int = 0) {
        self.date = date
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.directBytes = directBytes
        self.proxyBytes = proxyBytes
    }

    // Samples persisted before the direct/proxy split existed lack the two new keys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        downloadBytes = try container.decodeIfPresent(Int.self, forKey: .downloadBytes) ?? 0
        uploadBytes = try container.decodeIfPresent(Int.self, forKey: .uploadBytes) ?? 0
        directBytes = try container.decodeIfPresent(Int.self, forKey: .directBytes) ?? 0
        proxyBytes = try container.decodeIfPresent(Int.self, forKey: .proxyBytes) ?? 0
    }

    public var totalBytes: Int { downloadBytes + uploadBytes }
}

/// One clock-hour bucket of measured traffic, used by the Overview timeline's "Today" scale.
public struct HourlyTrafficSample: Codable, Equatable, Sendable, Identifiable {
    /// Start of the clock hour this bucket covers.
    public var date: Date
    public var downloadBytes: Int
    public var uploadBytes: Int

    public var id: Date { date }

    public init(date: Date, downloadBytes: Int = 0, uploadBytes: Int = 0) {
        self.date = date
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    public var totalBytes: Int { downloadBytes + uploadBytes }
}

public struct CoreResourceSnapshot: Codable, Equatable, Sendable {
    public var memoryBytes: Int?
    public var cpuPercent: Double?
    public var timestamp: Date

    public init(memoryBytes: Int? = nil, cpuPercent: Double? = nil, timestamp: Date = Date()) {
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.timestamp = timestamp
    }

    public static let empty = CoreResourceSnapshot()
}

public struct ProxyNode: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var type: String?
    public var delay: Int?
    public var isSelected: Bool

    public init(name: String, type: String? = nil, delay: Int? = nil, isSelected: Bool = false) {
        self.name = name
        self.type = type
        self.delay = delay
        self.isSelected = isSelected
    }
}

public struct ProxyGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var type: String?
    public var now: String?
    public var nodes: [ProxyNode]

    public init(name: String, type: String? = nil, now: String? = nil, nodes: [ProxyNode] = []) {
        self.name = name
        self.type = type
        self.now = now
        self.nodes = nodes
    }
}

public struct ConnectionEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var host: String
    public var rule: String?
    public var rulePayload: String?
    public var chain: [String]
    public var upload: Int
    public var download: Int
    public var process: String?
    public var sourceIP: String?
    public var destinationIP: String?
    /// Inbound listener the flow entered through (e.g. "Mixed", "Socks5", "Tun").
    public var inboundType: String?

    public init(
        id: String,
        host: String,
        rule: String? = nil,
        rulePayload: String? = nil,
        chain: [String] = [],
        upload: Int = 0,
        download: Int = 0,
        process: String? = nil,
        sourceIP: String? = nil,
        destinationIP: String? = nil,
        inboundType: String? = nil
    ) {
        self.id = id
        self.host = host
        self.rule = rule
        self.rulePayload = rulePayload
        self.chain = chain
        self.upload = upload
        self.download = download
        self.process = process
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.inboundType = inboundType
    }

    /// True when the flow bypassed the proxy chain entirely.
    public var isDirect: Bool {
        chain.isEmpty || chain.allSatisfy { $0.caseInsensitiveCompare("DIRECT") == .orderedSame }
    }

    /// The exit node that actually carried the flow (mihomo lists it first in the chain).
    public var exitNode: String {
        chain.first ?? "DIRECT"
    }
}

/// One named row of a ranked "top usage" list (rules, domains, nodes, …).
public struct RankedStat: Identifiable, Equatable, Sendable {
    public var name: String
    public var bytes: Int

    public var id: String { name }

    public init(name: String, bytes: Int) {
        self.name = name
        self.bytes = bytes
    }
}

/// Session-cumulative traffic totals keyed by the dimensions the Overview breaks down:
/// matched rule, destination domain, exit node, client source, inbound listener, and
/// target country. Fed by per-connection byte deltas as connection snapshots stream in.
public struct ConnectionStats: Equatable, Sendable {
    public var byRule: [String: Int] = [:]
    public var byDomain: [String: Int] = [:]
    public var byNode: [String: Int] = [:]
    public var bySource: [String: Int] = [:]
    public var byInbound: [String: Int] = [:]
    public var byCountry: [String: Int] = [:]
    public var directBytes = 0
    public var proxyBytes = 0
    /// Every destination host observed this session, even ones that never moved bytes.
    public var seenDestinations: Set<String> = []
    /// Connections that have come and gone this session.
    public var closedCount = 0

    public init() {}

    public static func ranked(_ totals: [String: Int], limit: Int = 6) -> [RankedStat] {
        totals
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { RankedStat(name: $0.key, bytes: $0.value) }
    }
}

public struct RuleEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var type: String
    public var payload: String
    public var proxy: String

    public init(id: UUID = UUID(), type: String, payload: String, proxy: String) {
        self.id = id
        self.type = type
        self.payload = payload
        self.proxy = proxy
    }

    public var displayText: String {
        [type, payload, proxy]
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }
}

public enum CoreLogLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case debug
    case info
    case warning
    case error

    public var id: String { rawValue }
}

public struct CoreLogEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: CoreLogLevel
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), level: CoreLogLevel, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}
