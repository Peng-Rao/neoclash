import Foundation

public struct RuntimePorts: Codable, Equatable, Sendable {
    public var mixedPort: Int
    public var controllerHost: String
    public var controllerPort: Int

    public init(mixedPort: Int = 7897, controllerHost: String = "127.0.0.1", controllerPort: Int = 9097) {
        self.mixedPort = mixedPort
        self.controllerHost = controllerHost
        self.controllerPort = controllerPort
    }

    public static func sanitizing(
        mixedPort: Int,
        controllerHost: String = "127.0.0.1",
        controllerPort: Int,
        fallback: RuntimePorts = RuntimePorts()
    ) -> RuntimePorts {
        RuntimePorts(
            mixedPort: sanitizedPort(mixedPort, fallback: fallback.mixedPort),
            controllerHost: normalizedControllerHost(controllerHost),
            controllerPort: sanitizedPort(controllerPort, fallback: fallback.controllerPort)
        )
    }

    /// Normalizes controller aliases before they are passed to socket and URL APIs. Resolving
    /// `localhost` through DNS can choose IPv6 on one call and IPv4 on another, so use an explicit
    /// loopback address. Brackets are endpoint syntax rather than part of an IPv6 host and are
    /// stripped here before feeding the value to `URLComponents` or `getaddrinfo`.
    public static func normalizedControllerHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketed: String
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
            unbracketed = String(trimmed.dropFirst().dropLast())
        } else {
            unbracketed = trimmed
        }
        return unbracketed.caseInsensitiveCompare("localhost") == .orderedSame
            ? "127.0.0.1"
            : unbracketed
    }

    /// Formats a host and port for Mihomo's `external-controller` setting, including the brackets
    /// required around IPv6 literals.
    public static func controllerEndpoint(host: String, port: Int) -> String {
        let normalizedHost = normalizedControllerHost(host)
        if normalizedHost.contains(":") {
            return "[\(normalizedHost)]:\(port)"
        }
        return "\(normalizedHost):\(port)"
    }

    private static func sanitizedPort(_ port: Int, fallback: Int) -> Int {
        (1...65_535).contains(port) ? port : fallback
    }
}

public struct TUNSettings: Codable, Equatable, Sendable {
    public static let defaultStack = "gvisor"
    public static let supportedStacks = ["system", "gvisor", "mixed"]

    public var isEnabled: Bool
    public var stack: String
    public var mtu: Int
    public var autoRoute: Bool

    public init(isEnabled: Bool = false, stack: String = defaultStack, mtu: Int = 9000, autoRoute: Bool = true) {
        self.isEnabled = isEnabled
        self.stack = Self.normalizedStack(stack) ?? Self.defaultStack
        self.mtu = mtu
        self.autoRoute = autoRoute
    }

    public static func normalizedStack(_ stack: String) -> String? {
        let normalized = stack.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedStacks.contains(normalized) ? normalized : nil
    }
}

/// The addresses NEPacketTunnelProvider assigns to the tunnel. They sit in the default fake-ip
/// range so the core's DNS hijack sees every lookup the system sends to `dnsServer`.
public enum PacketTunnelNetwork {
    public static let address = "198.18.0.1"
    public static let subnetMask = "255.255.0.0"
    public static let dnsServer = "198.18.0.2"
    /// Matches mihomo's default tun inet6-address.
    public static let ipv6Address = "fdfe:dcba:9876::1"
    public static let ipv6PrefixLength = 126
    public static let mtu = 1_500
}

/// Where the core runs. iOS hosts it in-process, so desktop assumptions about owning the network
/// stack and having memory to spare do not hold there.
public enum RuntimePlatform: String, Codable, Equatable, Sendable {
    case desktop
    /// Inside NEPacketTunnelProvider, which owns the routes and the utun device.
    case iosTunnel
    /// Inside the app process, with no TUN device.
    case iosLocal
}

public struct RuntimeOverrides: Codable, Equatable, Sendable {
    public var ports: RuntimePorts
    public var mode: RoutingMode
    public var logLevel: String
    public var ipv6: Bool
    public var unifiedDelay: Bool
    public var allowLAN: Bool
    public var allowExternalController: Bool
    public var tun: TUNSettings
    public var platform: RuntimePlatform

    public init(
        ports: RuntimePorts = RuntimePorts(),
        mode: RoutingMode = .rule,
        logLevel: String = "info",
        ipv6: Bool = true,
        unifiedDelay: Bool = true,
        allowLAN: Bool = false,
        allowExternalController: Bool = false,
        tun: TUNSettings = TUNSettings(),
        platform: RuntimePlatform = .desktop
    ) {
        self.ports = ports
        self.mode = mode
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.unifiedDelay = unifiedDelay
        self.allowLAN = allowLAN
        self.allowExternalController = allowExternalController
        self.tun = tun
        self.platform = platform
    }
}

public struct RuntimeIdentity: Codable, Equatable, Sendable {
    public var secret: String

    public init(secret: String = RuntimeIdentity.generateSecret()) {
        self.secret = secret
    }

    public static func generateSecret(byteCount: Int = 32) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return Data(bytes).base64EncodedString()
    }
}
