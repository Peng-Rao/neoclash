import Foundation
import NeoClashMobileCore
@preconcurrency import NetworkExtension

enum TunnelConfigurationState: Equatable {
    case missing
    case installed
    case unavailable(String)

    var label: String {
        switch self {
        case .missing:
            "Not Installed"
        case .installed:
            "Installed"
        case .unavailable:
            "Unavailable"
        }
    }
}

struct MobileTunnelConfiguration: Codable, Equatable, Sendable {
    var baseDirectory: String
    var workDirectory: String
    var cacheDirectory: String
    var runtimeConfigPath: String
    var logPath: String
    var errorPath: String
    var profileName: String
    var controllerHost: String
    var controllerPort: Int
    var mixedPort: Int
    var secret: String
    var version: String
}

struct TunnelInstallRequest: Equatable, Sendable {
    var serviceConfiguration: MobileTunnelConfiguration
    var runtimeConfigURL: URL
    var configurationFileURL: URL
}

@MainActor
final class IOSTunnelController {
    nonisolated static let appGroupIdentifier = "group.com.pengrao.NeoClash"
    nonisolated static let providerBundleIdentifier = "com.pengrao.NeoClash.iOS.PacketTunnel"
    nonisolated static let localizedDescription = "NeoClash"

    private let paths: ApplicationPaths
    private let fileManager: FileManager

    init(paths: ApplicationPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func writeConfiguration(
        runtimeYAML: String,
        profileName: String,
        ports: RuntimePorts,
        identity: RuntimeIdentity
    ) throws -> TunnelInstallRequest {
        let baseDirectory = sharedDirectory()
        let workDirectory = baseDirectory.appendingPathComponent("Runtime", isDirectory: true)
        let cacheDirectory = baseDirectory.appendingPathComponent("Cache", isDirectory: true)
        let logsDirectory = baseDirectory.appendingPathComponent("Logs", isDirectory: true)
        let runtimeConfigURL = workDirectory.appendingPathComponent("config.yaml")
        let serviceConfigURL = baseDirectory.appendingPathComponent("service.json")
        let logURL = logsDirectory.appendingPathComponent("neoclash.log")
        let errorURL = logsDirectory.appendingPathComponent("neoclash.err")

        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try AtomicFileWriter.write(runtimeYAML, to: runtimeConfigURL)

        let serviceConfiguration = MobileTunnelConfiguration(
            baseDirectory: baseDirectory.path,
            workDirectory: workDirectory.path,
            cacheDirectory: cacheDirectory.path,
            runtimeConfigPath: runtimeConfigURL.path,
            logPath: logURL.path,
            errorPath: errorURL.path,
            profileName: profileName,
            controllerHost: ports.controllerHost,
            controllerPort: ports.controllerPort,
            mixedPort: ports.mixedPort,
            secret: identity.secret,
            version: "0.1.0"
        )
        let data = try JSONEncoder.pretty.encode(serviceConfiguration)
        try AtomicFileWriter.write(data, to: serviceConfigURL)

        return TunnelInstallRequest(
            serviceConfiguration: serviceConfiguration,
            runtimeConfigURL: runtimeConfigURL,
            configurationFileURL: serviceConfigURL
        )
    }

    func installOrUpdate(configurationFileURL: URL) async throws {
        let configurationPath = configurationFileURL.path
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let manager = managers?.first { $0.localizedDescription == Self.localizedDescription }
                    ?? NETunnelProviderManager()
                let tunnelProtocol = NETunnelProviderProtocol()
                tunnelProtocol.providerBundleIdentifier = Self.providerBundleIdentifier
                tunnelProtocol.serverAddress = Self.localizedDescription
                tunnelProtocol.providerConfiguration = [
                    "configurationPath": configurationPath
                ]

                manager.localizedDescription = Self.localizedDescription
                manager.protocolConfiguration = tunnelProtocol
                manager.isEnabled = true

                manager.saveToPreferences { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    manager.loadFromPreferences { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let manager = managers?.first(where: { $0.localizedDescription == Self.localizedDescription }) else {
                    continuation.resume(throwing: TunnelControllerError.missingConfiguration)
                    return
                }
                guard let session = manager.connection as? NETunnelProviderSession else {
                    continuation.resume(throwing: TunnelControllerError.missingTunnelSession)
                    return
                }
                do {
                    try session.startTunnel(options: ["fromApp": "true" as NSString])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let manager = managers?.first(where: { $0.localizedDescription == Self.localizedDescription }) else {
                    continuation.resume(throwing: TunnelControllerError.missingConfiguration)
                    return
                }
                manager.connection.stopVPNTunnel()
                continuation.resume()
            }
        }
    }

    func status() async throws -> NEVPNStatus {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NEVPNStatus, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let status = managers?
                    .first(where: { $0.localizedDescription == Self.localizedDescription })?
                    .connection
                    .status ?? .invalid
                continuation.resume(returning: status)
            }
        }
    }

    func configurationState() async throws -> TunnelConfigurationState {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TunnelConfigurationState, Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let manager = managers?.first { $0.localizedDescription == Self.localizedDescription }
                continuation.resume(returning: manager?.isEnabled == true ? .installed : .missing)
            }
        }
    }

    private func sharedDirectory() -> URL {
        if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            return container
        }
        return paths.root.appendingPathComponent("SharedTunnel", isDirectory: true)
    }

}

enum TunnelControllerError: Error, LocalizedError {
    case missingConfiguration
    case missingTunnelSession

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Install the NeoClash VPN configuration before starting."
        case .missingTunnelSession:
            "The saved VPN configuration is not a packet tunnel session."
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
