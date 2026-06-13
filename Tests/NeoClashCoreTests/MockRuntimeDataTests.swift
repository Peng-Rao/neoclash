import NeoClashCore
import XCTest

final class MockRuntimeDataTests: XCTestCase {
    func testMockProxySelectionUpdatesGroupState() {
        let groups = MockRuntimeData.proxyGroups()
        let updated = MockRuntimeData.selectProxy(groups: groups, groupName: "Proxy", proxyName: "Tokyo 02")
        let proxy = updated.first { $0.name == "Proxy" }

        XCTAssertEqual(proxy?.now, "Tokyo 02")
        XCTAssertEqual(proxy?.nodes.first { $0.name == "Tokyo 02" }?.isSelected, true)
        XCTAssertEqual(proxy?.nodes.first { $0.name == "Hong Kong 01" }?.isSelected, false)
    }

    func testMockDelayTestsAreDeterministicForTick() {
        let groups = MockRuntimeData.proxyGroups()
        let first = MockRuntimeData.testDelays(groups: groups, tick: 4)
        let second = MockRuntimeData.testDelays(groups: groups, tick: 4)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.flatMap(\.nodes).first { $0.name == "DIRECT" }?.delay, 0)
        XCTAssertNotNil(first.first?.nodes.first { $0.name == "Hong Kong 01" }?.delay)
    }

    func testMockConnectionsReflectSelectedProxy() {
        let groups = MockRuntimeData.selectProxy(groups: MockRuntimeData.proxyGroups(), groupName: "Proxy", proxyName: "Tokyo 02")
        let selected = MockRuntimeData.selectedMap(from: groups)
        let connections = MockRuntimeData.connections(tick: 2, selected: selected)

        XCTAssertTrue(connections.contains { $0.chain.contains("Tokyo 02") })
    }
}
