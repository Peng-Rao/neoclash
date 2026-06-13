import CryptoKit
import Foundation

public struct CoreManifest: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var arch: String
    public var sha256: String
    public var source: String

    public init(name: String, version: String, arch: String, sha256: String, source: String) {
        self.name = name
        self.version = version
        self.arch = arch
        self.sha256 = sha256
        self.source = source
    }
}

public enum CoreBinaryValidationError: Error, Equatable, LocalizedError {
    case missingBinary(URL)
    case notExecutable(URL)
    case checksumMismatch(expected: String, actual: String)
    case architectureMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .missingBinary(let url):
            "Core binary is missing: \(url.path)."
        case .notExecutable(let url):
            "Core binary is not executable: \(url.path)."
        case .checksumMismatch(let expected, let actual):
            "Core checksum mismatch. Expected \(expected), got \(actual)."
        case .architectureMismatch(let expected, let actual):
            "Core architecture mismatch. Expected \(expected), got \(actual)."
        }
    }
}

public struct CoreBinaryValidator: Sendable {
    public init() {}

    public func validate(coreURL: URL, manifest: CoreManifest? = nil) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: coreURL.path) else {
            throw CoreBinaryValidationError.missingBinary(coreURL)
        }
        guard fileManager.isExecutableFile(atPath: coreURL.path) else {
            throw CoreBinaryValidationError.notExecutable(coreURL)
        }
        guard let manifest else {
            return
        }
        let actualArch = Self.currentArchitecture
        guard manifest.arch == actualArch || manifest.arch == "universal" else {
            throw CoreBinaryValidationError.architectureMismatch(expected: manifest.arch, actual: actualArch)
        }

        let actualChecksum = try Self.sha256(of: coreURL)
        guard actualChecksum.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw CoreBinaryValidationError.checksumMismatch(expected: manifest.sha256, actual: actualChecksum)
        }
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

