import NeoClashCore
import XCTest

final class RuntimeConfigBuilderTests: XCTestCase {
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
        XCTAssertNotNil(object["proxies"])
        XCTAssertNotNil(object["proxy-groups"])
        XCTAssertNotNil(object["rules"])

        let tun = try XCTUnwrap(object["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "system")
        XCTAssertNil(tun["auto-redirect"])
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
}

