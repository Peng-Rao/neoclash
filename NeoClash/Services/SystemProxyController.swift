import Foundation
import SystemConfiguration

public struct SystemProxyCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/sbin/networksetup", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var server: String
    public var port: Int?
    public var authenticated: Bool

    public init(enabled: Bool, server: String = "", port: Int? = nil, authenticated: Bool = false) {
        self.enabled = enabled
        self.server = server
        self.port = port
        self.authenticated = authenticated
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case server
        case port
        case authenticated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        authenticated = try container.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
    }
}

public struct ProxyServiceSnapshot: Codable, Equatable, Sendable {
    public var service: String
    public var webProxy: ProxyEndpoint
    public var secureWebProxy: ProxyEndpoint
    public var socksProxy: ProxyEndpoint
    public var bypassDomains: [String]
    /// The NeoClash mixed port that replaced these original settings. Optional for backward
    /// compatibility with recovery files written before the field existed.
    public var managedLoopbackPort: Int?

    public init(
        service: String,
        webProxy: ProxyEndpoint,
        secureWebProxy: ProxyEndpoint,
        socksProxy: ProxyEndpoint,
        bypassDomains: [String] = [],
        managedLoopbackPort: Int? = nil
    ) {
        self.service = service
        self.webProxy = webProxy
        self.secureWebProxy = secureWebProxy
        self.socksProxy = socksProxy
        self.bypassDomains = bypassDomains
        self.managedLoopbackPort = managedLoopbackPort
    }

    public var hasEnabledAuthenticatedProxy: Bool {
        // networksetup cannot reveal credentials for restoration. Even a currently disabled
        // authenticated endpoint must be preserved untouched because enabling it later depends on
        // authentication state that a NeoClash snapshot cannot reproduce.
        [webProxy, secureWebProxy, socksProxy].contains { $0.authenticated }
    }
}

public enum SystemProxyError: Error, Equatable, LocalizedError {
    case noNetworkServices
    case authenticatedProxyCannotBeOverwritten(String)
    case commandFailed([String], Int32, String)

    public var errorDescription: String? {
        switch self {
        case .noNetworkServices:
            "No network services were found."
        case .authenticatedProxyCannotBeOverwritten(let service):
            "The \(service) service uses an authenticated proxy that NeoClash cannot safely preserve."
        case .commandFailed(let arguments, let status, let output):
            "networksetup \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        }
    }
}

public struct SystemProxyController: Sendable {
    public static let networksetup = "/usr/sbin/networksetup"
    public static let defaultBypassDomains = ["localhost", "127.0.0.1", "*.local"]
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "0.0.0.0", "localhost"]

    public init() {}

