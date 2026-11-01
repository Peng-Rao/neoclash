import Foundation
import NeoClashMobileCore

struct ControllerEndpoint: Equatable, Sendable {
    var host: String
    var port: Int
    var secret: String
}

struct EngineStartRequest: Sendable {
    var runtimeYAML: String
    var profileName: String
    var ports: RuntimePorts
    var identity: RuntimeIdentity
}

/// Where the core runs. The UI only ever talks to the controller on loopback, so this is the one
/// place the free-signing and Network Extension builds differ.
@MainActor
protocol EngineHost: AnyObject {
    var platform: RuntimePlatform { get }
    /// False when the core can run but device traffic does not pass through it.
    var routesDeviceTraffic: Bool { get }
    /// Called when the engine stops without being asked to, with the reason if there is one.
    var onUnexpectedStop: ((String?) -> Void)? { get set }

    func start(_ request: EngineStartRequest) async throws -> ControllerEndpoint
    func stop() async throws
    /// The controller of an engine that is already running, such as a tunnel that outlived the app.
    func runningEndpoint() async -> ControllerEndpoint?
}

/// Runs the core inside the app. It needs no entitlements, so it works with free signing, but it
/// stops when the app is suspended and carries no device traffic.
@MainActor
final class LocalEngineHost: EngineHost {
    let platform = RuntimePlatform.iosLocal
    let routesDeviceTraffic = false
    var onUnexpectedStop: ((String?) -> Void)?

    private let paths: ApplicationPaths

    init(paths: ApplicationPaths) {
        self.paths = paths
    }

    func start(_ request: EngineStartRequest) async throws -> ControllerEndpoint {
        let homeDirectory = paths.runtimeDirectory
        let configURL = paths.runtimeConfigURL
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try RuntimeFiles.writeProtected(Data(request.runtimeYAML.utf8), to: configURL)

        try await Task.detached(priority: .userInitiated) {
            try RuntimeFiles.installGeodata(into: homeDirectory)
            try EmbeddedCore.start(homeDirectory: homeDirectory, configURL: configURL)
        }.value

        return ControllerEndpoint(
            host: request.ports.controllerHost,
            port: request.ports.controllerPort,
            secret: request.identity.secret
        )
    }

    func stop() async throws {
        try await Task.detached(priority: .userInitiated) {
            try EmbeddedCore.stop()
        }.value
    }

    func runningEndpoint() async -> ControllerEndpoint? {
        nil
    }
}
