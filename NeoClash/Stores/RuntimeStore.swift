import Foundation
import Observation

@MainActor
@Observable
public final class RuntimeStore {
    public var status: CoreStatus = .stopped
    public var activeProfile: ProxyProfile?
    public var profiles: [ProxyProfile] = []
    public var proxies: [ProxyGroup] = []
    public var connections: [ConnectionEntry] = []
    public var rules: [RuleEntry] = []
    public var traffic: TrafficSnapshot = .zero
    public var trafficHistory: [TrafficSnapshot] = []
    public var sessionUploadBytes = 0
    public var sessionDownloadBytes = 0
    public var coreResource: CoreResourceSnapshot = .empty
    public var networkStatus: NetworkStatusSnapshot = .empty
    public var dailyTraffic: [DailyTrafficSample] = []
    public var logs: [CoreLogEntry] = []
    public var mode: RoutingMode = .rule
    public var isSystemProxyEnabled = false
    public var isTUNEnabled = false
    public var coreVersion = "Not running"
    public var diagnosticText = ""

    private let maxLogEntries = 600
    private let maxTrafficHistoryEntries = 44
    private let maxDailyTrafficDays = 14
    private let calendar: Calendar
    private var previousTraffic: TrafficSnapshot?

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func applyProfiles(_ profiles: [ProxyProfile]) {
        self.profiles = profiles
        if activeProfile == nil {
            activeProfile = profiles.first
        }
    }

    public func markStarting() {
        resetRuntimeMeasurements()
        status = .starting
        appendLog(level: .info, "Starting Mihomo runtime")
    }

    public func markRunning(version: String) {
        status = .running(version: version)
        coreVersion = version
        appendLog(level: .info, "Mihomo runtime is ready: \(version)")
    }

    public func markStopped() {
        status = .stopped
        coreVersion = "Not running"
        traffic = .zero
        resetRuntimeMeasurements()
        connections = []
        rules = []
        appendLog(level: .info, "Runtime stopped")
    }

    public func markCrashed(_ message: String, diagnostics: String = "") {
        status = .crashed(message: message)
        diagnosticText = Redactor.redact(diagnostics.isEmpty ? message : diagnostics)
        appendLog(level: .error, message)
    }

    public func reportError(_ message: String, diagnostics: String = "") {
        diagnosticText = Redactor.redact(diagnostics.isEmpty ? message : diagnostics)
        appendLog(level: .error, message)
    }

    public func update(proxies: [ProxyGroup]) {
        self.proxies = proxies
    }

    public func update(connections: [ConnectionEntry]) {
        self.connections = connections
    }

    public func update(rules: [RuleEntry]) {
        self.rules = rules
    }

    public func update(traffic: TrafficSnapshot) {
        if let previousTraffic {
            let elapsed = max(0, min(traffic.timestamp.timeIntervalSince(previousTraffic.timestamp), 5))
            let uploadDelta = Int((Double(previousTraffic.uploadPerSecond + traffic.uploadPerSecond) / 2 * elapsed).rounded())
            let downloadDelta = Int((Double(previousTraffic.downloadPerSecond + traffic.downloadPerSecond) / 2 * elapsed).rounded())
            sessionUploadBytes += uploadDelta
            sessionDownloadBytes += downloadDelta
            accumulateDailyTraffic(uploadDelta: uploadDelta, downloadDelta: downloadDelta, at: traffic.timestamp)
        }
        previousTraffic = traffic
        self.traffic = traffic
        trafficHistory.append(traffic)
        if trafficHistory.count > maxTrafficHistoryEntries {
            trafficHistory.removeFirst(trafficHistory.count - maxTrafficHistoryEntries)
        }
    }

    /// Seeds persisted day-bucketed traffic totals (oldest→newest) restored from disk at launch.
    public func seedDailyTraffic(_ samples: [DailyTrafficSample]) {
        dailyTraffic = trimmedDailyTraffic(samples)
    }

