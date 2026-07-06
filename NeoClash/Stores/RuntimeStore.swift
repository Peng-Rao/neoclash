import Foundation
import Observation

@MainActor
@Observable
public final class RuntimeStore {
    public var status: CoreStatus = .stopped
    public var activeProfile: ProxyProfile?
    public var profiles: [ProxyProfile] = []
    public var proxies: [ProxyGroup] = []
    public private(set) var isProxyPreview = false
    public var connections: [ConnectionEntry] = []
    public var rules: [RuleEntry] = []
    public var traffic: TrafficSnapshot = .zero
    public var trafficHistory: [TrafficSnapshot] = []
    public var sessionUploadBytes = 0
    public var sessionDownloadBytes = 0
    public var coreResource: CoreResourceSnapshot = .empty
    public var networkStatus: NetworkStatusSnapshot = .empty
    public var dailyTraffic: [DailyTrafficSample] = []
    public var hourlyTraffic: [HourlyTrafficSample] = []
    public private(set) var connectionStats = ConnectionStats()
    public var logs: [CoreLogEntry] = []
    public var mode: RoutingMode = .rule
    public var isSystemProxyEnabled = false
    public var isTUNEnabled = false
    public var coreVersion = "Not running"
    public var coreStartedAt: Date?
    public var diagnosticText = ""
    public private(set) var isTestingDelays = false
    public private(set) var testingDelayNodeNames: Set<String> = []
    public private(set) var delayTestCompletedCount = 0
    public private(set) var delayTestTotalCount = 0

