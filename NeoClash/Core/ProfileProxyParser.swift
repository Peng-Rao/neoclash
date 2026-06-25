import Foundation
@preconcurrency import Yams

public enum ProfileProxyParserError: Error, Equatable, LocalizedError {
    case invalidYAMLRoot

    public var errorDescription: String? {
        switch self {
        case .invalidYAMLRoot:
            "The selected profile is not a YAML mapping."
        }
    }
}

public struct ProfileProxyParser: Sendable {
    public init() {}

    public func proxyGroups(from yaml: String) throws -> [ProxyGroup] {
        let loaded = try Yams.load(yaml: yaml)
        guard let root = loaded as? [String: Any] else {
            throw ProfileProxyParserError.invalidYAMLRoot
        }

        let proxyTypes = proxyTypes(from: root["proxies"])
        guard let groups = root["proxy-groups"] as? [[String: Any]] else {
            return []
        }

        return groups.compactMap { group in
            guard let name = group["name"] as? String else {
                return nil
            }
            let all = group["proxies"] as? [String] ?? []
            let now = selectedProxy(in: group, all: all)
            let nodes = all.map { nodeName in
                ProxyNode(
                    name: nodeName,
                    type: proxyTypes[nodeName] ?? builtinProxyType(nodeName),
                    isSelected: nodeName == now
                )
            }
            return ProxyGroup(name: name, type: group["type"] as? String, now: now, nodes: nodes)
        }
    }

    private func proxyTypes(from value: Any?) -> [String: String] {
        guard let proxies = value as? [[String: Any]] else {
            return [:]
        }

        return proxies.reduce(into: [:]) { result, proxy in
            guard let name = proxy["name"] as? String else {
                return
            }
            result[name] = proxy["type"] as? String
        }
    }

    private func selectedProxy(in group: [String: Any], all: [String]) -> String? {
        if let now = group["now"] as? String, all.contains(now) {
            return now
        }
        return all.first
    }

    private func builtinProxyType(_ name: String) -> String? {
        switch name.uppercased() {
        case "DIRECT", "REJECT", "REJECT-DROP", "PASS":
            return "Built-in"
        default:
            return nil
        }
    }
}
