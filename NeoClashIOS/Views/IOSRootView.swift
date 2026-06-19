import SwiftUI

enum IOSAppTab: String, CaseIterable, Identifiable {
    case overview
    case profiles
    case proxies
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .profiles: "Profiles"
        case .proxies: "Proxies"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .profiles: "doc.text"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .logs: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

struct IOSRootView: View {
    @State private var selection: IOSAppTab = .overview

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                IOSDashboardView()
            }
            .tabItem { Label(IOSAppTab.overview.title, systemImage: IOSAppTab.overview.systemImage) }
            .tag(IOSAppTab.overview)

            NavigationStack {
                IOSProfilesView()
            }
            .tabItem { Label(IOSAppTab.profiles.title, systemImage: IOSAppTab.profiles.systemImage) }
            .tag(IOSAppTab.profiles)

            NavigationStack {
                IOSProxiesView()
            }
            .tabItem { Label(IOSAppTab.proxies.title, systemImage: IOSAppTab.proxies.systemImage) }
            .tag(IOSAppTab.proxies)

            NavigationStack {
                IOSLogsView()
            }
            .tabItem { Label(IOSAppTab.logs.title, systemImage: IOSAppTab.logs.systemImage) }
            .tag(IOSAppTab.logs)

            NavigationStack {
                IOSSettingsView()
            }
            .tabItem { Label(IOSAppTab.settings.title, systemImage: IOSAppTab.settings.systemImage) }
            .tag(IOSAppTab.settings)
        }
    }
}
