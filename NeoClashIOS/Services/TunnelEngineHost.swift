import Foundation
import NeoClashMobileCore
@preconcurrency import NetworkExtension

/// Runs the core in the packet tunnel extension. Requires the Network Extension capability, which
/// free Apple accounts cannot get.
@MainActor
final class TunnelEngineHost: EngineHost {
    let platform = RuntimePlatform.iosTunnel
    let routesDeviceTraffic = true
    var onUnexpectedStop: ((String?) -> Void)?

    private static let connectTimeout: Duration = .seconds(20)
    private static let statusPollInterval: Duration = .milliseconds(300)

    private let controller = IOSTunnelController()
    private var isEngineExpected = false
    private var statusObserver: (any NSObjectProtocol)?

    init() {
        // NEVPNStatus transitions arrive asynchronously, and the extension can fail long after
        // startTunnel() returns. The notification is process-wide and may belong to another VPN,
        // so re-read our own provider's status instead of trusting its object.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleStatusChange()
            }
        }
    }

    func start(_ request: EngineStartRequest) async throws -> ControllerEndpoint {
        let installRequest = try controller.writeConfiguration(
            runtimeYAML: request.runtimeYAML,
            profileName: request.profileName,
            ports: request.ports,
            identity: request.identity
        )
        try await controller.installOrUpdate(configurationFileURL: installRequest.configurationFileURL)
        try await controller.start()
        try await waitUntilConnected()
        isEngineExpected = true

        return ControllerEndpoint(
            host: request.ports.controllerHost,
            port: request.ports.controllerPort,
            secret: request.identity.secret
        )
    }

    func stop() async throws {
        isEngineExpected = false
        try await controller.stop()
    }

    func runningEndpoint() async -> ControllerEndpoint? {
        guard (try? await controller.status()) == .connected,
              let configuration = try? controller.storedConfiguration() else {
            return nil
        }
        isEngineExpected = true
        return ControllerEndpoint(
            host: configuration.controllerHost,
            port: configuration.controllerPort,
            secret: configuration.secret
        )
    }

    private func waitUntilConnected() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.connectTimeout)
        // The first reads can still report the previous session's disconnected state.
        var sawStart = false
        while clock.now < deadline {
            switch try await controller.status() {
            case .connected:
                return
            case .connecting, .reasserting:
                sawStart = true
            case .disconnected, .invalid:
                if sawStart {
                    throw TunnelEngineError.failed(await controller.lastDisconnectError())
                }
            default:
                break
            }
            try await Task.sleep(for: Self.statusPollInterval)
        }
        try? await controller.stop()
        throw TunnelEngineError.failed(nil)
    }

    private func handleStatusChange() async {
        guard isEngineExpected, let status = try? await controller.status() else {
            return
        }
        if status == .disconnected || status == .invalid {
            isEngineExpected = false
            onUnexpectedStop?(await controller.lastDisconnectError())
        }
    }
}

enum TunnelEngineError: Error, LocalizedError {
    case failed(String?)

    var errorDescription: String? {
        switch self {
        case .failed(let reason):
            reason ?? "The VPN did not connect."
        }
    }
}
