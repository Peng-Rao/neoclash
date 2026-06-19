import NeoClashCore
import XCTest

final class RuntimeConfigBuilderTests: XCTestCase {
    func testRuntimePortsSanitizingKeepsValidPorts() {
        let ports = RuntimePorts.sanitizing(
            mixedPort: 7_898,
            controllerHost: "localhost",
            controllerPort: 9_098
        )

        XCTAssertEqual(ports.mixedPort, 7_898)
        XCTAssertEqual(ports.controllerHost, "localhost")
        XCTAssertEqual(ports.controllerPort, 9_098)
    }

    func testRuntimePortsSanitizingFallsBackForInvalidPorts() {
        let fallback = RuntimePorts(mixedPort: 7_897, controllerPort: 9_097)
        let lowerBound = RuntimePorts.sanitizing(mixedPort: 0, controllerPort: -1, fallback: fallback)
        let upperBound = RuntimePorts.sanitizing(mixedPort: 65_536, controllerPort: Int.max, fallback: fallback)

        XCTAssertEqual(lowerBound, fallback)
        XCTAssertEqual(upperBound, fallback)
    }

    func testRuntimeConfigPreservesProfileAndInjectsOverrides() throws {
        let original = """
        proxies:
          - name: Tokyo 01
            type: ss
            server: example.com
        proxy-groups:
          - name: Proxy
            type: select
            proxies:
              - Tokyo 01
        rules:
          - MATCH,Proxy
        """
        let overrides = RuntimeOverrides(
            ports: RuntimePorts(mixedPort: 7898, controllerHost: "127.0.0.1", controllerPort: 9098),
            mode: .global,
            tun: TUNSettings(isEnabled: true)
        )

        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: original,
            overrides: overrides,
            identity: RuntimeIdentity(secret: "secret-value")
        )

        XCTAssertEqual(object["mixed-port"] as? Int, 7898)
        XCTAssertEqual(object["external-controller"] as? String, "127.0.0.1:9098")
        XCTAssertEqual(object["secret"] as? String, "secret-value")
        XCTAssertEqual(object["allow-lan"] as? Bool, false)
        XCTAssertEqual(object["mode"] as? String, "global")
        XCTAssertEqual(object["geodata-mode"] as? Bool, true)
        XCTAssertNotNil(object["proxies"])
        XCTAssertNotNil(object["proxy-groups"])
        XCTAssertNotNil(object["rules"])

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "system")
        XCTAssertNil(tun["auto-redirect"])
    }

    func testRuntimeConfigPreservesProfileIPv6Preference() throws {
        // The profile opts out of IPv6; the builder must not force it back on.
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: "ipv6: false\nproxies: []",
            overrides: RuntimeOverrides(ipv6: true),
            identity: RuntimeIdentity(secret: "secret")
        )

        XCTAssertEqual(object["ipv6"] as? Bool, false)
    }

    func testRuntimeConfigUsesOverrideIPv6WhenProfileOmitsIt() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: "proxies: []",
            overrides: RuntimeOverrides(ipv6: true),
            identity: RuntimeIdentity(secret: "secret")
        )

        XCTAssertEqual(object["ipv6"] as? Bool, true)
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        XCTAssertEqual(dns["ipv6"] as? Bool, true)
    }

    func testRuntimeConfigPreservesProfileTUNSettingsWhenEnabled() throws {
        let original = """
        tun:
          enable: false
          stack: gvisor
          device: utun1024
          mtu: 1500
          strict-route: false
        proxies: []
        """
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: original,
            overrides: RuntimeOverrides(tun: TUNSettings(isEnabled: true)),
            identity: RuntimeIdentity(secret: "secret")
        )

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)        // forced on
        XCTAssertEqual(tun["auto-route"] as? Bool, true)    // forced for routing
        XCTAssertEqual(tun["stack"] as? String, "gvisor")   // preserved, not clobbered with "system"
        XCTAssertEqual(tun["device"] as? String, "utun1024")
        XCTAssertEqual(tun["mtu"] as? Int, 1500)
        XCTAssertEqual(tun["strict-route"] as? Bool, false)
    }

    func testRuntimeConfigRejectsPublicControllerByDefault() throws {
        let overrides = RuntimeOverrides(
            ports: RuntimePorts(mixedPort: 7897, controllerHost: "0.0.0.0", controllerPort: 9097)
        )

        XCTAssertThrowsError(
            try RuntimeConfigBuilder().buildObject(
                originalYAML: "proxies: []",
                overrides: overrides,
                identity: RuntimeIdentity(secret: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeConfigError, .publicControllerNotAllowed("0.0.0.0"))
        }
    }

    func testRuntimeConfigRejectsEmptySecret() {
        XCTAssertThrowsError(
            try RuntimeConfigBuilder().buildObject(
                originalYAML: "proxies: []",
                identity: RuntimeIdentity(secret: "")
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeConfigError, .emptySecret)
        }
    }

    func testDirectOnlyProfileBuildsRealRuntimeConfig() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: RuntimeConfigBuilder.directOnlyProfileYAML,
            overrides: RuntimeOverrides(
                ports: RuntimePorts(mixedPort: 7899, controllerHost: "127.0.0.1", controllerPort: 9099),
                mode: .direct
            ),
            identity: RuntimeIdentity(secret: "direct-secret")
        )

        XCTAssertEqual(object["mixed-port"] as? Int, 7899)
        XCTAssertEqual(object["external-controller"] as? String, "127.0.0.1:9099")
        XCTAssertEqual(object["secret"] as? String, "direct-secret")
        XCTAssertEqual(object["mode"] as? String, "direct")
        XCTAssertEqual(object["geodata-mode"] as? Bool, true)

        let groups = try XCTUnwrap(object["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["name"] as? String, "Default")
        XCTAssertEqual(groups.first?["proxies"] as? [String], ["DIRECT"])
        XCTAssertEqual(object["rules"] as? [String], ["MATCH,Default"])
    }
}
