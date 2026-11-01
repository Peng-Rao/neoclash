import Foundation
internal import NeoClashEngine

public enum EmbeddedCoreError: Error, Equatable, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message):
            "Mihomo core error: \(Redactor.redact(message))"
        }
    }
}

/// Runs mihomo in this process through core/mobile. Both calls block while the core changes
/// state, so call them off the main actor.
public enum EmbeddedCore {
    public static func start(
        homeDirectory: URL,
        configURL: URL,
        tunFileDescriptor: Int32 = 0,
        memoryLimit: Int64 = 0
    ) throws {
        let error = homeDirectory.path.withCString { home in
            configURL.path.withCString { config in
                NCStart(home, config, tunFileDescriptor, memoryLimit)
            }
        }
        try throwIfNeeded(error)
    }

    public static func stop() throws {
        try throwIfNeeded(NCStop())
    }

    public static var version: String {
        consume(NCVersion()) ?? "Unknown"
    }

    private static func throwIfNeeded(_ error: UnsafeMutablePointer<CChar>?) throws {
        if let message = consume(error) {
            throw EmbeddedCoreError.failed(message)
        }
    }

    private static func consume(_ value: UnsafeMutablePointer<CChar>?) -> String? {
        guard let value else {
            return nil
        }
        defer { NCFreeString(value) }
        return String(cString: value)
    }
}
