import Foundation
import NeoClashMobileCore
@preconcurrency import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// The system kills packet tunnels at a limit reported as 50 MiB. This soft Go limit leaves
    /// room for the Swift runtime and for buffers the Go heap does not account for.
    private static let memoryLimit: Int64 = 38 * 1_024 * 1_024

    override func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configuration: MobileTunnelConfiguration
        do {
            configuration = try loadConfiguration()
        } catch {
            completionHandler(error)
            return
        }

        // NetworkExtension calls back once on its own queue, so this is never used concurrently.
        nonisolated(unsafe) let completionHandler = completionHandler
        setTunnelNetworkSettings(Self.networkSettings()) { error in
            if let error {
                Self.record(error, for: configuration)
                completionHandler(error)
                return
            }

            guard let descriptor = TunnelDescriptor.find() else {
                let error = PacketTunnelError.missingDescriptor
                Self.record(error, for: configuration)
                completionHandler(error)
                return
            }

            do {
                try EmbeddedCore.start(
                    homeDirectory: URL(fileURLWithPath: configuration.workDirectory, isDirectory: true),
                    configURL: URL(fileURLWithPath: configuration.runtimeConfigPath),
                    tunFileDescriptor: descriptor,
                    memoryLimit: Self.memoryLimit
                )
                completionHandler(nil)
            } catch {
                Self.record(error, for: configuration)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with _: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        try? EmbeddedCore.stop()
        completionHandler()
    }

    private func loadConfiguration() throws -> MobileTunnelConfiguration {
        guard let path = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["configurationPath"] as? String else {
            throw PacketTunnelError.missingConfiguration
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(MobileTunnelConfiguration.self, from: data)
    }

    private static func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: PacketTunnelNetwork.mtu)

        let ipv4 = NEIPv4Settings(
            addresses: [PacketTunnelNetwork.address],
            subnetMasks: [PacketTunnelNetwork.subnetMask]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // Without this route, IPv6 traffic would leave through the physical interface, unproxied.
        let ipv6 = NEIPv6Settings(
            addresses: [PacketTunnelNetwork.ipv6Address],
            networkPrefixLengths: [NSNumber(value: PacketTunnelNetwork.ipv6PrefixLength)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [PacketTunnelNetwork.dnsServer])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /// The app sees the failure through the connection's last error; this keeps a copy for
    /// diagnosing a tunnel that died with no app attached.
    private static func record(_ error: Error, for configuration: MobileTunnelConfiguration) {
        NSLog("NeoClash packet tunnel failed: \(error.localizedDescription)")
        try? AtomicFileWriter.write(
            error.localizedDescription,
            to: URL(fileURLWithPath: configuration.errorPath)
        )
    }
}

enum PacketTunnelError: Error, LocalizedError {
    case missingConfiguration
    case missingDescriptor

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "The VPN configuration has no NeoClash runtime settings. Start it from the app."
        case .missingDescriptor:
            "The packet tunnel could not find its network interface."
        }
    }
}
