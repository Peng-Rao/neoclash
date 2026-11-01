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
        XCTAssertEqual(ports.controllerHost, "127.0.0.1")
        XCTAssertEqual(ports.controllerPort, 9_098)
    }

    func testRuntimePortsNormalizeAndFormatIPv6Controller() {
        let ports = RuntimePorts.sanitizing(
            mixedPort: 7_898,
            controllerHost: "[::1]",
            controllerPort: 9_098
        )

        XCTAssertEqual(ports.controllerHost, "::1")
        XCTAssertEqual(RuntimePorts.controllerEndpoint(host: ports.controllerHost, port: ports.controllerPort), "[::1]:9098")
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
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["auto-route"] as? Bool, true)
        XCTAssertEqual(tun["auto-detect-interface"] as? Bool, true)
        XCTAssertEqual(tun["dns-hijack"] as? [String], ["any:53", "tcp://any:53"])
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

    func testRuntimeConfigAddsDefaultSnifferWhenProfileOmitsIt() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: "proxies: []",
            identity: RuntimeIdentity(secret: "secret")
        )

        let sniffer = try XCTUnwrap(object["sniffer"] as? [String: Any])
        XCTAssertEqual(sniffer["enable"] as? Bool, true)
        XCTAssertEqual(sniffer["parse-pure-ip"] as? Bool, true)
        // Sniffed names must stay display/DNS metadata, not rewrite the flow's destination.
        XCTAssertEqual(sniffer["override-destination"] as? Bool, false)
        XCTAssertNotNil((sniffer["sniff"] as? [String: Any])?["TLS"])
    }

    func testRuntimeConfigPreservesProfileSnifferBlock() throws {
        let original = """
        sniffer:
          enable: false
        proxies: []
        """
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: original,
            identity: RuntimeIdentity(secret: "secret")
        )

        let sniffer = try XCTUnwrap(object["sniffer"] as? [String: Any])
        XCTAssertEqual(sniffer["enable"] as? Bool, false)
        XCTAssertNil(sniffer["parse-pure-ip"])
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

    func testRuntimeConfigNormalizesTUNStackAndAllowsAutoRouteOff() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: "proxies: []",
            overrides: RuntimeOverrides(tun: TUNSettings(isEnabled: true, stack: "gVisor", autoRoute: false)),
            identity: RuntimeIdentity(secret: "secret")
        )

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["auto-route"] as? Bool, false)
        XCTAssertEqual(tun["auto-detect-interface"] as? Bool, false)
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

    func testRuntimeConfigFormatsIPv6LoopbackController() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: "proxies: []",
            overrides: RuntimeOverrides(
                ports: RuntimePorts(mixedPort: 7_897, controllerHost: "::1", controllerPort: 9_097)
            ),
            identity: RuntimeIdentity(secret: "secret")
        )

        XCTAssertEqual(object["external-controller"] as? String, "[::1]:9097")
    }

    func testRuntimeConfigRejectsMixedAndControllerPortCollision() {
        XCTAssertThrowsError(
            try RuntimeConfigBuilder().buildObject(
                originalYAML: "proxies: []",
                overrides: RuntimeOverrides(
                    ports: RuntimePorts(mixedPort: 9_097, controllerPort: 9_097)
                ),
                identity: RuntimeIdentity(secret: "secret")
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeConfigError, .portCollision(9_097))
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

    private static let desktopProfile = """
    external-ui: ui
    interface-name: en0
    redir-port: 7892
    tun:
      enable: true
      device: utun7
      mtu: 9000
      strict-route: true
      stack: Mixed
      auto-route: true
    rules:
      - MATCH,DIRECT
    """

    func testDesktopPlatformKeepsDesktopConfigUnchanged() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: Self.desktopProfile,
            overrides: RuntimeOverrides(tun: TUNSettings(isEnabled: true)),
            identity: RuntimeIdentity(secret: "desktop-secret")
        )

        XCTAssertEqual(object["geodata-mode"] as? Bool, true)
        XCTAssertEqual(object["external-ui"] as? String, "ui")
        XCTAssertEqual(object["interface-name"] as? String, "en0")
        XCTAssertNil(object["find-process-mode"])
        XCTAssertNil(object["geodata-loader"])
        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["device"] as? String, "utun7")
        XCTAssertEqual(tun["mtu"] as? Int, 9000)
        XCTAssertEqual(tun["strict-route"] as? Bool, true)
        XCTAssertEqual(tun["auto-route"] as? Bool, true)
    }

    func testPacketTunnelLeavesRoutingAndDeviceToTheSystem() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: Self.desktopProfile,
            overrides: RuntimeOverrides(platform: .iosTunnel),
            identity: RuntimeIdentity(secret: "tunnel-secret")
        )

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["auto-route"] as? Bool, false)
        XCTAssertEqual(tun["auto-detect-interface"] as? Bool, false)
        XCTAssertEqual(tun["mtu"] as? Int, PacketTunnelNetwork.mtu)
        XCTAssertEqual(tun["stack"] as? String, "mixed")
        XCTAssertNotNil(tun["dns-hijack"])
        XCTAssertNil(tun["device"])
        XCTAssertNil(tun["strict-route"])
    }

    func testMobilePlatformsDropDesktopKeysAndUseSmallGeodata() throws {
        for platform in [RuntimePlatform.iosTunnel, .iosLocal] {
            let object = try RuntimeConfigBuilder().buildObject(
                originalYAML: Self.desktopProfile,
                overrides: RuntimeOverrides(platform: platform),
                identity: RuntimeIdentity(secret: "mobile-secret")
            )

            XCTAssertEqual(object["geodata-mode"] as? Bool, false)
            XCTAssertEqual(object["geodata-loader"] as? String, "memconservative")
            XCTAssertEqual(object["geo-auto-update"] as? Bool, false)
            XCTAssertEqual(object["find-process-mode"] as? String, "off")
            XCTAssertNil(object["external-ui"])
            XCTAssertNil(object["interface-name"])
            XCTAssertNil(object["redir-port"])
        }
    }

    func testLocalEngineDisablesProfileTUN() throws {
        let object = try RuntimeConfigBuilder().buildObject(
            originalYAML: Self.desktopProfile,
            overrides: RuntimeOverrides(tun: TUNSettings(isEnabled: true), platform: .iosLocal),
            identity: RuntimeIdentity(secret: "local-secret")
        )

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, false)
    }
}