    private let maxLogEntries = 600
    private let maxTrafficHistoryEntries = 44
    private let maxDailyTrafficDays = 31
    private let maxHourlyTrafficHours = 48
    private let calendar: Calendar
    private var previousTraffic: TrafficSnapshot?
    /// Last observed cumulative byte count per connection id, for delta attribution.
    private var connectionByteBaseline: [String: Int] = [:]

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
        coreStartedAt = Date()
        appendLog(level: .info, "Mihomo runtime is ready: \(version)")
    }

    public func markStopped() {
        status = .stopped
        coreVersion = "Not running"
        coreStartedAt = nil
        traffic = .zero
        resetRuntimeMeasurements()
        proxies = []
        isProxyPreview = false
        connections = []
        rules = []
        appendLog(level: .info, "Runtime stopped")
    }

    public func markCrashed(_ message: String, diagnostics: String = "") {
        status = .crashed(message: message)
        coreStartedAt = nil
        diagnosticText = Redactor.redact(diagnostics.isEmpty ? message : diagnostics)
        appendLog(level: .error, message)
    }

    public func reportError(_ message: String, diagnostics: String = "") {
        diagnosticText = Redactor.redact(diagnostics.isEmpty ? message : diagnostics)
        appendLog(level: .error, message)
    }

    public func update(proxies: [ProxyGroup]) {
        self.proxies = proxies
        isProxyPreview = false
    }

    /// Shows a profile-parsed snapshot while the core is stopped so nodes stay browsable and
    /// TCP-testable; replaced wholesale by live data on the next core start.
    public func updatePreviewProxies(_ groups: [ProxyGroup]) {
        guard !status.isRunning else {
            return
        }
        proxies = groups
        isProxyPreview = true
    }

    public func beginDelayTest(nodeNames: [String]) {
        let names = Set(nodeNames)
        guard !names.isEmpty else {
            finishDelayTest()
            return
        }

        isTestingDelays = true
        testingDelayNodeNames = names
        delayTestCompletedCount = 0
        delayTestTotalCount = names.count
    }

    public func recordDelayTestResult(name: String, delay: Int?) {
        var groups = proxies
        for groupIndex in groups.indices {
            for nodeIndex in groups[groupIndex].nodes.indices where groups[groupIndex].nodes[nodeIndex].name == name {
                groups[groupIndex].nodes[nodeIndex].delay = delay
            }
        }
        proxies = groups

        if testingDelayNodeNames.remove(name) != nil {
            delayTestCompletedCount = min(delayTestCompletedCount + 1, delayTestTotalCount)
        }
    }

    public func finishDelayTest() {
        isTestingDelays = false
        testingDelayNodeNames = []
        delayTestCompletedCount = 0
        delayTestTotalCount = 0
    }

    public func update(connections: [ConnectionEntry]) {
        accumulateConnectionStats(connections)
        self.connections = connections
    }

    /// Attributes each connection's byte growth since the previous snapshot to the
    /// Overview breakdowns, and folds the direct/proxy split into today's daily bucket.
    private func accumulateConnectionStats(_ entries: [ConnectionEntry], at timestamp: Date = Date()) {
        var baseline: [String: Int] = [:]
        baseline.reserveCapacity(entries.count)
        var directDelta = 0
        var proxyDelta = 0

        for entry in entries {
            let total = entry.upload + entry.download
            baseline[entry.id] = total
            connectionStats.seenDestinations.insert(entry.host)

            let delta = max(0, total - (connectionByteBaseline[entry.id] ?? 0))
            guard delta > 0 else {
                continue
            }
            if entry.isDirect {
                directDelta += delta
            } else {
                proxyDelta += delta
            }
            connectionStats.byRule[ruleLabel(of: entry), default: 0] += delta
            connectionStats.byDomain[entry.host, default: 0] += delta
            connectionStats.byNode[entry.exitNode, default: 0] += delta
            if let source = entry.sourceIP {
                connectionStats.bySource[source, default: 0] += delta
            }
            if let inbound = entry.inboundType {
                connectionStats.byInbound[inbound, default: 0] += delta
            }
            if let country = targetCountry(of: entry) {
                connectionStats.byCountry[country, default: 0] += delta
            }
        }

        connectionStats.closedCount += connectionByteBaseline.keys.count { baseline[$0] == nil }
        connectionStats.directBytes += directDelta
        connectionStats.proxyBytes += proxyDelta
        connectionByteBaseline = baseline

        if directDelta > 0 || proxyDelta > 0 {
            let day = calendar.startOfDay(for: timestamp)
            if let index = dailyTraffic.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
                dailyTraffic[index].directBytes += directDelta
                dailyTraffic[index].proxyBytes += proxyDelta
            } else {
                dailyTraffic.append(DailyTrafficSample(date: day, directBytes: directDelta, proxyBytes: proxyDelta))
                dailyTraffic = trimmedDailyTraffic(dailyTraffic)
            }
        }
    }

    private func ruleLabel(of entry: ConnectionEntry) -> String {
        guard let rule = entry.rule, !rule.isEmpty else {
            return "MATCH"
        }
        guard let payload = entry.rulePayload else {
            return rule
        }
        return "\(rule) · \(payload)"
    }

    /// Where the flow ultimately lands: the exit node's country for proxied flows,
    /// this machine's egress country for direct ones.
    private func targetCountry(of entry: ConnectionEntry) -> String? {
        if entry.isDirect {
            return networkStatus.egressCountryCode?.uppercased()
        }
        return CountryGuesser.countryCode(for: entry.exitNode)
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
            accumulateHourlyTraffic(uploadDelta: uploadDelta, downloadDelta: downloadDelta, at: traffic.timestamp)
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

    /// Seeds persisted hour-bucketed traffic totals restored from disk at launch.
    public func seedHourlyTraffic(_ samples: [HourlyTrafficSample]) {
        hourlyTraffic = trimmedHourlyTraffic(samples)
    }

    /// Today's 24 clock-hour buckets (00…23), zero-filled for hours without recorded traffic.
    public func todayHourlyTraffic(now: Date = Date()) -> [HourlyTrafficSample] {
        let dayStart = calendar.startOfDay(for: now)
        return (0..<24).map { hour in
            let bucket = calendar.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart
            return hourlyTraffic.first { $0.date == bucket } ?? HourlyTrafficSample(date: bucket)
        }
    }

    private func accumulateHourlyTraffic(uploadDelta: Int, downloadDelta: Int, at timestamp: Date) {
        guard uploadDelta > 0 || downloadDelta > 0 else {
            return
        }
        guard let hour = calendar.dateInterval(of: .hour, for: timestamp)?.start else {
            return
        }
        if let index = hourlyTraffic.firstIndex(where: { $0.date == hour }) {
            hourlyTraffic[index].uploadBytes += uploadDelta
            hourlyTraffic[index].downloadBytes += downloadDelta
        } else {
            hourlyTraffic.append(HourlyTrafficSample(date: hour, downloadBytes: downloadDelta, uploadBytes: uploadDelta))
            hourlyTraffic = trimmedHourlyTraffic(hourlyTraffic)
        }
    }

    private func trimmedHourlyTraffic(_ samples: [HourlyTrafficSample]) -> [HourlyTrafficSample] {
        let sorted = samples.sorted { $0.date < $1.date }
        if sorted.count > maxHourlyTrafficHours {
            return Array(sorted.suffix(maxHourlyTrafficHours))
        }
        return sorted
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
        connectionStats = ConnectionStats()
        connectionByteBaseline = [:]
    }

    public static func preview() -> RuntimeStore {
        let store = RuntimeStore()
        store.status = .running(version: "mihomo preview")
        store.coreVersion = "mihomo preview"
        store.coreStartedAt = Date(timeIntervalSinceNow: -4_520)
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
            ConnectionEntry(id: "1", host: "example.com", rule: "DOMAIN-SUFFIX", rulePayload: "example.com",
                            chain: ["Tokyo 01", "Proxy"], upload: 2_048, download: 98_304, process: "Safari",
                            sourceIP: "127.0.0.1", destinationIP: "93.184.216.34", inboundType: "Mixed"),
            ConnectionEntry(id: "2", host: "api.github.com", rule: "MATCH", rulePayload: nil,
                            chain: ["Singapore 02", "Proxy"], upload: 4_096, download: 180_224, process: "Xcode",
                            sourceIP: "192.168.1.41", destinationIP: "140.82.112.6", inboundType: "Socks5")
        ]
        store.update(connections: store.connections)
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
