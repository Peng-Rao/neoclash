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

    func testSystemProxyParsesAndRejectsAuthenticatedProxyEvenWhenDisabled() throws {
        let output = """
        Enabled: Yes
        Server: corporate.proxy
        Port: 8080
        Authenticated Proxy Enabled: 1
        """

        let endpoint = SystemProxyController.parseProxyState(output)
        XCTAssertEqual(
            endpoint,
            ProxyEndpoint(enabled: true, server: "corporate.proxy", port: 8080, authenticated: true)
        )

        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: endpoint,
            secureWebProxy: ProxyEndpoint(enabled: false),
            socksProxy: ProxyEndpoint(enabled: false)
        )
        XCTAssertTrue(snapshot.hasEnabledAuthenticatedProxy)
        XCTAssertThrowsError(try SystemProxyController.validateCanOverwrite(snapshot)) { error in
            XCTAssertEqual(error as? SystemProxyError, .authenticatedProxyCannotBeOverwritten("Wi-Fi"))
        }

        var disabledSnapshot = snapshot
        disabledSnapshot.webProxy.enabled = false
        XCTAssertTrue(disabledSnapshot.hasEnabledAuthenticatedProxy)
        XCTAssertThrowsError(try SystemProxyController.validateCanOverwrite(disabledSnapshot)) { error in
            XCTAssertEqual(error as? SystemProxyError, .authenticatedProxyCannotBeOverwritten("Wi-Fi"))
        }
    }

    func testSystemProxyRestoreUsesEmptySentinelToClearBypassDomains() {
        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: false),
            secureWebProxy: ProxyEndpoint(enabled: false),
            socksProxy: ProxyEndpoint(enabled: false),
            bypassDomains: []
        )

        let commands = SystemProxyController().restoreCommands(snapshot: snapshot).map(\.arguments)
        XCTAssertTrue(commands.contains(["-setproxybypassdomains", "Wi-Fi", "Empty"]))
    }

    func testLoopbackConfigurationDetectionIncludesDisabledSuppressedEndpoints() {
        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: false, server: "127.0.0.1", port: 7897),
            secureWebProxy: ProxyEndpoint(enabled: false),
            socksProxy: ProxyEndpoint(enabled: false)
        )

        XCTAssertTrue(SystemProxyController.hasLoopbackConfiguration(snapshot))
        XCTAssertTrue(SystemProxyController.hasLoopbackConfiguration(snapshot, port: 7897))
        XCTAssertFalse(SystemProxyController.hasLoopbackConfiguration(snapshot, port: 7898))
        XCTAssertNil(SystemProxyController.loopbackProxyPort(snapshot))
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

    func testMatchingLoopbackDisableCommandsPreserveUnrelatedProxyKinds() {
        let snapshot = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 7897),
            secureWebProxy: ProxyEndpoint(enabled: true, server: "corp.example", port: 8443),
            socksProxy: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 9999)
        )

        let commands = SystemProxyController.disableMatchingLoopbackCommands(
            snapshot: snapshot,
            port: 7897
        ).map(\.arguments)

        XCTAssertEqual(commands, [["-setwebproxystate", "Wi-Fi", "off"]])
    }

    func testPersistedProxyOwnershipAllowsOnlyNeoClashOrOriginalFields() {
        let original = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "corp.example", port: 8080),
            secureWebProxy: ProxyEndpoint(enabled: false, server: "secure.example", port: 8443),
            socksProxy: ProxyEndpoint(enabled: false),
            bypassDomains: ["*.corp"]
        )
        let partialNeoClashMutation = ProxyServiceSnapshot(
            service: "Wi-Fi",
            webProxy: ProxyEndpoint(enabled: true, server: "127.0.0.1", port: 7897),
            secureWebProxy: original.secureWebProxy,
            socksProxy: original.socksProxy,
            bypassDomains: original.bypassDomains
        )
        XCTAssertTrue(
            SystemProxyController.canRestorePersistedSnapshot(
                original,
                from: partialNeoClashMutation,
                neoClashPort: 7897
            )
        )

        var changedByUser = partialNeoClashMutation
        changedByUser.secureWebProxy = ProxyEndpoint(
            enabled: true,
            server: "new-corp.example",
            port: 9443
        )
        XCTAssertFalse(
            SystemProxyController.canRestorePersistedSnapshot(
                original,
                from: changedByUser,
                neoClashPort: 7897
            )
        )

        var changedBypass = partialNeoClashMutation
        changedBypass.bypassDomains = ["new.example"]
        XCTAssertFalse(
            SystemProxyController.canRestorePersistedSnapshot(
                original,
                from: changedBypass,
                neoClashPort: 7897
            )
        )

        XCTAssertFalse(
            SystemProxyController.canRestorePersistedSnapshot(
                original,
                from: original,
                neoClashPort: 7897
            )
        )
    }

    func testProxySnapshotDecodesLegacyRecoveryRecordWithoutManagedPort() throws {
        let data = Data(
            """
            {
              "service": "Wi-Fi",
              "webProxy": { "enabled": false, "server": "", "authenticated": false },
              "secureWebProxy": { "enabled": false, "server": "", "authenticated": false },
              "socksProxy": { "enabled": false, "server": "", "authenticated": false },
              "bypassDomains": []
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ProxyServiceSnapshot.self, from: data)
        XCTAssertNil(decoded.managedLoopbackPort)
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
    func testRuntimeStoreReconcilesActiveProfileAfterReload() {
        let root = URL(fileURLWithPath: "/tmp/neoclash-profile-test", isDirectory: true)
        let first = ProxyProfile(
            name: "First",
            kind: .localYAML,
            localFileURL: root.appendingPathComponent("first.yaml")
        )
        let second = ProxyProfile(
            name: "Second",
            kind: .localYAML,
            localFileURL: root.appendingPathComponent("second.yaml")
        )
        let store = RuntimeStore()
        store.applyProfiles([first, second])
        store.activeProfile = second

        var refreshedSecond = second
        refreshedSecond.name = "Second (updated)"
        store.applyProfiles([first, refreshedSecond])
        XCTAssertEqual(store.activeProfile, refreshedSecond)

        store.applyProfiles([first])
        XCTAssertEqual(store.activeProfile, first)

        store.applyProfiles([])
        XCTAssertNil(store.activeProfile)
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

    func testCoreResourceMonitorSamplesRootOwnedProcess() throws {
        // TUN mode runs the core setuid-root; proc_pidinfo is EPERM across users, so the
        // monitor must fall back to `ps`. launchd (pid 1) reproduces the cross-user case.
        let result = try XCTUnwrap(CoreResourceMonitor().snapshot(pid: 1))

        XCTAssertGreaterThan(result.sample.memoryBytes, 0)
        XCTAssertGreaterThan(result.sample.cpuTimeNanoseconds, 0)
    }

    func testWaitForPortsAvailableThrowsWhileForeignListenerHoldsPort() async throws {
        let port = 18_631
        let listener = try XCTUnwrap(Self.occupyLoopbackPort(port))
        defer { close(listener) }

        let controller = CoreProcessController()
        do {
            try await controller.waitForPortsAvailable(Self.portWaitRequest(controllerPort: port), timeout: 0.4)
            XCTFail("Expected portUnavailable for a held port")
        } catch let error as CoreProcessError {
            XCTAssertEqual(error, .portUnavailable(port))
        }
    }

    func testWaitForPortsAvailableRecoversWhenPortFreesMidWait() async throws {
        // Restart race: the previous core releases its listener a beat after stop().
        let port = 18_632
        let listener = try XCTUnwrap(Self.occupyLoopbackPort(port))

        let releaser = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            close(listener)
        }
        defer { releaser.cancel() }

        let controller = CoreProcessController()
        try await controller.waitForPortsAvailable(Self.portWaitRequest(controllerPort: port), timeout: 4)
    }

    func testWaitForPortsAvailableRejectsPortCollision() async {
        let port = 18_633
        let request = CoreStartRequest(
            coreURL: URL(fileURLWithPath: "/usr/bin/true"),
            runtimeDirectory: FileManager.default.temporaryDirectory,
            runtimeConfigURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.yaml"),
            ports: RuntimePorts(mixedPort: port, controllerHost: "127.0.0.1", controllerPort: port),
            secret: "secret"
        )

        do {
            try await CoreProcessController().waitForPortsAvailable(request)
            XCTFail("Expected a deterministic port-collision error")
        } catch let error as CoreProcessError {
            XCTAssertEqual(error, .portCollision(port))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPortCheckerSupportsNormalizedLoopbackHosts() {
        let checker = PortChecker()

        XCTAssertTrue(checker.isAvailable(host: "localhost", port: 18_634))
        XCTAssertTrue(checker.isAvailable(host: "::1", port: 18_635))
        XCTAssertTrue(checker.isAvailable(host: "[::1]", port: 18_636))
    }

    func testConcurrentCoreStartIsRejectedWhileFirstStartIsSuspended() async throws {
        let port = 18_637
        let listener = try XCTUnwrap(Self.occupyLoopbackPort(port))
        defer { close(listener) }

        let controller = CoreProcessController()
        let request = Self.portWaitRequest(controllerPort: port)
        let firstStart = Task {
            try await controller.start(request)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await controller.start(request)
            XCTFail("Expected the concurrent start to be rejected")
        } catch let error as CoreProcessError {
            XCTAssertEqual(error, .processAlreadyRunning)
        }

        firstStart.cancel()
        do {
            _ = try await firstStart.value
            XCTFail("Expected the canceled first start to unwind")
        } catch is CancellationError {
            // Expected: cancellation must release the serialized starting state.
        } catch {
            XCTFail("Unexpected first-start error: \(error)")
        }
    }

    func testConfigurationValidationDrainsLargeOutputWithoutDeadlocking() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = try Self.makeExecutableScript(
            """
            #!/bin/sh
            if [ "$1" = "-t" ]; then
              /usr/bin/yes validation-output | /usr/bin/head -c 262144
              exit 0
            fi
            exit 0
            """,
            in: directory,
            name: "large-output-core"
        )
        let request = CoreStartRequest(
            coreURL: script,
            runtimeDirectory: directory,
            runtimeConfigURL: directory.appendingPathComponent("config.yaml"),
            ports: RuntimePorts(mixedPort: 18_638, controllerPort: 18_639),
            secret: "secret",
            readinessTimeout: 1,
            validationTimeout: 3
        )

        do {
            _ = try await CoreProcessController().start(request)
            XCTFail("The fake launch should exit before readiness")
        } catch let error as CoreProcessError {
            guard case .unexpectedExit = error else {
                XCTFail("Validation should finish rather than time out: \(error)")
                return
            }
        }
    }

    func testCancelingConfigurationValidationTerminatesAndReapsValidator() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pidURL = directory.appendingPathComponent("validator.pid")
        let script = try Self.makeExecutableScript(
            """
            #!/bin/sh
            echo $$ > '\(pidURL.path)'
            exec /bin/sleep 30
            """,
            in: directory,
            name: "slow-validator"
        )
        let request = CoreStartRequest(
            coreURL: script,
            runtimeDirectory: directory,
            runtimeConfigURL: directory.appendingPathComponent("config.yaml"),
            ports: RuntimePorts(mixedPort: 18_640, controllerPort: 18_641),
            secret: "secret",
            validationTimeout: 20
        )
        let controller = CoreProcessController()
        let start = Task {
            try await controller.start(request)
        }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))

        start.cancel()
        do {
            _ = try await start.value
            XCTFail("Expected validation cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let probeResult = kill(pid, 0)
        let probeError = errno
        XCTAssertEqual(probeResult, -1, "Canceled validation process should be reaped")
        XCTAssertEqual(probeError, ESRCH)
    }

    private static func portWaitRequest(controllerPort: Int) -> CoreStartRequest {
        CoreStartRequest(
            coreURL: URL(fileURLWithPath: "/usr/bin/true"),
            runtimeDirectory: FileManager.default.temporaryDirectory,
            runtimeConfigURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.yaml"),
            ports: RuntimePorts(mixedPort: 18_630, controllerHost: "127.0.0.1", controllerPort: controllerPort),
            secret: "secret"
        )
    }

    private static func occupyLoopbackPort(_ port: Int) -> Int32? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return nil
        }
        var value: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func makeExecutableScript(_ contents: String, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testCoreResourceMonitorParsesPSCPUTime() {
        XCTAssertEqual(CoreResourceMonitor.nanoseconds(fromCPUTime: "0:00.05"), 50_000_000)
        XCTAssertEqual(CoreResourceMonitor.nanoseconds(fromCPUTime: "7:21.06"), 441_060_000_000)
        XCTAssertEqual(CoreResourceMonitor.nanoseconds(fromCPUTime: "1:02:03.04"), 3_723_040_000_000)
        XCTAssertEqual(CoreResourceMonitor.nanoseconds(fromCPUTime: "2-03:04:05.06"), 183_845_060_000_000)
        XCTAssertNil(CoreResourceMonitor.nanoseconds(fromCPUTime: "garbage"))
        XCTAssertNil(CoreResourceMonitor.nanoseconds(fromCPUTime: ""))
    }

    func testOrphanedCorePIDsMatchOnlyOurRuntimeDirectoryAndExcludeLivePID() {
        let runtimeDir = "/Users/me/Library/Application Support/com.pengrao.NeoClash/Runtime"
        let psOutput = """
         4242 /Apps/NeoClash.app/Contents/Resources/Core/mihomo -f \(runtimeDir)/config.yaml -d \(runtimeDir)
        4243 /bin/sh -c echo mihomo -d \(runtimeDir)
        4244 /tmp/mihomo-helper -d \(runtimeDir)
        4245 /Apps/NeoClash.app/Contents/Resources/Core/mihomo -d \(runtimeDir)-other
        4246 /bin/sh -c /Apps/NeoClash.app/Contents/Resources/Core/mihomo -d \(runtimeDir)
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

    @MainActor
    func testRuntimeStoreAggregatesConnectionStatsFromByteDeltas() {
        let store = RuntimeStore()
        store.markStarting()

        let first = ConnectionEntry(
            id: "1", host: "example.com", rule: "DOMAIN-SUFFIX", rulePayload: "example.com",
            chain: ["🇯🇵 Tokyo 01", "Proxy"], upload: 100, download: 400,
            sourceIP: "192.168.1.41", inboundType: "Mixed"
        )
        let direct = ConnectionEntry(
            id: "2", host: "apple.com", rule: "DOMAIN-SUFFIX", rulePayload: "apple.com",
            chain: ["DIRECT"], upload: 50, download: 150,
            sourceIP: "192.168.1.41", inboundType: "Tun"
        )
        store.update(connections: [first, direct])

        XCTAssertEqual(store.connectionStats.proxyBytes, 500)
        XCTAssertEqual(store.connectionStats.directBytes, 200)
        XCTAssertEqual(store.connectionStats.byDomain["example.com"], 500)
        XCTAssertEqual(store.connectionStats.byNode["🇯🇵 Tokyo 01"], 500)
        XCTAssertEqual(store.connectionStats.byNode["DIRECT"], 200)
        XCTAssertEqual(store.connectionStats.byRule["DOMAIN-SUFFIX · example.com"], 500)
        XCTAssertEqual(store.connectionStats.bySource["192.168.1.41"], 700)
        XCTAssertEqual(store.connectionStats.byInbound["Mixed"], 500)
        XCTAssertEqual(store.connectionStats.byCountry["JP"], 500)
        XCTAssertEqual(store.connectionStats.seenDestinations.count, 2)
        XCTAssertEqual(store.connectionStats.closedCount, 0)

        // Only growth since the last snapshot is attributed; a vanished id counts as closed.
        var grown = first
        grown.upload = 150
        grown.download = 550
        store.update(connections: [grown])

        XCTAssertEqual(store.connectionStats.proxyBytes, 700)
        XCTAssertEqual(store.connectionStats.byDomain["example.com"], 700)
        XCTAssertEqual(store.connectionStats.closedCount, 1)

        // The direct/proxy split lands in today's daily bucket for the Traffic Split card.
        let today = store.recentDailyTraffic(days: 1).first
        XCTAssertEqual(today?.proxyBytes, 700)
        XCTAssertEqual(today?.directBytes, 200)

        store.markStopped()
        XCTAssertEqual(store.connectionStats, ConnectionStats())
    }

    @MainActor
    func testRuntimeStoreBucketsHourlyTrafficByClockHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = RuntimeStore(calendar: calendar)

        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_000_000))
        let nineAM = calendar.date(byAdding: .hour, value: 9, to: dayStart)!

        store.markStarting()
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_000, downloadPerSecond: 2_000, timestamp: nineAM))
        store.update(traffic: TrafficSnapshot(uploadPerSecond: 1_000, downloadPerSecond: 2_000, timestamp: nineAM.addingTimeInterval(1)))

        let buckets = store.todayHourlyTraffic(now: nineAM)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[9].uploadBytes, 1_000)
        XCTAssertEqual(buckets[9].downloadBytes, 2_000)
        XCTAssertEqual(buckets[8].totalBytes, 0)
    }

    func testDailyTrafficSampleDecodesLegacyPayloadWithoutSplitFields() throws {
        let legacy = """
        [{"date": 1000000, "downloadBytes": 42, "uploadBytes": 7}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let samples = try decoder.decode([DailyTrafficSample].self, from: Data(legacy.utf8))
        XCTAssertEqual(samples.first?.downloadBytes, 42)
        XCTAssertEqual(samples.first?.directBytes, 0)
        XCTAssertEqual(samples.first?.proxyBytes, 0)
    }

    func testCountryGuesserResolvesFlagsAliasesAndCodes() {
        XCTAssertEqual(CountryGuesser.countryCode(for: "🇭🇰 IEPL 香港 01"), "HK")
        XCTAssertEqual(CountryGuesser.countryCode(for: "Tokyo Premium"), "JP")
        XCTAssertEqual(CountryGuesser.countryCode(for: "新加坡 BGP"), "SG")
        XCTAssertEqual(CountryGuesser.countryCode(for: "US-West 03"), "US")
        XCTAssertNil(CountryGuesser.countryCode(for: "Fastest Auto"))
        XCTAssertEqual(CountryGuesser.flagEmoji(for: "JP"), "🇯🇵")
    }
}
