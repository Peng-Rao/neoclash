import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let configurationPath = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["configurationPath"] as? String
        if let configurationPath {
            NSLog("NeoClash packet tunnel received configuration at \(configurationPath)")
        }

        completionHandler(Self.missingEngineError())
    }

    override func stopTunnel(
        with _: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        let response: [String: String] = [
            "status": "placeholder",
            "message": String(data: messageData, encoding: .utf8) ?? "No embedded iOS VPN engine is bundled."
        ]
        completionHandler?(try? JSONEncoder().encode(response))
    }

    private static func missingEngineError() -> NSError {
        NSError(
            domain: "NeoClashPacketTunnel",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "NeoClash iOS packet tunnel is scaffolded, but no embedded Mihomo/Libclash engine is bundled yet."
            ]
        )
    }
}
