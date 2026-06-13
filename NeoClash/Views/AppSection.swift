import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case profiles
    case proxies
    case connections
    case rules
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .profiles: "Profiles"
        case .proxies: "Proxies"
        case .connections: "Connections"
        case .rules: "Rules"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .profiles: "doc.text"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .connections: "network"
        case .rules: "list.bullet.rectangle"
        case .logs: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

