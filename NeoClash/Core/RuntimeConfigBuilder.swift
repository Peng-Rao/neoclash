import Foundation
@preconcurrency import Yams

public enum RuntimeConfigError: Error, Equatable, LocalizedError {
    case invalidYAMLRoot
    case emptySecret
    case invalidPort(Int)
    case publicControllerNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidYAMLRoot:
            "The selected profile is not a YAML mapping."
        case .emptySecret:
            "The runtime controller secret cannot be empty."
        case .invalidPort(let port):
            "Invalid runtime port: \(port)."
        case .publicControllerNotAllowed(let host):
            "External controller host \(host) is not allowed unless external control is enabled."
        }
    }
}

public struct RuntimeConfigBuilder: Sendable {
    public static let directOnlyProfileYAML = """
    proxies: []
    proxy-groups:
      - name: Default
        type: select
        proxies:
          - DIRECT
    rules:
      - MATCH,Default
    """

    public init() {}

    public func build(
        originalYAML: String,
        overrides: RuntimeOverrides = RuntimeOverrides(),
        identity: RuntimeIdentity = RuntimeIdentity()
    ) throws -> String {
        let object = try buildObject(originalYAML: originalYAML, overrides: overrides, identity: identity)
        return try Yams.dump(object: object, width: -1, sortKeys: false)
    }

    public func buildObject(
        originalYAML: String,
        overrides: RuntimeOverrides = RuntimeOverrides(),
        identity: RuntimeIdentity = RuntimeIdentity()
    ) throws -> [String: Any] {
        guard !identity.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeConfigError.emptySecret
        }
        try validate(port: overrides.ports.mixedPort)
        try validate(port: overrides.ports.controllerPort)

        let controllerHost = overrides.ports.controllerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overrides.allowExternalController && !Self.isLoopback(host: controllerHost) {
            throw RuntimeConfigError.publicControllerNotAllowed(controllerHost)
        }

        let loaded = try Yams.load(yaml: originalYAML)
        guard var root = loaded as? [String: Any] else {
            throw RuntimeConfigError.invalidYAMLRoot
        }

        root["mixed-port"] = overrides.ports.mixedPort
        root["external-controller"] = "\(controllerHost):\(overrides.ports.controllerPort)"
        root["secret"] = identity.secret
        root["allow-lan"] = overrides.allowLAN
        root["mode"] = overrides.mode.mihomoValue
        root["log-level"] = overrides.logLevel
        root["ipv6"] = overrides.ipv6
        root["unified-delay"] = overrides.unifiedDelay
        root["geodata-mode"] = true

        if root["dns"] == nil {
            root["dns"] = defaultDNS(ipv6: overrides.ipv6)
        }

        if overrides.tun.isEnabled {
            root["tun"] = tunConfig(settings: overrides.tun)
        } else if var existingTUN = root["tun"] as? [String: Any] {
            existingTUN["enable"] = false
            root["tun"] = existingTUN
        }

        return root
    }

    private func validate(port: Int) throws {
        guard (1...65_535).contains(port) else {
            throw RuntimeConfigError.invalidPort(port)
        }
    }

    private func defaultDNS(ipv6: Bool) -> [String: Any] {
        [
            "enable": true,
            "ipv6": ipv6,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "nameserver": [
                "https://1.1.1.1/dns-query",
                "https://8.8.8.8/dns-query"
            ],
            "fallback": [
                "https://dns.google/dns-query"
            ]
        ]
    }

    private func tunConfig(settings: TUNSettings) -> [String: Any] {
        [
            "enable": true,
            "stack": settings.stack,
            "device": "utun",
            "auto-route": true,
            "strict-route": true,
            "auto-detect-interface": true,
            "dns-hijack": ["any:53"],
            "mtu": settings.mtu
        ]
    }

    public static func isLoopback(host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}
