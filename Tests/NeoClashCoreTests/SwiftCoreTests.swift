import Foundation
import NeoClashCore
import NeoClashSwiftCoreLib
import XCTest

final class SwiftCoreTests: XCTestCase {
    func testSwiftCoreControllerObjectsMatchExistingDecoders() throws {
        let state = SwiftCoreState(configuration: try SwiftCoreConfiguration.parse(yaml: Self.sampleYAML()))

        XCTAssertTrue(state.isAuthorized(headers: ["Authorization": "Bearer test-secret"]))
        XCTAssertFalse(state.isAuthorized(headers: ["Authorization": "Bearer wrong"]))

        let proxyGroups = try MihomoAPIClient.decodeProxyGroups(from: SwiftCoreJSON.data(state.proxiesObject()))
        XCTAssertEqual(proxyGroups.first?.name, "Default")
        XCTAssertEqual(proxyGroups.first?.nodes.map(\.name), ["DIRECT"])

        let rules = try MihomoAPIClient.decodeRules(from: SwiftCoreJSON.data(state.rulesObject()))
        XCTAssertEqual(rules.map(\.displayText), ["MATCH,DIRECT"])

        let connections = try MihomoAPIClient.decodeConnections(from: SwiftCoreJSON.data(state.connectionsObject()))
        XCTAssertTrue(connections.isEmpty)
    }

    private static func sampleYAML() -> String {
        """
        mixed-port: 17897
        external-controller: 127.0.0.1:19097
        secret: test-secret
        mode: rule
        log-level: info
        allow-lan: false
        proxies: []
        proxy-groups:
          - name: Default
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """
    }
}
