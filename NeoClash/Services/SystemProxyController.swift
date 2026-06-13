import Foundation

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

    public init(enabled: Bool, server: String = "", port: Int? = nil) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }
}

public struct ProxyServiceSnapshot: Codable, Equatable, Sendable {
    public var service: String
    public var webProxy: ProxyEndpoint
    public var secureWebProxy: ProxyEndpoint
    public var socksProxy: ProxyEndpoint
    public var bypassDomains: [String]

    public init(
        service: String,
        webProxy: ProxyEndpoint,
        secureWebProxy: ProxyEndpoint,
        socksProxy: ProxyEndpoint,
        bypassDomains: [String] = []
    ) {
        self.service = service
        self.webProxy = webProxy
        self.secureWebProxy = secureWebProxy
        self.socksProxy = socksProxy
        self.bypassDomains = bypassDomains
    }
}

public enum SystemProxyError: Error, Equatable, LocalizedError {
    case noNetworkServices
    case commandFailed([String], Int32, String)

    public var errorDescription: String? {
        switch self {
        case .noNetworkServices:
            "No network services were found."
        case .commandFailed(let arguments, let status, let output):
            "networksetup \(arguments.joined(separator: " ")) failed with status \(status): \(output)"
        }
    }
}

public struct SystemProxyController: Sendable {
    public static let networksetup = "/usr/sbin/networksetup"
    public static let defaultBypassDomains = ["localhost", "127.0.0.1", "*.local"]

    public init() {}

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
        commands += [
            SystemProxyCommand(arguments: ["-setwebproxystate", snapshot.service, snapshot.webProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsecurewebproxystate", snapshot.service, snapshot.secureWebProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxystate", snapshot.service, snapshot.socksProxy.enabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setproxybypassdomains", snapshot.service] + snapshot.bypassDomains)
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
        guard let service = servicePreference(from: try availableServices()) else {
            throw SystemProxyError.noNetworkServices
        }
        return service
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
            default:
                continue
            }
        }

        return ProxyEndpoint(enabled: enabled, server: server, port: port)
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
