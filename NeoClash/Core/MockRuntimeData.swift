import Foundation

public enum MockRuntimeData {
    public static let profileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    public static func profile(localFileURL: URL) -> ProxyProfile {
        ProxyProfile(
            id: profileID,
            name: "Demo Profile",
            kind: .localYAML,
            localFileURL: localFileURL,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    public static func proxyGroups() -> [ProxyGroup] {
        [
            ProxyGroup(
                name: "Proxy",
                type: "Selector",
                now: "Hong Kong 01",
                nodes: [
                    ProxyNode(name: "Hong Kong 01", type: "Hysteria2", delay: 38, isSelected: true),
                    ProxyNode(name: "Tokyo 02", type: "VLESS", delay: 64),
                    ProxyNode(name: "Singapore 03", type: "Trojan", delay: 78),
                    ProxyNode(name: "Los Angeles 04", type: "TUIC", delay: 142),
                    ProxyNode(name: "Frankfurt 05", type: "WireGuard", delay: 188)
                ]
            ),
            ProxyGroup(
                name: "Streaming",
                type: "URLTest",
                now: "Singapore 03",
                nodes: [
                    ProxyNode(name: "Singapore 03", type: "Trojan", delay: 74, isSelected: true),
                    ProxyNode(name: "Tokyo 02", type: "VLESS", delay: 88),
                    ProxyNode(name: "Los Angeles 04", type: "TUIC", delay: 126)
                ]
            ),
            ProxyGroup(
                name: "AI",
                type: "Selector",
                now: "Los Angeles 04",
                nodes: [
                    ProxyNode(name: "Los Angeles 04", type: "TUIC", delay: 118, isSelected: true),
                    ProxyNode(name: "Hong Kong 01", type: "Hysteria2", delay: 52),
                    ProxyNode(name: "Frankfurt 05", type: "WireGuard", delay: 171)
                ]
            ),
            ProxyGroup(
                name: "Final",
                type: "Selector",
                now: "Proxy",
                nodes: [
                    ProxyNode(name: "Proxy", type: "Selector", delay: 38, isSelected: true),
                    ProxyNode(name: "DIRECT", type: "Direct", delay: 0),
                    ProxyNode(name: "REJECT", type: "Reject", delay: nil)
                ]
            )
        ]
    }

    public static var rules: [RuleEntry] {
        [
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "openai.com", proxy: "AI"),
            RuleEntry(type: "GEOSITE", payload: "netflix", proxy: "Streaming"),
            RuleEntry(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            RuleEntry(type: "MATCH", payload: "", proxy: "Final")
        ]
    }

    public static func traffic(tick: Int) -> TrafficSnapshot {
        let phase = Double(tick)
        let upload = 18_000 + Int((sin(phase / 2.7) + 1) * 42_000) + (tick % 5) * 3_600
        let download = 420_000 + Int((sin(phase / 3.4) + 1) * 1_400_000) + (tick % 7) * 72_000
        return TrafficSnapshot(uploadPerSecond: upload, downloadPerSecond: download)
    }

    public static func connections(tick: Int, selected: [String: String]) -> [ConnectionEntry] {
        let proxy = selected["Proxy"] ?? "Hong Kong 01"
        let streaming = selected["Streaming"] ?? "Singapore 03"
        let ai = selected["AI"] ?? "Los Angeles 04"
        let baseUp = 2_048 + tick * 1_173
        let baseDown = 96_000 + tick * 18_241

        var entries = [
            ConnectionEntry(
                id: "mock-github",
                host: "api.github.com",
                rule: "DOMAIN-SUFFIX",
                chain: ["Proxy", proxy],
                upload: baseUp,
                download: baseDown,
                process: "Xcode"
            ),
            ConnectionEntry(
                id: "mock-openai",
                host: "chat.openai.com",
                rule: "DOMAIN-SUFFIX",
                chain: ["AI", ai],
                upload: baseUp / 2,
                download: baseDown * 2,
                process: "Safari"
            ),
            ConnectionEntry(
                id: "mock-streaming",
                host: "video.example.cdn",
                rule: "GEOSITE",
                chain: ["Streaming", streaming],
                upload: baseUp / 3,
                download: baseDown * 4,
                process: "TV"
            ),
            ConnectionEntry(
                id: "mock-apple",
                host: "configuration.apple.com",
                rule: "DOMAIN-SUFFIX",
                chain: ["DIRECT"],
                upload: 640 + tick * 45,
                download: 8_192 + tick * 512,
                process: "nsurlsessiond"
            )
        ]

        if tick % 4 != 0 {
            entries.append(
                ConnectionEntry(
                    id: "mock-sync",
                    host: "notes.icloud.com",
                    rule: "DOMAIN-SUFFIX",
                    chain: ["DIRECT"],
                    upload: 8_192 + tick * 770,
                    download: 32_768 + tick * 1_840,
                    process: "Notes"
                )
            )
        }
        return entries
    }

    public static func selectProxy(groups: [ProxyGroup], groupName: String, proxyName: String) -> [ProxyGroup] {
        groups.map { group in
            guard group.name == groupName else {
                return group
            }
            var copy = group
            copy.now = proxyName
            copy.nodes = group.nodes.map { node in
                var copy = node
                copy.isSelected = node.name == proxyName
                return copy
            }
            return copy
        }
    }

    public static func testDelays(groups: [ProxyGroup], tick: Int) -> [ProxyGroup] {
        groups.map { group in
            var group = group
            group.nodes = group.nodes.map { node in
                var copy = node
                if node.name == "REJECT" {
                    copy.delay = nil
                } else if node.name == "DIRECT" {
                    copy.delay = 0
                } else {
                    copy.delay = 28 + ((stableValue(node.name) + tick * 11) % 190)
                }
                return copy
            }
            return group
        }
    }

    public static func selectedMap(from groups: [ProxyGroup]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.name, group.now ?? group.nodes.first(where: \.isSelected)?.name ?? group.nodes.first?.name ?? "DIRECT")
        })
    }

    private static func stableValue(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { partial, scalar in
            partial + Int(scalar.value)
        }
    }
}

