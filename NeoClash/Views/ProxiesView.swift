import NeoClashCore
import SwiftUI

struct ProxiesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("autoCloseConnections") private var autoCloseConnections = true
    @State private var activeGroup: String?
    @State private var query = ""

    private var groups: [ProxyGroup] { runtime.proxies }
    private var current: ProxyGroup? {
        groups.first { $0.name == activeGroup } ?? groups.first
    }
    private var filteredNodes: [ProxyNode] {
        guard let current else { return [] }
        guard !query.isEmpty else { return current.nodes }
        return current.nodes.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                EmptyState(systemImage: "globe", title: "No proxy groups",
                           message: "Start the Mihomo core to load proxy groups and nodes.")
            } else {
                HStack(alignment: .top, spacing: 14) {
                    groupRail.frame(width: 252)
                    nodeArea.frame(maxWidth: .infinity)
                }
                .padding(20)
            }
        }
        .navigationTitle("Proxies")
    }

    // MARK: Group rail

    private var groupRail: some View {
        GlassCard(title: "Proxy Groups", systemImage: "globe", padded: false) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        groupRow(group)
                        if group.id != groups.last?.id { Divider().opacity(0.5) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func groupRow(_ group: ProxyGroup) -> some View {
        let isActive = current?.id == group.id
        return Button {
            activeGroup = group.name
        } label: {
            HStack(spacing: 10) {
                GlyphBox(systemImage: "globe.asia.australia", size: 30, active: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                    Text(group.now ?? "—")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Badge(text: group.type ?? "Group")
                    Text("\(group.nodes.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.accentColor.soft(0.16) : .clear)
            .overlay(alignment: .leading) {
                if isActive { Rectangle().fill(Color.accentColor).frame(width: 2) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Node area

    private var nodeArea: some View {
        GlassCard(padded: false) {
            VStack(spacing: 0) {
                nodeHeader
                Divider().opacity(0.6)
                ScrollView {
                    if filteredNodes.isEmpty {
                        EmptyState(systemImage: "magnifyingglass", title: "No matching nodes",
                                   message: "Nothing matches “\(query)”.")
                            .padding(.vertical, 30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                            ForEach(filteredNodes) { node in
                                NodeCard(node: node, selected: node.isSelected) { pick(node) }
                            }
                        }
                        .padding(14)
                    }
                }
                Divider().opacity(0.6)
                nodeFooter
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var nodeHeader: some View {
        HStack(spacing: 10) {
            GlyphBox(systemImage: "globe.asia.australia", size: 28, active: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(current?.name ?? "—").font(.system(size: 12.5, weight: .semibold))
                Text("\(current?.nodes.count ?? 0) nodes · \(current?.type ?? "Selector")")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            NCSearchField(text: $query, placeholder: "Filter nodes", width: 160)
            Button { Task { await coordinator.testDelays() } } label: {
                Label("Test All", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var nodeFooter: some View {
        HStack {
            Toggle(isOn: $autoCloseConnections) {
                Text("Close existing connections after switching")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
            Spacer()
            Text(avgDelayText).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var avgDelayText: String {
        let delays = (current?.nodes ?? []).compactMap { $0.delay }
        guard !delays.isEmpty else { return "No latency data" }
        return "Avg delay \(delays.reduce(0, +) / delays.count) ms"
    }

    private func pick(_ node: ProxyNode) {
        guard let current else { return }
        Task {
            await coordinator.selectProxy(group: current.name, proxy: node.name,
                                          closeConnections: autoCloseConnections)
        }
    }
}

private struct NodeCard: View {
    var node: ProxyNode
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(node.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if selected { StatusDot(color: .ncRun, size: 7, glow: false) }
                }
                HStack {
                    LatencyPill(delay: node.delay)
                    Spacer()
                    if let delay = node.delay, delay > 0 {
                        Meter(value: max(0.08, 1 - Double(delay) / 250),
                              color: delay < 80 ? .ncRun : delay < 160 ? .ncWarn : .ncDanger,
                              width: 48)
                    } else {
                        Text(node.type ?? "Proxy").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 11))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 11).stroke(Color.accentColor.soft(0.5), lineWidth: 1)
            }
        }
    }
}

struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
                .frame(width: 52, height: 52)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
