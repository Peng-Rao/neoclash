import NeoClashCore
import XCTest

final class SecurityAndSystemTests: XCTestCase {
    func testRedactsURLsAndBearerSecrets() {
        let input = "GET https://token@example.com/sub.yaml Authorization: Bearer abc123"
        let output = Redactor.redact(input)

        XCTAssertFalse(output.contains("token@example.com"))
        XCTAssertFalse(output.contains("abc123"))
        XCTAssertTrue(output.contains("https://<redacted>"))
        XCTAssertTrue(output.contains("Bearer <redacted>"))
    }

    func testSystemProxyEnableCommandsUseLoopbackPortAndBypassDomains() {
        let commands = SystemProxyController().enableCommands(service: "Wi-Fi", host: "127.0.0.1", port: 7897)

        XCTAssertEqual(commands.first?.arguments, ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7897"])
        XCTAssertTrue(commands.contains { $0.arguments == ["-setsecurewebproxystate", "Wi-Fi", "on"] })
        XCTAssertTrue(commands.contains { $0.arguments == ["-setproxybypassdomains", "Wi-Fi", "localhost", "127.0.0.1", "*.local"] })
    }

    func testSecurePathValidatorRejectsTraversalOutsideAllowedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let validator = try SecurePathValidator(allowedRoots: [root])
        XCTAssertNoThrow(try validator.validatePath(root.appendingPathComponent("Runtime/config.yaml")))
        XCTAssertThrowsError(try validator.validatePath(root.appendingPathComponent("../\(outside.lastPathComponent)/core")))
    }

    func testInMemorySecretStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        store.save("https://example.com/sub", service: "svc", account: "profile")

        XCTAssertEqual(try store.load(service: "svc", account: "profile"), "https://example.com/sub")
        store.delete(service: "svc", account: "profile")
        XCTAssertThrowsError(try store.load(service: "svc", account: "profile"))
    }
}
