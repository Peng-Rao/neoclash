import Foundation

/// Written by the app to the shared container and read by the packet tunnel at start. It also
/// lets the app reattach to a tunnel that outlived it.
public struct MobileTunnelConfiguration: Codable, Equatable, Sendable {
    public var baseDirectory: String
    public var workDirectory: String
    public var cacheDirectory: String
    public var runtimeConfigPath: String
    public var logPath: String
    public var errorPath: String
    public var profileName: String
    public var controllerHost: String
    public var controllerPort: Int
    public var mixedPort: Int
    public var secret: String
    public var version: String

    public init(
        baseDirectory: String,
        workDirectory: String,
        cacheDirectory: String,
        runtimeConfigPath: String,
        logPath: String,
        errorPath: String,
        profileName: String,
        controllerHost: String,
        controllerPort: Int,
        mixedPort: Int,
        secret: String,
        version: String
    ) {
        self.baseDirectory = baseDirectory
        self.workDirectory = workDirectory
        self.cacheDirectory = cacheDirectory
        self.runtimeConfigPath = runtimeConfigPath
        self.logPath = logPath
        self.errorPath = errorPath
        self.profileName = profileName
        self.controllerHost = controllerHost
        self.controllerPort = controllerPort
        self.mixedPort = mixedPort
        self.secret = secret
        self.version = version
    }
}