    /// The last `count` calendar days (oldest→newest), zero-filled for days without recorded traffic.
    public func recentDailyTraffic(days count: Int = 7, now: Date = Date()) -> [DailyTrafficSample] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return dailyTraffic.first { calendar.isDate($0.date, inSameDayAs: day) }
                ?? DailyTrafficSample(date: day)
        }
    }

    private func accumulateDailyTraffic(uploadDelta: Int, downloadDelta: Int, at timestamp: Date) {
        guard uploadDelta > 0 || downloadDelta > 0 else {
            return
        }
        let day = calendar.startOfDay(for: timestamp)
        if let index = dailyTraffic.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            dailyTraffic[index].uploadBytes += uploadDelta
            dailyTraffic[index].downloadBytes += downloadDelta
        } else {
            dailyTraffic.append(DailyTrafficSample(date: day, downloadBytes: downloadDelta, uploadBytes: uploadDelta))
            dailyTraffic = trimmedDailyTraffic(dailyTraffic)
        }
    }

    private func trimmedDailyTraffic(_ samples: [DailyTrafficSample]) -> [DailyTrafficSample] {
        let sorted = samples.sorted { $0.date < $1.date }
        if sorted.count > maxDailyTrafficDays {
            return Array(sorted.suffix(maxDailyTrafficDays))
        }
        return sorted
    }

    public func update(coreResource: CoreResourceSnapshot) {
        self.coreResource = coreResource
    }

    public func update(networkStatus: NetworkStatusSnapshot) {
        self.networkStatus = networkStatus
    }

    public func appendLog(level: CoreLogLevel, _ message: String) {
        logs.append(CoreLogEntry(level: level, message: Redactor.redact(message)))
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
    }

    private func resetRuntimeMeasurements() {
        traffic = .zero
        trafficHistory = []
        sessionUploadBytes = 0
        sessionDownloadBytes = 0
        coreResource = .empty
        previousTraffic = nil
    }

    public static func preview() -> RuntimeStore {
        let store = RuntimeStore()
        store.status = .running(version: "mihomo preview")
        store.coreVersion = "mihomo preview"
        store.traffic = TrafficSnapshot(uploadPerSecond: 42_000, downloadPerSecond: 3_200_000)
        store.networkStatus = NetworkStatusSnapshot(
            internetLatencyMS: 42,
            dnsLatencyMS: 11,
            routerLatencyMS: 2,
            interfaceName: "en0",
            interfaceKind: .wifi,
            serviceName: "Wi-Fi",
            wifiSSID: "Studio",
            wifiBand: "5GHz",
            localIPAddress: "192.168.1.41",
            routerIPAddress: "192.168.1.1",
            egressIPAddress: "18.163.12.249",
            egressCountryCode: "HK",
            updatedAt: Date()
        )
        store.proxies = [
            ProxyGroup(
                name: "Proxy",
                type: "Selector",
                now: "Tokyo 01",
                nodes: [
                    ProxyNode(name: "Tokyo 01", type: "Hysteria2", delay: 42, isSelected: true),
                    ProxyNode(name: "Singapore 02", type: "Trojan", delay: 88),
                    ProxyNode(name: "Los Angeles 03", type: "VLESS", delay: nil)
                ]
            ),
            ProxyGroup(
                name: "Streaming",
                type: "URLTest",
                now: "Singapore 02",
                nodes: [
                    ProxyNode(name: "Singapore 02", type: "Trojan", delay: 72, isSelected: true),
                    ProxyNode(name: "Tokyo 01", type: "Hysteria2", delay: 91)
                ]
            )
        ]
        store.connections = [
            ConnectionEntry(id: "1", host: "example.com", rule: "DOMAIN-SUFFIX", chain: ["Proxy", "Tokyo 01"], upload: 2_048, download: 98_304, process: "Safari"),
            ConnectionEntry(id: "2", host: "api.github.com", rule: "MATCH", chain: ["Proxy", "Singapore 02"], upload: 4_096, download: 180_224, process: "Xcode")
        ]
        store.rules = [
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
            RuleEntry(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            RuleEntry(type: "MATCH", payload: "", proxy: "Proxy")
        ]
        store.logs = [
            CoreLogEntry(level: .info, message: "Runtime ready"),
            CoreLogEntry(level: .warning, message: "Delay test timed out for Los Angeles 03")
        ]
        return store
    }
}
