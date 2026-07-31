import Darwin
import Foundation

public enum AtomicFileWriter {
    public static func write(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                // replaceItemAt can replace (and thereby destroy) a non-empty directory. Atomic
                // file writes must never reinterpret an unexpected filesystem object as a file.
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }

        let temporaryURL = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")

        // A failed replacement (permissions, a full disk, or a destination that changed type
        // concurrently) must not leave profile/config fragments behind indefinitely.
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try data.write(to: temporaryURL)
        // POSIX rename is an atomic file replacement and refuses to replace a directory with a
        // regular file. FileManager.replaceItemAt can reinterpret a concurrently substituted
        // filesystem object, undermining the non-regular-file check above.
        guard Darwin.rename(temporaryURL.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func write(_ string: String, to destination: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try write(data, to: destination)
    }
}
