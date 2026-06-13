import NeoClashCore
import XCTest

final class MihomoAPIClientTests: XCTestCase {
    func testPercentEncodesProxyPathSegments() async throws {
        let client = MihomoAPIClient(host: "127.0.0.1", port: 9097, secret: "secret")
        let url = try await client.makeURL(pathSegments: ["proxies", "Proxy/日本 01", "delay"])

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9097/proxies/Proxy%2F%E6%97%A5%E6%9C%AC%2001/delay")
    }

    func testDecodesProxyGroupsDefensively() throws {
        let json = """
        {
          "proxies": {
            "Proxy": {"type": "Selector", "now": "Tokyo 01", "all": ["Tokyo 01", "Direct"]},
            "Tokyo 01": {"type": "Hysteria2", "delay": 42},
            "Direct": {"type": "Direct"}
          }
        }
        """

        let groups = try MihomoAPIClient.decodeProxyGroups(from: Data(json.utf8))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Proxy")
        XCTAssertEqual(groups[0].nodes.first?.name, "Tokyo 01")
        XCTAssertEqual(groups[0].nodes.first?.isSelected, true)
    }

    func testDecodesConnectionsWithFallbackHost() throws {
        let json = """
        {
          "connections": [
            {
              "id": "abc",
              "metadata": {"destinationIP": "1.1.1.1", "process": "Safari"},
              "chains": ["Proxy", "Tokyo"],
              "upload": 10,
              "download": 20,
              "rule": "MATCH"
            }
          ]
        }
        """

        let connections = try MihomoAPIClient.decodeConnections(from: Data(json.utf8))
        XCTAssertEqual(connections.first?.host, "1.1.1.1")
        XCTAssertEqual(connections.first?.process, "Safari")
        XCTAssertEqual(connections.first?.chain, ["Proxy", "Tokyo"])
    }

    func testDecodesRulesWithVariableKeys() throws {
        let json = """
        {
          "rules": [
            {"type": "DOMAIN-SUFFIX", "payload": "apple.com", "proxy": "DIRECT"},
            {"ruleType": "MATCH", "rule": "", "adapter": "Proxy"}
          ]
        }
        """

        let rules = try MihomoAPIClient.decodeRules(from: Data(json.utf8))
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].displayText, "DOMAIN-SUFFIX,apple.com,DIRECT")
        XCTAssertEqual(rules[1].displayText, "MATCH,Proxy")
    }
}
