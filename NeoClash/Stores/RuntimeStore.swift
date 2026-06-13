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
    public var logs: [CoreLogEntry] = []
    public var mode: RoutingMode = .rule
    public var isSystemProxyEnabled = false
    public var isTUNEnabled = false
    public var coreVersion = "Not running"
    public var diagnosticText = ""

    private let maxLogEntries = 600

    public init() {}

    public func applyProfiles(_ profiles: [ProxyProfile]) {
        self.profiles = profiles
        if activeProfile == nil {
            activeProfile = profiles.first
        }
    }

    public func markStarting() {
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
        self.traffic = traffic
    }

    public func appendLog(level: CoreLogLevel, _ message: String) {
        logs.append(CoreLogEntry(level: level, message: Redactor.redact(message)))
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }
    }

    public static func preview() -> RuntimeStore {
        let store = RuntimeStore()
        store.status = .running(version: "mihomo preview")
        store.coreVersion = "mihomo preview"
        store.traffic = TrafficSnapshot(uploadPerSecond: 42_000, downloadPerSecond: 3_200_000)
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
