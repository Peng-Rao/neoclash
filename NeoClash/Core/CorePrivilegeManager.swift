import Darwin
import Foundation

public enum CorePrivilegeError: Error, Equatable, LocalizedError {
    case authorizationCancelled
    case authorizationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationCancelled:
            "Administrator authorization is required to enable TUN mode, but it was cancelled."
        case .authorizationFailed(let output):
            "Failed to grant TUN privileges to the core.\n\(Redactor.redact(output))"
        }
    }
}

/// Grants the bundled core the privileges it needs for TUN mode on macOS.
///
/// TUN requires the core to create a `utun` device and edit the routing table, which need root.
/// Mirroring the approach used by mainstream mihomo GUIs (e.g. clash-party), the core binary is
/// made **setuid root** via a single administrator prompt. Afterwards the app launches the core
/// as an ordinary child process — it runs with effective uid 0 (so TUN works), while its real uid
/// stays the user's, so the app can still terminate and monitor it normally.
///
/// The grant is idempotent: if the binary is already `root`-owned with the setuid bit, no prompt
/// is shown (this avoids the repeated-authorization bug seen in other clients).
public struct CorePrivilegeManager: Sendable {
    public init() {}

    /// True when `coreURL` is owned by root and carries the setuid bit (so it runs as root).
    public func hasRootPrivileges(coreURL: URL) -> Bool {
        var info = stat()
        guard stat(coreURL.path, &info) == 0 else {
            return false
        }
        return info.st_uid == 0 && (info.st_mode & UInt16(S_ISUID)) != 0
    }

    /// Ensures the core can run TUN, prompting for administrator authorization only if needed.
    public func ensureTUNPrivileges(coreURL: URL) throws {
        if hasRootPrivileges(coreURL: coreURL) {
            return
        }

        let path = coreURL.path
        let shell = "chown root:admin " + Self.shellQuote(path) + " && chmod +sx " + Self.shellQuote(path)
        let appleScript = "do shell script " + Self.appleScriptQuote(shell) + " with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if output.localizedCaseInsensitiveContains("cancel") || output.contains("-128") {
                throw CorePrivilegeError.authorizationCancelled
            }
            throw CorePrivilegeError.authorizationFailed(output)
        }
        guard hasRootPrivileges(coreURL: coreURL) else {
            throw CorePrivilegeError.authorizationFailed("The core did not gain root privileges after authorization.")
        }
    }

    // Single-quote for /bin/sh; only fixed, app-owned paths are ever passed in.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
