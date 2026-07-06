import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case requests
    case policy
    case rules
    case profiles
    case logs
    case engineGeneral
    case engineNetwork
    case engineDNS
    case engineTUN
    case engineSniffer
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .requests: "Requests"
        case .policy: "Policy"
        case .rules: "Rules"
        case .profiles: "Profiles"
        case .logs: "Logs"
        case .engineGeneral: "General"
        case .engineNetwork: "Network"
        case .engineDNS: "DNS"
        case .engineTUN: "TUN"
        case .engineSniffer: "Sniffer"
        case .map: "Map"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .requests: "list.bullet.rectangle"
        case .policy: "square.3.layers.3d"
        case .rules: "doc.plaintext"
        case .profiles: "archivebox"
        case .logs: "doc.text"
        case .engineGeneral: "gearshape"
        case .engineNetwork: "globe"
        case .engineDNS: "server.rack"
        case .engineTUN: "shield.lefthalf.filled"
        case .engineSniffer: "scope"
        case .map: "map"
        }
    }
}
