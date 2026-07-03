import Foundation
@preconcurrency import Yams

/// A browsable snapshot of a profile's proxies built without a running core: groups and
/// nodes come straight from the YAML, and each node's server endpoint backs offline TCP
/// reachability tests.
public struct ProfileProxyPreview: Sendable {
    public struct Endpoint: Equatable, Sendable {
        public var host: String
        public var port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public var groups: [ProxyGroup]
    public var endpoints: [String: Endpoint]

    public init(groups: [ProxyGroup], endpoints: [String: Endpoint]) {
        self.groups = groups
        self.endpoints = endpoints
    }

    public static func parse(yaml: String) -> ProfileProxyPreview {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any] else {
            return ProfileProxyPreview(groups: [], endpoints: [:])
        }

        let proxies = (root["proxies"] as? [[String: Any]]) ?? []
        var endpoints: [String: Endpoint] = [:]
        var typesByName: [String: String] = [:]
        var orderedNames: [String] = []
        for proxy in proxies {
            guard let name = proxy["name"] as? String, !name.isEmpty else {
                continue
            }
            orderedNames.append(name)
            if let type = proxy["type"] as? String {
                typesByName[name] = type
            }
            if let server = proxy["server"] as? String, !server.isEmpty, let port = portValue(proxy["port"]) {
                endpoints[name] = Endpoint(host: server, port: port)
            }
        }

        let groupEntries = (root["proxy-groups"] as? [[String: Any]]) ?? []
        var groups: [ProxyGroup] = groupEntries.compactMap { entry in
            guard let name = entry["name"] as? String else {
                return nil
            }
            let members = (entry["proxies"] as? [String]) ?? []
            let nodes = members.map { ProxyNode(name: $0, type: typesByName[$0]) }
            return ProxyGroup(name: name, type: entry["type"] as? String, now: nil, nodes: nodes)
        }

        // A profile with proxies but no groups referencing them still deserves a browsable list.
        if groups.allSatisfy(\.nodes.isEmpty), !orderedNames.isEmpty {
            let nodes = orderedNames.map { ProxyNode(name: $0, type: typesByName[$0]) }
            groups.insert(ProxyGroup(name: "Proxies", type: "Profile", now: nil, nodes: nodes), at: 0)
        }

        return ProfileProxyPreview(groups: groups, endpoints: endpoints)
    }

    private static func portValue(_ raw: Any?) -> Int? {
        let port: Int?
        if let value = raw as? Int {
            port = value
        } else if let string = raw as? String {
            port = Int(string)
        } else {
            port = nil
        }
        guard let port, (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}
