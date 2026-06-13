import Foundation

public struct ApplicationPaths: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public var profilesDirectory: URL {
        root.appendingPathComponent("Profiles", isDirectory: true)
    }

    public var runtimeDirectory: URL {
        root.appendingPathComponent("Runtime", isDirectory: true)
    }

    public var runtimeConfigURL: URL {
        runtimeDirectory.appendingPathComponent("config.yaml")
    }

    public var logsDirectory: URL {
        root.appendingPathComponent("Logs", isDirectory: true)
    }

    public var coresDirectory: URL {
        root.appendingPathComponent("Cores", isDirectory: true)
    }

    public static func defaultPaths(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.pengrao.NeoClash") -> ApplicationPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ApplicationPaths(root: appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true))
    }
}

