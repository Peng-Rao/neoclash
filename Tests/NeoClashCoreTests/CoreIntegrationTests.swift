import NeoClashCore
import XCTest

/// End-to-end smoke test that launches the real bundled Mihomo core, drives it through
/// the same pipeline the app uses (`RuntimeConfigBuilder` → `CoreProcessController` →
/// `MihomoAPIClient`), and verifies the control plane responds before a clean shutdown.
///
/// The test resolves the bundled binary/geodata from the repository tree relative to this
/// source file, so it is skipped (not failed) when those resources or the required loopback
/// ports are unavailable.
final class CoreIntegrationTests: XCTestCase {
    func testRealCoreStartsServesControlAPIAndStops() async throws {
        let resources = try Self.bundledResources()

        let mixedPort = 17_897
        let controllerPort = 19_097
        let portChecker = PortChecker()
        try XCTSkipUnless(
            portChecker.isAvailable(host: "127.0.0.1", port: mixedPort)
                && portChecker.isAvailable(host: "127.0.0.1", port: controllerPort),
            "Required loopback test ports (\(mixedPort)/\(controllerPort)) are busy."
        )

        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoclash-core-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        // Copy bundled geodata beside the runtime config, mirroring AppCoordinator.prepareRuntimeFiles.
        for resource in resources.geo {
            for destinationName in resource.destinationNames {
                let destination = runtimeDirectory.appendingPathComponent(destinationName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: resource.sourceURL, to: destination)
            }
        }

        // A representative subscription-style profile: a proxy, a select group, and GEO + MATCH rules.
        let profileYAML = """
        proxies:
          - {name: demo-ss, type: ss, server: 192.0.2.10, port: 8388, cipher: aes-256-gcm, password: demopass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [demo-ss, DIRECT]}
        rules:
          - GEOSITE,category-ads-all,REJECT
          - GEOIP,CN,DIRECT
          - MATCH,PROXY
        """

        let identity = RuntimeIdentity()
        let overrides = RuntimeOverrides(
            ports: RuntimePorts(mixedPort: mixedPort, controllerHost: "127.0.0.1", controllerPort: controllerPort),
            mode: .rule
        )
        let runtimeYAML = try RuntimeConfigBuilder().build(
            originalYAML: profileYAML,
            overrides: overrides,
            identity: identity
        )
        let runtimeConfigURL = runtimeDirectory.appendingPathComponent("config.yaml")
        try AtomicFileWriter.write(runtimeYAML, to: runtimeConfigURL)

        let controller = CoreProcessController()
        let request = CoreStartRequest(
            coreURL: resources.core,
            runtimeDirectory: runtimeDirectory,
            runtimeConfigURL: runtimeConfigURL,
            manifest: resources.manifest,
            ports: overrides.ports,
            secret: identity.secret,
            readinessTimeout: 25,
            validateConfiguration: true,
            validationTimeout: 20
        )

        // start() validates the binary checksum/arch against the manifest, validates the config
        // with `mihomo -t`, checks ports, launches the process, and polls /version for readiness.
        let result = try await controller.start(request)
        do {
            XCTAssertTrue(result.version.contains("v1."), "Unexpected core version: \(result.version)")
            XCTAssertGreaterThan(result.processIdentifier, 0)

            // The watchdog polls this to detect an unexpected exit; it must read true while running.
            let aliveWhileRunning = await controller.isCoreRunning()
            XCTAssertTrue(aliveWhileRunning)

            let api = MihomoAPIClient(host: "127.0.0.1", port: controllerPort, secret: identity.secret)

            let configs = try await api.configs()
            XCTAssertEqual(configs.mixedPort, mixedPort)
            XCTAssertEqual(configs.mode, "rule")

            let groups = try await api.proxies()
            XCTAssertTrue(
                groups.contains { $0.name == "PROXY" },
                "Expected a PROXY group, found: \(groups.map(\.name))"
            )

            let rules = try await api.rules()
            XCTAssertGreaterThanOrEqual(rules.count, 3)

            // Mode switching reaches the running core.
            try await api.updateMode(.global)
            let globalConfigs = try await api.configs()
            XCTAssertEqual(globalConfigs.mode, "global")

            // Proxy selection persists.
            try await api.updateMode(.rule)
            try await api.selectProxy(group: "PROXY", proxy: "DIRECT")
            let afterSelect = try await api.proxies()
            XCTAssertEqual(afterSelect.first { $0.name == "PROXY" }?.now, "DIRECT")

            // Delay tests are non-fatal even when the upstream is unreachable.
            _ = await api.testDelay(name: "DIRECT")
        } catch {
            await controller.stop()
            throw error
        }

        await controller.stop()
        let aliveAfterStop = await controller.isCoreRunning()
        XCTAssertFalse(aliveAfterStop)
        let stoppedOutputIsBounded = await controller.capturedOutput.count < 1_000_000
        XCTAssertTrue(stoppedOutputIsBounded)
    }

    // MARK: - Resource resolution

    private struct GeoResource {
        var sourceURL: URL
        var destinationNames: [String]
    }

    private static func bundledResources() throws -> (core: URL, manifest: CoreManifest?, geo: [GeoResource]) {
        // .../Tests/NeoClashCoreTests/CoreIntegrationTests.swift → repository root.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreURL = repositoryRoot.appendingPathComponent("NeoClash/Resources/Core/mihomo")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: coreURL.path),
            "Bundled Mihomo core not found at \(coreURL.path)."
        )

        let geoDirectory = repositoryRoot.appendingPathComponent("NeoClash/Resources/Geo")
        let geo = [
            GeoResource(sourceURL: geoDirectory.appendingPathComponent("geoip.dat"), destinationNames: ["geoip.dat"]),
            GeoResource(sourceURL: geoDirectory.appendingPathComponent("geosite.dat"), destinationNames: ["geosite.dat"]),
            GeoResource(
                sourceURL: geoDirectory.appendingPathComponent("country.mmdb"),
                destinationNames: ["country.mmdb", "Country.mmdb"]
            )
        ]
        for resource in geo {
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: resource.sourceURL.path),
                "Bundled geodata missing: \(resource.sourceURL.lastPathComponent)."
            )
        }

        let manifestURL = repositoryRoot.appendingPathComponent("NeoClash/Resources/Core/mihomo-manifest.json")
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(CoreManifest.self, from: $0) }

        return (coreURL, manifest, geo)
    }
}
