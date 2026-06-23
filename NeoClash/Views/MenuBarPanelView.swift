import AppKit
import NeoClashCore
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("autoCloseConnections") private var autoCloseConnections = true
    @AppStorage(SettingsKey.menuShowGroups) private var showGroups = true
    @AppStorage(SettingsKey.menuShowTrends) private var showTrends = true
    @AppStorage(SettingsKey.menuShowMetrics) private var showMetrics = true
    @AppStorage(SettingsKey.menuShowSubscription) private var showSubscription = true
    @AppStorage(SettingsKey.menuShowCopyProxy) private var showCopyProxy = true
    @State private var hoveredGroup: String?
    @State private var copiedProxy = false

    var body: some View {
        @Bindable var runtime = runtime
        let running = runtime.status.isRunning

        VStack(spacing: 8) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "bolt.horizontal.fill").font(.system(size: 12)).foregroundStyle(.white))
                    Text("NeoClash").font(.system(size: 14, weight: .bold))
                }
                Spacer()
                HStack(spacing: 6) {
                    StatusDot(color: running ? .ncRun : .secondary, size: 7, glow: false)
                    Text(running ? "Running" : "Stopped")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(running ? Color.ncRun : .secondary)
                }
            }
            .padding(.horizontal, 4)

            // Network metrics card
            if showMetrics {
                VStack(spacing: 6) {
                    HStack {
                        Label("\(runtime.connections.count)", systemImage: "link")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor)
                        Spacer()
                        Label(runtime.traffic.uploadPerSecond.bytesPerSecondString, systemImage: "arrow.up")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor)
                    }
                    HStack {
                        Label(runtime.coreVersion == "Not running" ? "—" : "core", systemImage: "memorychip")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.ncViolet)
                        Spacer()
                        Label(runtime.traffic.downloadPerSecond.bytesPerSecondString, systemImage: "arrow.down")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.ncRun)
                    }
                }
                .labelStyle(.titleAndIcon)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }

            // Traffic trends sparkline
            if showTrends {
                trendsCard
            }

            Divider()

            modeSelector

            Divider()

            // Quick toggles
            menuToggle("System Proxy", systemImage: "globe",
                       isOn: Binding(get: { runtime.isSystemProxyEnabled },
                                     set: { coordinator.setSystemProxyEnabled($0) }))
            menuToggle("TUN / Enhanced Mode", systemImage: "shield.lefthalf.filled",
                       isOn: Binding(get: { runtime.isTUNEnabled },
                                     set: { coordinator.setTUNEnabled($0) }))

            // Subscription info
            if showSubscription {
                Divider()
                subscriptionRow
            }

            // Proxy groups — right-click a row to switch its node
            if showGroups, !runtime.proxies.isEmpty {
                Divider()
                ForEach(runtime.proxies.prefix(6)) { group in
                    groupRow(group)
                }
            }

            Divider()

            // Footer actions
            if showCopyProxy {
                Button { copyTerminalProxy() } label: {
                    Label(copiedProxy ? "Copied!" : "Copy Terminal Proxy",
                          systemImage: copiedProxy ? "checkmark" : "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button { quit() } label: {
                Label("Quit", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 300)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Outbound Mode", systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(runtime.mode.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(RoutingMode.allCases) { mode in
                    Button {
                        coordinator.setMode(mode)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                                .opacity(runtime.mode == mode ? 1 : 0)
                                .frame(width: 12)
                            Text(mode.displayName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(runtime.mode == mode ? Color.accentColor : Color.primary)
                    .background(
                        runtime.mode == mode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
                        in: .rect(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(runtime.mode == mode ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07), lineWidth: 1)
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: runtime.mode)
        }
    }

    private var trendsCard: some View {
        let values = runtime.trafficHistory.suffix(40).map { Double($0.downloadPerSecond) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Traffic", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(runtime.traffic.downloadPerSecond.bytesPerSecondString)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            if values.count >= 2 {
                Sparkline(values: Array(values), color: .accentColor, height: 34)
            } else {
                Text("Waiting for traffic…")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var subscriptionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.activeProfile?.name ?? "No profile")
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(subscriptionDetail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 4)
    }

    private var subscriptionDetail: String {
        guard let profile = runtime.activeProfile else {
            return "Import or add a subscription"
        }
        if let updated = profile.lastUpdatedAt {
            return "Updated \(updated.formatted(.relative(presentation: .named)))"
        }
        return profile.kind == .remoteSubscription ? "Subscription" : "Local profile"
    }

    private func copyTerminalProxy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(terminalProxyExportCommand(), forType: .string)
        copiedProxy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedProxy = false
        }
    }

    private func menuToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage).font(.system(size: 12.5))
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    private func groupRow(_ group: ProxyGroup) -> some View {
        Menu {
            nodeMenu(for: group)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe.asia.australia").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(group.name).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(group.now ?? "—").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoveredGroup == group.id ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering in
            hoveredGroup = hovering ? group.id : (hoveredGroup == group.id ? nil : hoveredGroup)
        }
        .help("Click to switch node")
        .contextMenu { nodeMenu(for: group) }
        .animation(.snappy(duration: 0.15), value: hoveredGroup)
    }

    @ViewBuilder
    private func nodeMenu(for group: ProxyGroup) -> some View {
        if group.nodes.isEmpty {
            Text("No nodes available")
        } else {
            Picker(group.name, selection: Binding(
                get: { group.now ?? "" },
                set: { node in
                    Task { await coordinator.selectProxy(group: group.name, proxy: node, closeConnections: autoCloseConnections) }
                }
            )) {
                ForEach(group.nodes) { node in
                    Text(nodeLabel(node)).tag(node.name)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func nodeLabel(_ node: ProxyNode) -> String {
        if let delay = node.delay, delay > 0 {
            return "\(node.name) · \(delay) ms"
        }
        return node.name
    }

    private func quit() {
        Task { @MainActor in
            if runtime.status != .stopped {
                await coordinator.stop()
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
