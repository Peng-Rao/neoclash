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
            controllerHost: controllerHost,
            controllerPort: sanitizedPort(controllerPort, fallback: fallback.controllerPort)
        )
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

public struct RuntimeOverrides: Codable, Equatable, Sendable {
    public var ports: RuntimePorts
    public var mode: RoutingMode
    public var logLevel: String
    public var ipv6: Bool
    public var unifiedDelay: Bool
    public var allowLAN: Bool
    public var allowExternalController: Bool
    public var tun: TUNSettings

    public init(
        ports: RuntimePorts = RuntimePorts(),
        mode: RoutingMode = .rule,
        logLevel: String = "info",
        ipv6: Bool = true,
        unifiedDelay: Bool = true,
        allowLAN: Bool = false,
        allowExternalController: Bool = false,
        tun: TUNSettings = TUNSettings()
    ) {
        self.ports = ports
        self.mode = mode
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.unifiedDelay = unifiedDelay
        self.allowLAN = allowLAN
        self.allowExternalController = allowExternalController
        self.tun = tun
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
