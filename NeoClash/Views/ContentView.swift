import NeoClashCore
import SwiftUI

struct ContentView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    sidebarRow(.overview)
                    sidebarRow(.requests, badge: runtime.status.isRunning ? runtime.connections.count : 0)
                    sidebarRow(.policy)
                    sidebarRow(.rules)
                    sidebarRow(.profiles)
                    sidebarRow(.logs)
                }
                Section("Engine") {
                    sidebarRow(.engineGeneral)
                    sidebarRow(.engineNetwork)
                    sidebarRow(.engineDNS)
                    sidebarRow(.engineTUN)
                    sidebarRow(.engineSniffer)
                }
                Section("Lab") {
                    sidebarRow(.map)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarStatusFooter() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 216)
        } detail: {
            selectedView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selection)
                .transition(.opacity)
                .animation(.smooth(duration: 0.28), value: selection)
        }
        .frame(minWidth: 840, minHeight: 560)
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { controlBar } }
    }

    /// Global controls in the window's top-right toolbar: profile switcher, routing mode, the
    /// System Proxy / TUN quick toggles, and the core start/stop button.
    @ViewBuilder
    private var controlBar: some View {
        let modeBinding = Binding(get: { runtime.mode }, set: { coordinator.setMode($0) })
        let proxyBinding = Binding(get: { runtime.isSystemProxyEnabled }, set: { coordinator.setSystemProxyEnabled($0) })
        let tunBinding = Binding(get: { runtime.isTUNEnabled }, set: { coordinator.setTUNEnabled($0) })

        Menu {
            if runtime.profiles.isEmpty {
                Text("No profiles")
            } else {
                ForEach(runtime.profiles) { profile in
                    Button {
                        coordinator.applyProfile(profile)
                    } label: {
                        if runtime.activeProfile?.id == profile.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
        }
        .help("Active profile: \(runtime.activeProfile?.name ?? "None")")

        Picker("Routing mode", selection: modeBinding) {
            ForEach(RoutingMode.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Toggle(isOn: proxyBinding) { Image(systemName: "globe") }
            .toggleStyle(.button)
            .help("System Proxy")
            .accessibilityLabel("System Proxy")

        Toggle(isOn: tunBinding) { Image(systemName: "shield.lefthalf.filled") }
            .toggleStyle(.button)
            .help("TUN / Enhanced Mode")
            .accessibilityLabel("TUN / Enhanced Mode")

        Button {
            if runtime.status.isRunning {
                Task { await coordinator.stop() }
            } else {
                Task { await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLan) }
            }
        } label: {
            Image(systemName: runtime.status.isRunning ? "stop.fill" : "play.fill")
        }
        .help(runtime.status.isRunning ? "Stop core" : "Start core")
        .accessibilityLabel(runtime.status.isRunning ? "Stop core" : "Start core")
        .disabled(isCoreTransitioning)
    }

    private var isCoreTransitioning: Bool {
        switch runtime.status {
        case .starting, .stopping: true
        default: false
        }
    }

    private func sidebarRow(_ section: AppSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge)
            .tag(section)
    }

    @ViewBuilder
    private var selectedView: some View {
        switch selection ?? .overview {
        case .overview: DashboardView()
        case .requests: ConnectionsView()
        case .policy: ProxiesView()
        case .rules: RulesView()
        case .profiles: ProfilesView()
        case .logs: LogsView()
        case .engineGeneral: EngineGeneralView()
        case .engineNetwork: EngineNetworkView()
        case .engineDNS: EngineDNSView()
        case .engineTUN: EngineTUNView()
        case .engineSniffer: EngineSnifferView()
        case .map: MapView()
        }
    }
}

/// Live status dots pinned to the bottom of the sidebar: System Proxy, Enhanced
/// Mode (TUN), and the Mihomo kernel (green when running, red when it is not).
private struct SidebarStatusFooter: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("System Proxy", color: runtime.isSystemProxyEnabled ? .ncRun : .secondary.opacity(0.55))
            row("Enhanced Mode", color: runtime.isTUNEnabled ? .ncRun : .secondary.opacity(0.55))
            row("Kernel", color: runtime.status.isRunning ? .ncRun : .ncDanger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .animation(.smooth(duration: 0.3), value: runtime.status)
    }

    private func row(_ label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}