    /// True when the server is a loopback address — i.e. a proxy we (or another local tool) set to
    /// point at a core on this machine.
    public static func isLoopback(_ server: String) -> Bool {
        loopbackHosts.contains(server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The port of the first enabled loopback proxy in the snapshot, if any. Used to detect a system
    /// proxy left pointing at a local core after a crash.
    public static func loopbackProxyPort(_ snapshot: ProxyServiceSnapshot) -> Int? {
        for endpoint in [snapshot.webProxy, snapshot.secureWebProxy, snapshot.socksProxy] {
            if endpoint.enabled, isLoopback(endpoint.server), let port = endpoint.port {
                return port
            }
        }
        return nil
    }

    /// True even while the proxy state is off. NeoClash intentionally turns its endpoints off for
    /// Wi-Fi suppression, so crash recovery must still recognize the configured loopback address.
    public static func hasLoopbackConfiguration(
        _ snapshot: ProxyServiceSnapshot,
        port expectedPort: Int? = nil
    ) -> Bool {
        [snapshot.webProxy, snapshot.secureWebProxy, snapshot.socksProxy].contains { endpoint in
            guard let port = endpoint.port, (1...65_535).contains(port) else {
                return false
            }
            if let expectedPort, port != expectedPort {
                return false
            }
            return isLoopback(endpoint.server)
        }
    }

    /// NeoClash writes exactly this endpoint shape. Loopback aliases (localhost/::1/0.0.0.0) and
    /// authenticated endpoints may belong to another local proxy and are not proof of ownership.
    public static func isManagedEndpoint(_ endpoint: ProxyEndpoint, port: Int) -> Bool {
        endpoint.server.trimmingCharacters(in: .whitespacesAndNewlines) == "127.0.0.1"
            && endpoint.port == port
            && !endpoint.authenticated
    }

    public static func hasEnabledManagedEndpoint(_ snapshot: ProxyServiceSnapshot, port: Int) -> Bool {
        [snapshot.webProxy, snapshot.secureWebProxy, snapshot.socksProxy].contains {
            $0.enabled && isManagedEndpoint($0, port: port)
        }
    }

    /// Determines whether a crash-recovery snapshot still owns the live service. A partial
    /// `networksetup` sequence can leave some endpoints changed and others untouched, so require
    /// every live field to be either NeoClash's exact signature or the persisted original value.
    /// Any third-party/user change makes the live state authoritative and prevents restoration.
    public static func canRestorePersistedSnapshot(
        _ original: ProxyServiceSnapshot,
        from current: ProxyServiceSnapshot,
        neoClashPort: Int
    ) -> Bool {
        guard original.service == current.service else {
            return false
        }

        let pairs = [
            (current.webProxy, original.webProxy),
            (current.secureWebProxy, original.secureWebProxy),
            (current.socksProxy, original.socksProxy)
        ]
        guard pairs.contains(where: { isManagedEndpoint($0.0, port: neoClashPort) }),
              pairs.allSatisfy({ isManagedEndpoint($0.0, port: neoClashPort) || $0.0 == $0.1 }) else {
            return false
        }

        func normalizedDomains(_ domains: [String]) -> Set<String> {
            Set(domains.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
        }
        let currentBypass = normalizedDomains(current.bypassDomains)
        return currentBypass == normalizedDomains(original.bypassDomains)
            || currentBypass == normalizedDomains(defaultBypassDomains)
    }

    public static func validateCanOverwrite(_ snapshot: ProxyServiceSnapshot) throws {
        guard !snapshot.hasEnabledAuthenticatedProxy else {
            throw SystemProxyError.authenticatedProxyCannotBeOverwritten(snapshot.service)
        }
    }

    /// Treats loopback-pointing endpoints as disabled so a later restore never re-points the system
    /// proxy at our own (possibly dead) local core. Prevents the snapshot from "restoring" a proxy we
    /// ourselves set on a previous run.
    public static func sanitizingLoopback(_ snapshot: ProxyServiceSnapshot) -> ProxyServiceSnapshot {
        func cleaned(_ endpoint: ProxyEndpoint) -> ProxyEndpoint {
            endpoint.enabled && isLoopback(endpoint.server) ? ProxyEndpoint(enabled: false) : endpoint
        }
        return ProxyServiceSnapshot(
            service: snapshot.service,
            webProxy: cleaned(snapshot.webProxy),
            secureWebProxy: cleaned(snapshot.secureWebProxy),
            socksProxy: cleaned(snapshot.socksProxy),
            bypassDomains: snapshot.bypassDomains
        )
    }

    public func disableCommands(service: String) -> [SystemProxyCommand] {
        [
            SystemProxyCommand(arguments: ["-setwebproxystate", service, "off"]),
            SystemProxyCommand(arguments: ["-setsecurewebproxystate", service, "off"]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxystate", service, "off"])
        ]
    }

    public func disableAll(service: String) throws {
        for command in disableCommands(service: service) {
            try run(command)
        }
    }

    /// Disables only endpoints that still match NeoClash's loopback port. A network service may
    /// contain a mixture of proxy kinds; disabling all three because one matches would turn off a
    /// corporate or user-managed endpoint that changed after NeoClash crashed.
    public func disableMatchingLoopback(service: String, port: Int) throws -> Bool {
        let commands = Self.disableMatchingLoopbackCommands(snapshot: try snapshot(service: service), port: port)
        for command in commands {
            try run(command)
        }
        return !commands.isEmpty
    }

    public static func disableMatchingLoopbackCommands(
        snapshot: ProxyServiceSnapshot,
        port: Int
    ) -> [SystemProxyCommand] {
        let endpoints: [(ProxyEndpoint, String)] = [
            (snapshot.webProxy, "-setwebproxystate"),
            (snapshot.secureWebProxy, "-setsecurewebproxystate"),
            (snapshot.socksProxy, "-setsocksfirewallproxystate")
        ]
        return endpoints.compactMap { endpoint, command in
            guard endpoint.enabled, isManagedEndpoint(endpoint, port: port) else {
                return nil
            }
            return SystemProxyCommand(arguments: [command, snapshot.service, "off"])
        }
    }

    public func enableCommands(service: String, host: String, port: Int) -> [SystemProxyCommand] {
        [
            SystemProxyCommand(arguments: ["-setwebproxy", service, host, String(port)]),
            SystemProxyCommand(arguments: ["-setsecurewebproxy", service, host, String(port)]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxy", service, host, String(port)]),
            SystemProxyCommand(arguments: ["-setwebproxystate", service, "on"]),
            SystemProxyCommand(arguments: ["-setsecurewebproxystate", service, "on"]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxystate", service, "on"]),
            SystemProxyCommand(arguments: ["-setproxybypassdomains", service] + Self.defaultBypassDomains)
        ]
    }

    public func restoreCommands(snapshot: ProxyServiceSnapshot) -> [SystemProxyCommand] {
        var commands: [SystemProxyCommand] = []
        if let command = restoreCommand(kind: .web, service: snapshot.service, endpoint: snapshot.webProxy) {
            commands.append(command)
        }
        if let command = restoreCommand(kind: .secureWeb, service: snapshot.service, endpoint: snapshot.secureWebProxy) {
            commands.append(command)
        }
        if let command = restoreCommand(kind: .socks, service: snapshot.service, endpoint: snapshot.socksProxy) {
            commands.append(command)
        }
        let bypassDomains = snapshot.bypassDomains.isEmpty ? ["Empty"] : snapshot.bypassDomains
        commands += [
            SystemProxyCommand(arguments: ["-setwebproxystate", snapshot.service, snapshot.webProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsecurewebproxystate", snapshot.service, snapshot.secureWebProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxystate", snapshot.service, snapshot.socksProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setproxybypassdomains", snapshot.service] + bypassDomains)
        ]
        return commands
    }

    public func servicePreference(from services: [String]) -> String? {
        if services.contains("Wi-Fi") {
            return "Wi-Fi"
        }
        if services.contains("Ethernet") {
            return "Ethernet"
        }
        return services.first
    }

    public func run(_ command: SystemProxyCommand) throws {
        _ = try runAndCapture(command)
    }

    public func availableServices() throws -> [String] {
        let output = try runAndCapture(SystemProxyCommand(arguments: ["-listallnetworkservices"]))
        return output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .dropFirst()
            .filter { !$0.hasPrefix("*") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func selectedService() throws -> String {
        if let service = try activeService() {
            return service
        }
        guard let service = servicePreference(from: try availableServices()) else {
            throw SystemProxyError.noNetworkServices
        }
        return service
    }

    public func activeService() throws -> String? {
        guard let interfaceName = Self.primaryIPv4InterfaceName() else {
            return nil
        }
        let output = try runAndCapture(SystemProxyCommand(arguments: ["-listnetworkserviceorder"]))
        return Self.parseNetworkServiceOrder(output, interfaceName: interfaceName)
    }

    public func snapshot(service: String) throws -> ProxyServiceSnapshot {
        ProxyServiceSnapshot(
            service: service,
            webProxy: Self.parseProxyState(try runAndCapture(SystemProxyCommand(arguments: ["-getwebproxy", service]))),
            secureWebProxy: Self.parseProxyState(try runAndCapture(SystemProxyCommand(arguments: ["-getsecurewebproxy", service]))),
            socksProxy: Self.parseProxyState(try runAndCapture(SystemProxyCommand(arguments: ["-getsocksfirewallproxy", service]))),
            bypassDomains: Self.parseBypassDomains(try runAndCapture(SystemProxyCommand(arguments: ["-getproxybypassdomains", service])))
        )
    }

    public func enable(service: String, host: String, port: Int) throws {
        for command in enableCommands(service: service, host: host, port: port) {
            try run(command)
        }
    }

    public func restore(snapshot: ProxyServiceSnapshot) throws {
        for command in restoreCommands(snapshot: snapshot) {
            try run(command)
        }
    }

    public static func parseProxyState(_ output: String) -> ProxyEndpoint {
        var enabled = false
        var server = ""
        var port: Int?
        var authenticated = false

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else {
                continue
            }
            switch parts[0].lowercased() {
            case "enabled":
                enabled = ["yes", "1", "on", "true"].contains(parts[1].lowercased())
            case "server":
                server = parts[1]
            case "port":
                port = Int(parts[1])
            case "authenticated proxy enabled":
                authenticated = ["yes", "1", "on", "true"].contains(parts[1].lowercased())
            default:
                continue
            }
        }

        return ProxyEndpoint(enabled: enabled, server: server, port: port, authenticated: authenticated)
    }

    public static func parseBypassDomains(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveContains("There aren't any bypass domains") {
            return []
        }

        return trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("bypass domains") }
    }

    public static func primaryIPv4InterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "NeoClashSystemProxy" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return value["PrimaryInterface"] as? String
    }

    public static func parseNetworkServiceOrder(_ output: String, interfaceName: String) -> String? {
        var currentService: String?

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("("), !trimmed.localizedCaseInsensitiveContains("Hardware Port:") {
                guard let closeParen = trimmed.firstIndex(of: ")") else {
                    continue
                }
                let service = trimmed[trimmed.index(after: closeParen)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !service.isEmpty {
                    currentService = service
                }
                continue
            }

            guard trimmed.localizedCaseInsensitiveContains("Device:") else {
                continue
            }
            let device = trimmed
                .components(separatedBy: "Device:")
                .last?
                .replacingOccurrences(of: ")", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if device == interfaceName {
                return currentService
            }
        }

        return nil
    }

    private enum ProxyKind {
        case web
        case secureWeb
        case socks
    }

    private func restoreCommand(kind: ProxyKind, service: String, endpoint: ProxyEndpoint) -> SystemProxyCommand? {
        guard let port = endpoint.port, !endpoint.server.isEmpty else {
            return nil
        }
        switch kind {
        case .web:
            return SystemProxyCommand(arguments: ["-setwebproxy", service, endpoint.server, String(port)])
        case .secureWeb:
            return SystemProxyCommand(arguments: ["-setsecurewebproxy", service, endpoint.server, String(port)])
        case .socks:
            return SystemProxyCommand(arguments: ["-setsocksfirewallproxy", service, endpoint.server, String(port)])
        }
    }

    private func runAndCapture(_ command: SystemProxyCommand) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SystemProxyError.commandFailed(command.arguments, process.terminationStatus, output)
        }
        return output
    }
}
