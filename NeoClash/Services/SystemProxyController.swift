import Foundation

public struct SystemProxyCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String = "/usr/sbin/networksetup", arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ProxyServiceSnapshot: Codable, Equatable, Sendable {
    public var service: String
    public var webProxyEnabled: Bool
    public var secureWebProxyEnabled: Bool
    public var socksProxyEnabled: Bool
    public var bypassDomains: [String]

    public init(
        service: String,
        webProxyEnabled: Bool,
        secureWebProxyEnabled: Bool,
        socksProxyEnabled: Bool,
        bypassDomains: [String] = []
    ) {
        self.service = service
        self.webProxyEnabled = webProxyEnabled
        self.secureWebProxyEnabled = secureWebProxyEnabled
        self.socksProxyEnabled = socksProxyEnabled
        self.bypassDomains = bypassDomains
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
        [
            SystemProxyCommand(arguments: ["-setwebproxystate", snapshot.service, snapshot.webProxyEnabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsecurewebproxystate", snapshot.service, snapshot.secureWebProxyEnabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setsocksfirewallproxystate", snapshot.service, snapshot.socksProxyEnabled ? "on" : "off"]),
            SystemProxyCommand(arguments: ["-setproxybypassdomains", snapshot.service] + snapshot.bypassDomains)
        ]
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
    }
}

