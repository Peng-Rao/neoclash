import NeoClashCore
import XCTest

final class ProfileProxyPreviewTests: XCTestCase {
    func testParsesGroupsNodesAndEndpointsFromProfileYAML() {
        let yaml = """
        proxies:
          - {name: Tokyo 01, type: hysteria2, server: jp1.example.com, port: 443}
          - {name: Osaka 02, type: trojan, server: jp2.example.com, port: "8443"}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [Tokyo 01, Osaka 02, DIRECT]}
        rules:
          - MATCH,PROXY
        """

        let preview = ProfileProxyPreview.parse(yaml: yaml)

        XCTAssertEqual(preview.groups.map(\.name), ["PROXY"])
        XCTAssertEqual(preview.groups[0].nodes.map(\.name), ["Tokyo 01", "Osaka 02", "DIRECT"])
        XCTAssertEqual(preview.groups[0].nodes[0].type, "hysteria2")
        XCTAssertNil(preview.groups[0].nodes[0].delay)
        XCTAssertEqual(preview.endpoints["Tokyo 01"], .init(host: "jp1.example.com", port: 443))
        // String ports (common in converted subscriptions) must parse too.
        XCTAssertEqual(preview.endpoints["Osaka 02"], .init(host: "jp2.example.com", port: 8443))
        // Built-ins have no endpoint and are skipped by the offline test.
        XCTAssertNil(preview.endpoints["DIRECT"])
    }

    func testSynthesizesGroupWhenProfileHasProxiesButNoGroups() {
        let yaml = """
        proxies:
          - {name: Solo, type: ss, server: solo.example.com, port: 8388}
        """

        let preview = ProfileProxyPreview.parse(yaml: yaml)

        XCTAssertEqual(preview.groups.count, 1)
        XCTAssertEqual(preview.groups[0].name, "Proxies")
        XCTAssertEqual(preview.groups[0].nodes.map(\.name), ["Solo"])
    }

    func testParsesEmptyPreviewFromInvalidYAML() {
        let preview = ProfileProxyPreview.parse(yaml: ":not yaml: [")

        XCTAssertTrue(preview.groups.isEmpty)
        XCTAssertTrue(preview.endpoints.isEmpty)
    }

    func testTCPProberMeasuresLocalListenerAndFailsClosedPort() async throws {
        let port = 18_633
        let listener = try XCTUnwrap(Self.occupyLoopbackPort(port))
        defer { close(listener) }

        let prober = TCPLatencyProber()
        let latency = await prober.latencyMS(host: "127.0.0.1", port: port, timeout: 2)
        XCTAssertNotNil(latency)
        XCTAssertGreaterThan(latency ?? 0, 0)

        // Loopback connection refused resolves quickly to nil rather than a bogus number.
        let refused = await prober.latencyMS(host: "127.0.0.1", port: 18_634, timeout: 2)
        XCTAssertNil(refused)
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
}
