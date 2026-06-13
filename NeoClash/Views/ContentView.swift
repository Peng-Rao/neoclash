import NeoClashCore
import SwiftUI

struct ContentView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var selection: AppSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    sidebarRow(.dashboard)
                    sidebarRow(.connections, badge: runtime.status.isRunning ? runtime.connections.count : 0)
                    sidebarRow(.logs)
                }
                Section("Proxy") {
                    sidebarRow(.proxies)
                    sidebarRow(.rules)
                }
                Section("Config") {
                    sidebarRow(.profiles)
                    sidebarRow(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 216)
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WindowMesh() }
        }
    }

    private func sidebarRow(_ section: AppSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge)
            .tag(section)
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .profiles: ProfilesView()
        case .proxies: ProxiesView()
        case .connections: ConnectionsView()
        case .rules: RulesView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
