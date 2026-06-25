import Darwin
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

    func testSystemProxyParsesActiveNetworkServiceFromInterface() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en7)

        (3) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        """

        XCTAssertEqual(
            SystemProxyController.parseNetworkServiceOrder(output, interfaceName: "en7"),
            "USB 10/100/1000 LAN"
        )
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

    @MainActor
    func testRuntimeStoreAccumulatesTrafficSessionAndHistory() {
        let store = RuntimeStore()
        let start = Date(timeIntervalSince1970: 100)

        store.markStarting()
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_024, downloadPerSecond: 2_048, timestamp: start))
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 3_072, downloadPerSecond: 6_144, timestamp: start.addingTimeInterval(2)))

        XCTAssertEqual(store.sessionUploadBytes, 4_096)
        XCTAssertEqual(store.sessionDownloadBytes, 8_192)
        XCTAssertEqual(store.trafficHistory.map(\.uploadPerSecond), [1_024, 3_072])
    }

    @MainActor
    func testRuntimeStoreBucketsDailyTrafficByCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = RuntimeStore(calendar: calendar)

        let day1 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000_000))
        let day2 = calendar.date(byAdding: .day, value: 1, to: day1)!

        store.markStarting()
        // Two 1s-apart samples on day 1 at a constant rate accumulate exactly into day 1's bucket.
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_000, downloadPerSecond: 2_000, timestamp: day1))
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_000, downloadPerSecond: 2_000, timestamp: day1.addingTimeInterval(1)))
        // A sample on the next calendar day opens a new bucket.
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 5_000, downloadPerSecond: 5_000, timestamp: day2))
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 5_000, downloadPerSecond: 5_000, timestamp: day2.addingTimeInterval(1)))

        let recent = store.recentDailyTraffic(days: 2, now: day2.addingTimeInterval(1))
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.uploadBytes, 1_000)
        XCTAssertEqual(recent.first?.downloadBytes, 2_000)
        XCTAssertGreaterThan(recent.last?.totalBytes ?? 0, 0)
        XCTAssertTrue(calendar.isDate(recent.last?.date ?? .distantPast, inSameDayAs: day2))
    }

    @MainActor
    func testRuntimeStoreResetsRuntimeMeasurements() {
        let store = RuntimeStore()
        let start = Date(timeIntervalSince1970: 100)

        store.markStarting()
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_024, downloadPerSecond: 2_048, timestamp: start))
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_024, downloadPerSecond: 2_048, timestamp: start.addingTimeInterval(1)))
        store.update(coreResource: CoreResourceSnapshot(memoryBytes: 64_000_000, cpuPercent: 1.2, timestamp: start))
        store.markStopped()

        XCTAssertEqual(store.sessionUploadBytes, 0)
        XCTAssertEqual(store.sessionDownloadBytes, 0)
        XCTAssertEqual(store.trafficHistory, [])
        XCTAssertEqual(store.traffic, .zero)
        XCTAssertEqual(store.coreResource, .empty)
    }

    @MainActor
    func testRuntimeStoreTracksDelayTestProgressAndResults() {
        let store = RuntimeStore()
        store.proxies = [
            ProxyGroup(
                name: "Proxy",
                nodes: [
                    ProxyNode(name: "Tokyo 01", delay: nil),
                    ProxyNode(name: "Singapore 02", delay: 88)
                ]
            ),
            ProxyGroup(
                name: "Streaming",
                nodes: [
                    ProxyNode(name: "Tokyo 01", delay: nil)
                ]
            )
        ]

        store.beginDelayTest(nodeNames: ["Tokyo 01", "Singapore 02"])

        XCTAssertTrue(store.isTestingDelays)
        XCTAssertEqual(store.delayTestCompletedCount, 0)
        XCTAssertEqual(store.delayTestTotalCount, 2)
        XCTAssertEqual(store.testingDelayNodeNames, Set(["Tokyo 01", "Singapore 02"]))

        store.recordDelayTestResult(name: "Tokyo 01", delay: 42)

        XCTAssertEqual(store.delayTestCompletedCount, 1)
        XCTAssertFalse(store.testingDelayNodeNames.contains("Tokyo 01"))
        XCTAssertEqual(store.proxies[0].nodes[0].delay, 42)
        XCTAssertEqual(store.proxies[1].nodes[0].delay, 42)

        store.recordDelayTestResult(name: "Singapore 02", delay: nil)

        XCTAssertEqual(store.delayTestCompletedCount, 2)
        XCTAssertNil(store.proxies[0].nodes[1].delay)

        store.finishDelayTest()

        XCTAssertFalse(store.isTestingDelays)
        XCTAssertTrue(store.testingDelayNodeNames.isEmpty)
        XCTAssertEqual(store.delayTestCompletedCount, 0)
        XCTAssertEqual(store.delayTestTotalCount, 0)
    }

    @MainActor
    func testRuntimeStoreSelectsProxyWithoutRunningCore() {
        let store = RuntimeStore()
        store.proxies = [
            ProxyGroup(
                name: "HighSpeed",
                now: "Singapore",
                nodes: [
                    ProxyNode(name: "Singapore", isSelected: true),
                    ProxyNode(name: "Tokyo")
                ]
            )
        ]

        XCTAssertTrue(store.selectProxy(group: "HighSpeed", proxy: "Tokyo"))
        XCTAssertEqual(store.proxies[0].now, "Tokyo")
        XCTAssertFalse(store.proxies[0].nodes[0].isSelected)
        XCTAssertTrue(store.proxies[0].nodes[1].isSelected)
        XCTAssertFalse(store.selectProxy(group: "HighSpeed", proxy: "Missing"))
    }

    func testProfileProxyParserBuildsGroupsFromYAML() throws {
        let yaml = """
        proxies:
          - name: Singapore
            type: vless
          - name: Tokyo
            type: trojan
        proxy-groups:
          - name: HighSpeed
            type: select
            proxies:
              - Singapore
              - Tokyo
              - DIRECT
        """

        let groups = try ProfileProxyParser().proxyGroups(from: yaml)

        XCTAssertEqual(groups, [
            ProxyGroup(
                name: "HighSpeed",
                type: "select",
                now: "Singapore",
                nodes: [
                    ProxyNode(name: "Singapore", type: "vless", isSelected: true),
                    ProxyNode(name: "Tokyo", type: "trojan"),
                    ProxyNode(name: "DIRECT", type: "Built-in")
                ]
            )
        ])
    }

    func testCoreResourceMonitorCalculatesCPUPercentFromSamples() {
        let start = Date(timeIntervalSince1970: 100)
        let previous = CoreResourceSample(cpuTimeNanoseconds: 1_000_000_000, memoryBytes: 10, timestamp: start)
        let current = CoreResourceSample(cpuTimeNanoseconds: 2_500_000_000, memoryBytes: 20, timestamp: start.addingTimeInterval(3))

        XCTAssertEqual(CoreResourceMonitor.cpuPercent(previous: previous, current: current) ?? -1, 50, accuracy: 0.001)
    }

    func testCoreResourceMonitorSamplesCurrentProcess() throws {
        let result = try XCTUnwrap(CoreResourceMonitor().snapshot(pid: getpid()))

        XCTAssertGreaterThan(result.sample.memoryBytes, 0)
        XCTAssertGreaterThanOrEqual(result.sample.cpuTimeNanoseconds, 0)
        XCTAssertEqual(result.snapshot.memoryBytes, Int(result.sample.memoryBytes))
    }

    func testOrphanedCorePIDsMatchOnlyOurRuntimeDirectoryAndExcludeLivePID() {
        let runtimeDir = "/Users/me/Library/Application Support/com.pengrao.NeoClash/Runtime"
        let psOutput = """
         4242 /Apps/NeoClash.app/Contents/Resources/Core/mihomo -f \(runtimeDir)/config.yaml -d \(runtimeDir)
          777 /opt/homebrew/bin/mihomo -d /Users/me/.config/mihomo
          999 /Apps/NeoClash.app/Contents/Resources/Core/mihomo -f \(runtimeDir)/config.yaml -d \(runtimeDir)
        """

        let pids = CoreProcessController.orphanedCorePIDs(
            runtimeDirectoryPath: runtimeDir,
            psOutput: psOutput,
            excluding: 999
        )

        // Matches only the mihomo bound to our runtime dir, skips the unrelated Homebrew core, and
        // never reaps the live PID.
        XCTAssertEqual(pids, [4242])
    }

    func testSanitizingLoopbackDropsSelfPointingProxiesButKeepsRemoteOnes() {
        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 7896),
            secureWebProxy: ProxyEndpoint(enabled: true, server: "corp-proxy.example", port: 8443),
            socksProxy: ProxyEndpoint(enabled: true, server: "localhost", port: 7896)
        )

        let cleaned = SystemProxyController.sanitizingLoopback(snapshot)

        XCTAssertFalse(cleaned.webProxy.enabled)
        XCTAssertFalse(cleaned.socksProxy.enabled)
        XCTAssertEqual(cleaned.secureWebProxy, ProxyEndpoint(enabled: true, server: "corp-proxy.example", port: 8443))
    }

    func testLoopbackProxyPortReportsFirstEnabledLoopbackEndpoint() {
        let withLoopback = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: false, server: "127.0.0.1", port: 1),
            secureWebProxy: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 7896),
            socksProxy: ProxyEndpoint(enabled: false)
        )
        XCTAssertEqual(SystemProxyController.loopbackProxyPort(withLoopback), 7896)

        let remoteOnly = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "corp.example", port: 8080),
            secureWebProxy: ProxyEndpoint(enabled: false),
            socksProxy: ProxyEndpoint(enabled: false)
        )
        XCTAssertNil(SystemProxyController.loopbackProxyPort(remoteOnly))
    }
}
