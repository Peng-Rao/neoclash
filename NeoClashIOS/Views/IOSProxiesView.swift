import NeoClashMobileCore
import SwiftUI

struct IOSProxiesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        Group {
            if runtime.proxies.isEmpty {
                StoppedState(title: "No proxies yet", message: "Start NeoClash to see the proxy groups in your profile.")
            } else if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                groupList
            }
        }
        .navigationTitle("Proxies")
        .searchable(text: $searchText, prompt: "Search nodes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                testButton
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(visibleGroups) { group in
                    Section {
                        if isExpanded(group) {
                            // A node can sit in several groups, so its name alone is not a row identity.
                            ForEach(group.nodes.map { GroupedNode(group: group.name, node: $0) }) { row in
                                let node = row.node
                                NodeRow(
                                    node: node,
                                    isTesting: runtime.testingDelayNodeNames.contains(node.name),
                                    isSelectable: group.isSelectable
                                ) {
                                    Task { await coordinator.selectProxy(group: group.name, proxy: node.name) }
                                }
                            }
                        }
                    } header: {
                        GroupHeader(group: group, isExpanded: isExpanded(group)) {
                            toggle(group)
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: runtime.proxies.map(\.now))
    }

    private var testButton: some View {
        Button {
            Task { await coordinator.testDelays() }
        } label: {
            if runtime.isTestingDelays {
                Text("\(runtime.delayTestCompletedCount)/\(runtime.delayTestTotalCount)")
                    .ncMono(.caption)
                    .contentTransition(.numericText())
            } else {
                Label("Test all nodes", systemImage: "gauge.with.needle")
            }
        }
        .disabled(runtime.proxies.isEmpty || runtime.isTestingDelays)
    }

    /// Groups you choose in come first. GLOBAL only routes traffic in global mode, so it would be
    /// a dead control otherwise.
    private var visibleGroups: [ProxyGroup] {
        let shown = runtime.proxies.filter { $0.name != "GLOBAL" || runtime.mode == .global }
        let groups = shown.filter(\.isSelectable) + shown.filter { !$0.isSelectable }
        guard !searchText.isEmpty else {
            return groups
        }
        return groups.compactMap { group in
            var filtered = group
            filtered.nodes = group.nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            return filtered.nodes.isEmpty ? nil : filtered
        }
    }

    private func isExpanded(_ group: ProxyGroup) -> Bool {
        !searchText.isEmpty || !collapsedGroups.contains(group.name)
    }

    private func toggle(_ group: ProxyGroup) {
        withAnimation(.snappy(duration: 0.25)) {
            if collapsedGroups.remove(group.name) == nil {
                collapsedGroups.insert(group.name)
            }
        }
    }
}

private struct GroupedNode: Identifiable {
    var group: String
    var node: ProxyNode

    var id: String { "\(group)/\(node.name)" }
}

private extension ProxyGroup {
    /// Automatic groups such as url-test choose for themselves and the core refuses a selection.
    var isSelectable: Bool {
        type?.lowercased() == "selector"
    }
}

private struct GroupHeader: View {
    var group: ProxyGroup
    var isExpanded: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .padding(.horizontal, NC.pagePadding)
            .padding(.vertical, 10)
            .background(.bar)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var subtitle: String {
        guard let now = group.now else {
            return group.type ?? "Group"
        }
        return group.isSelectable ? now : "\(group.type ?? "Automatic"): \(now)"
    }
}

private struct NodeRow: View {
    var node: ProxyNode
    var isTesting: Bool
    var isSelectable: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Capsule()
                    .fill(NC.brandVertical)
                    .frame(width: 3, height: 26)
                    .opacity(node.isSelected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.subheadline.weight(node.isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if let type = node.type {
                        Text(type)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                LatencyLabel(delay: node.delay, isTesting: isTesting)
            }
            .padding(.leading, NC.pagePadding - 8)
            .padding(.trailing, NC.pagePadding)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Not disabled: rows in an automatic group are live information and shouldn't look greyed out.
        .allowsHitTesting(isSelectable)
        .animation(.snappy(duration: 0.2), value: node.isSelected)
        .accessibilityAddTraits(node.isSelected ? .isSelected : [])
    }
}
