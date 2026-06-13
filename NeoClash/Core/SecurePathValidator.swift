import Foundation

public enum SecurePathValidationError: Error, Equatable, LocalizedError {
    case emptyAllowedRoots
    case pathEscapesAllowedRoots(URL)
    case relativePath(String)
    case missingPath(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyAllowedRoots:
            "No allowed roots were configured."
        case .pathEscapesAllowedRoots(let url):
            "Path escapes allowed roots: \(url.path)."
        case .relativePath(let path):
            "Relative paths are not allowed: \(path)."
        case .missingPath(let url):
            "Path does not exist: \(url.path)."
        }
    }
}

public struct SecurePathValidator {
    private let allowedRoots: [URL]
    private let fileManager: FileManager

    public init(allowedRoots: [URL], fileManager: FileManager = .default) throws {
        guard !allowedRoots.isEmpty else {
            throw SecurePathValidationError.emptyAllowedRoots
        }
        self.allowedRoots = allowedRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        self.fileManager = fileManager
    }

    public func validateExistingPath(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/") else {
            throw SecurePathValidationError.relativePath(url.path)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw SecurePathValidationError.missingPath(url)
        }
        return try validatePath(url)
    }

    public func validatePath(_ url: URL) throws -> URL {
        guard url.path.hasPrefix("/") else {
            throw SecurePathValidationError.relativePath(url.path)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let resolvedPath = resolved.path

        for root in allowedRoots {
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if resolvedPath == root.path || resolvedPath.hasPrefix(rootPath) {
                return resolved
            }
        }
        throw SecurePathValidationError.pathEscapesAllowedRoots(url)
    }
}
