import NeoClashCore
import SwiftUI

struct ContentView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @State private var selection: AppSection? = .dashboard

    var body: some View {
        @Bindable var runtime = runtime

        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: [
                            [0, 0], [0.5, 0], [1, 0],
                            [0, 0.5], [0.45, 0.5], [1, 0.55],
                            [0, 1], [0.5, 1], [1, 1]
                        ],
                        colors: [
                            .blue.opacity(0.16), .mint.opacity(0.12), .clear,
                            .clear, .white.opacity(0.08), .purple.opacity(0.10),
                            .clear, .teal.opacity(0.10), .clear
                        ]
                    )
                    .ignoresSafeArea()
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        if runtime.status.isRunning {
                            await coordinator.stop()
                        } else {
                            await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort)
                        }
                    }
                } label: {
                    Label(runtime.status.isRunning ? "Stop" : "Start", systemImage: runtime.status.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.glass)

                Picker("Mode", selection: $runtime.mode) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Toggle(isOn: $runtime.isSystemProxyEnabled) {
                    Label("System Proxy", systemImage: "macwindow.badge.plus")
                }
                .toggleStyle(.button)

                Toggle(isOn: $runtime.isTUNEnabled) {
                    Label("TUN", systemImage: "shield.lefthalf.filled")
                }
                .toggleStyle(.button)

                TrafficBadge(direction: "arrow.up", value: runtime.traffic.uploadPerSecond)
                TrafficBadge(direction: "arrow.down", value: runtime.traffic.downloadPerSecond)
            }
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selection ?? .dashboard {
        case .dashboard:
            DashboardView()
        case .profiles:
            ProfilesView()
        case .proxies:
            ProxiesView()
        case .connections:
            ConnectionsView()
        case .rules:
            RulesView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        }
    }
}

private struct TrafficBadge: View {
    var direction: String
    var value: Int

    var body: some View {
        Label(value.bytesPerSecondString, systemImage: direction)
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(in: .capsule)
    }
}
