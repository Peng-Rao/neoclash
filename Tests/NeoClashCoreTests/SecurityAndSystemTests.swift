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

    func testSystemProxyParsesNetworksetupProxyState() {
        let output = """
        Enabled: Yes
        Server: proxy.local
        Port: 8080
        Authenticated Proxy Enabled: 0
        """

        let endpoint = SystemProxyController.parseProxyState(output)
        XCTAssertEqual(endpoint, ProxyEndpoint(enabled: true, server: "proxy.local", port: 8080))
    }

    func testSystemProxyRestoreCommandsPreserveSnapshotValues() {
        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "old-http.local", port: 8080),
            secureWebProxy: ProxyEndpoint(enabled: false, server: "old-https.local", port: 8443),
            socksProxy: ProxyEndpoint(enabled: true, server: "old-socks.local", port: 1080),
            bypassDomains: ["localhost", "*.corp"]
        )

        let commands = SystemProxyController().restoreCommands(snapshot: snapshot).map(\.arguments)

        XCTAssertTrue(commands.contains(["-setwebproxy", "Wi-Fi", "old-http.local", "8080"]))
        XCTAssertTrue(commands.contains(["-setsecurewebproxy", "Wi-Fi", "old-https.local", "8443"]))
        XCTAssertTrue(commands.contains(["-setsocksfirewallproxy", "Wi-Fi", "old-socks.local", "1080"]))
        XCTAssertTrue(commands.contains(["-setwebproxystate", "Wi-Fi", "on"]))
        XCTAssertTrue(commands.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(commands.contains(["-setsocksfirewallproxystate", "Wi-Fi", "on"]))
        XCTAssertTrue(commands.contains(["-setproxybypassdomains", "Wi-Fi", "localhost", "*.corp"]))
    }

    func testNetworkStatusParsesEgressPayloads() throws {
        let ipinfo = Data(#"{"ip":"18.163.12.249","country":"hk"}"#.utf8)
        XCTAssertEqual(
            NetworkStatusProbe.parseEgressPayload(ipinfo),
            NetworkEgressInfo(ipAddress: "18.163.12.249", countryCode: "HK")
        )

        let ifconfig = Data(#"{"ip":"203.0.113.8","country_iso":"sg"}"#.utf8)
        XCTAssertEqual(
            NetworkStatusProbe.parseEgressPayload(ifconfig),
            NetworkEgressInfo(ipAddress: "203.0.113.8", countryCode: "SG")
        )
    }

    func testNetworkStatusLatencyRoundsToAtLeastOneMillisecond() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(NetworkStatusProbe.latencyMilliseconds(start: start, end: start.addingTimeInterval(0.0001)), 1)
        XCTAssertEqual(NetworkStatusProbe.latencyMilliseconds(start: start, end: start.addingTimeInterval(0.0424)), 42)
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

    func testCoreBinaryValidatorChecksExecutableAndChecksum() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let coreURL = directory.appendingPathComponent("mihomo")
        try Data("fake-core".utf8).write(to: coreURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)

        let checksum = try CoreBinaryValidator.sha256(of: coreURL)
        let manifest = CoreManifest(
            name: "mihomo",
            version: "test",
            arch: CoreBinaryValidator.currentArchitecture,
            sha256: checksum,
            source: "local"
        )

        XCTAssertNoThrow(try CoreBinaryValidator().validate(coreURL: coreURL, manifest: manifest))

        let badManifest = CoreManifest(
            name: "mihomo",
            version: "test",
            arch: CoreBinaryValidator.currentArchitecture,
            sha256: String(repeating: "0", count: 64),
            source: "local"
        )
        XCTAssertThrowsError(try CoreBinaryValidator().validate(coreURL: coreURL, manifest: badManifest))
    }
}
