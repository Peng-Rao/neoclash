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

    func testDecodesProxyDelayFromHistory() throws {
        // Mihomo reports latency in each proxy's `history` array (latest entry last), with
        // delay 0 meaning the probe failed; there is no top-level `delay` key.
        let json = """
        {
          "proxies": {
            "Proxy": {"type": "Selector", "now": "Tokyo 01", "all": ["Tokyo 01", "Osaka 02", "Direct"]},
            "Tokyo 01": {"type": "Hysteria2", "history": [{"time": "t0", "delay": 130}, {"time": "t1", "delay": 42}]},
            "Osaka 02": {"type": "Trojan", "history": [{"time": "t1", "delay": 0}]},
            "Direct": {"type": "Direct", "history": []}
          }
        }
        """

        let groups = try MihomoAPIClient.decodeProxyGroups(from: Data(json.utf8))
        let nodes = groups[0].nodes
        XCTAssertEqual(nodes[0].delay, 42)
        XCTAssertNil(nodes[1].delay)
        XCTAssertNil(nodes[2].delay)
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

    func testDecodesConnectionEmptyHostFallsBackToDestination() throws {
        // Mihomo sends an empty `host` (not null) for IP-routed flows, and an empty
        // `process` when it can't resolve one. Both must not render blank.
        let json = """
        {
          "connections": [
            {
              "id": "abc",
              "metadata": {
                "host": "",
                "sniffHost": "",
                "destinationIP": "1.1.1.1",
                "destinationPort": "443",
                "process": ""
              },
              "chains": ["DIRECT"],
              "upload": 1,
              "download": 2,
              "rule": "IPCIDR"
            }
          ]
        }
        """

        let connections = try MihomoAPIClient.decodeConnections(from: Data(json.utf8))
        XCTAssertEqual(connections.first?.host, "1.1.1.1:443")
        XCTAssertNil(connections.first?.process)
    }

    func testDecodesConnectionPrefersSniffHostOverDestinationIP() throws {
        let json = """
        {
          "connections": [
            {
              "id": "abc",
              "metadata": {"host": "", "sniffHost": "example.com", "destinationIP": "1.1.1.1"},
              "chains": ["Proxy"],
              "upload": 1,
              "download": 2
            }
          ]
        }
        """

        let connections = try MihomoAPIClient.decodeConnections(from: Data(json.utf8))
        XCTAssertEqual(connections.first?.host, "example.com")
    }

    func testDecodesNullConnectionsAsEmpty() throws {
        // An idle Mihomo core serialises an empty connection list as `null`.
        let json = #"{"downloadTotal":0,"uploadTotal":0,"connections":null,"memory":0}"#
        let connections = try MihomoAPIClient.decodeConnections(from: Data(json.utf8))
        XCTAssertTrue(connections.isEmpty)
    }

    func testDecodesNullRulesAsEmpty() throws {
        let json = #"{"rules":null}"#
        let rules = try MihomoAPIClient.decodeRules(from: Data(json.utf8))
        XCTAssertTrue(rules.isEmpty)
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

    func testDecodesConnectionMetadataForOverviewStats() throws {
        let json = """
        {
          "connections": [
            {
              "id": "abc",
              "metadata": {
                "host": "example.com",
                "sourceIP": "192.168.1.41",
                "destinationIP": "93.184.216.34",
                "type": "Mixed"
              },
              "chains": ["🇯🇵 Tokyo 01", "Proxy"],
              "upload": 10,
              "download": 20,
              "rule": "DOMAIN-SUFFIX",
              "rulePayload": "example.com"
            }
          ]
        }
        """

        let connections = try MihomoAPIClient.decodeConnections(from: Data(json.utf8))
        let entry = try XCTUnwrap(connections.first)
        XCTAssertEqual(entry.sourceIP, "192.168.1.41")
        XCTAssertEqual(entry.destinationIP, "93.184.216.34")
        XCTAssertEqual(entry.inboundType, "Mixed")
        XCTAssertEqual(entry.rulePayload, "example.com")
        XCTAssertEqual(entry.exitNode, "🇯🇵 Tokyo 01")
        XCTAssertFalse(entry.isDirect)
    }

    func testConnectionDirectDetection() {
        XCTAssertTrue(ConnectionEntry(id: "1", host: "a", chain: []).isDirect)
        XCTAssertTrue(ConnectionEntry(id: "2", host: "a", chain: ["DIRECT"]).isDirect)
        XCTAssertFalse(ConnectionEntry(id: "3", host: "a", chain: ["Tokyo 01", "Proxy"]).isDirect)
    }
}
