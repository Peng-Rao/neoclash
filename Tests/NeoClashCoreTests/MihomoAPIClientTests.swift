import Foundation
@testable import NeoClashCore
import XCTest

final class MihomoAPIClientTests: XCTestCase {
    func testPercentEncodesProxyPathSegments() async throws {
        let client = MihomoAPIClient(host: "127.0.0.1", port: 9097, secret: "secret")
        let url = try await client.makeURL(pathSegments: ["proxies", "Proxy/日本 01", "delay"])

        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9097/proxies/Proxy%2F%E6%97%A5%E6%9C%AC%2001/delay")
    }

    func testBuildsBracketedIPv6ControllerURL() async throws {
        let client = MihomoAPIClient(host: "::1", port: 9097, secret: "secret")
        let url = try await client.makeURL(pathSegments: ["version"])

        XCTAssertEqual(url.absoluteString, "http://[::1]:9097/version")
    }

    func testReloadConfigSendsJSONPathObject() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MihomoURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let expectedPath = "/tmp/runtime config.yaml"

        MihomoURLProtocolStub.handler = { request in
            let body = try XCTUnwrap(request.capturedHTTPBody())
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object, ["path": expectedPath])
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.url?.query, "force=true")

            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data())
        }
        defer { MihomoURLProtocolStub.handler = nil }

        let client = MihomoAPIClient(host: "127.0.0.1", port: 9097, secret: "secret", session: session)
        try await client.reloadConfig(path: expectedPath)
    }

    func testWebSocketStreamFinishesWhenClientWasStopped() async {
        let client = MihomoWebSocketClient(host: "127.0.0.1", port: 9097, secret: "secret")
        await client.stop()

        let stream = await client.stream(path: "/traffic")
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()

        XCTAssertNil(event)
    }

    func testWebSocketStreamDropsOldestEventsWhenBufferIsFull() async {
        let (stream, continuation) = MihomoWebSocketClient.makeBufferedStream()
        let overflow = 3

        for value in 0..<(MihomoWebSocketClient.streamBufferLimit + overflow) {
            continuation.yield(.raw(Data([UInt8(value)])))
        }
        continuation.finish()

        var received: [Int] = []
        for await event in stream {
            guard case .raw(let data) = event, let value = data.first else {
                XCTFail("Expected a raw WebSocket event")
                continue
            }
            received.append(Int(value))
        }

        XCTAssertEqual(received.count, MihomoWebSocketClient.streamBufferLimit)
        XCTAssertEqual(received, Array(overflow..<(MihomoWebSocketClient.streamBufferLimit + overflow)))
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

private extension URLRequest {
    func capturedHTTPBody() throws -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let httpBodyStream else {
            return nil
        }

        httpBodyStream.open()
        defer { httpBodyStream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = httpBodyStream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw httpBodyStream.streamError ?? URLError(.cannotDecodeContentData)
            }
            if bytesRead == 0 {
                return body
            }
            body.append(contentsOf: buffer.prefix(bytesRead))
        }
    }
}

private final class MihomoURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
