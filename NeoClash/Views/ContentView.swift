import NeoClashCore
import SwiftUI

struct ContentView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false
    @State private var selection: AppSection? = .dashboard

    var body: some View {
        @Bindable var runtime = runtime

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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarStatus

                Picker("Mode", selection: $runtime.mode) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()

                Toggle(isOn: $runtime.isSystemProxyEnabled) {
                    Label("System Proxy", systemImage: "globe")
                }
                .toggleStyle(.button)

                Toggle(isOn: $runtime.isTUNEnabled) {
                    Label("TUN", systemImage: "shield.lefthalf.filled")
                }
                .toggleStyle(.button)

                Toggle(isOn: $allowLan) {
                    Label("Allow LAN", systemImage: "wifi.router")
                }
                .toggleStyle(.button)
            }
        }
    }

    private var toolbarStatus: some View {
        HStack(spacing: 6) {
            StatusDot(color: statusColor, size: 7, glow: false)
            Text(runtime.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Core status: \(runtime.status.label)")
    }

    private func sidebarRow(_ section: AppSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge)
            .tag(section)
    }

    private var statusColor: Color {
        switch runtime.status {
        case .running: .ncRun
        case .starting, .stopping: .accentColor
        case .crashed: .ncDanger
        case .stopped: .secondary
        }
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
