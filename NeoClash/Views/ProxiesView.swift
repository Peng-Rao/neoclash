import NeoClashCore
import SwiftUI

struct ProxiesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var searchText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Proxies")
                        .font(.largeTitle.weight(.semibold))
                    Spacer()
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Button {
                        runtime.appendLog(level: .info, "Delay test requested")
                    } label: {
                        Label("Test", systemImage: "timer")
                    }
                    .buttonStyle(.glass)
                }

                ForEach(filteredGroups) { group in
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(group.name)
                                        .font(.headline)
                                    Text(group.type ?? "Group")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(group.now ?? "None")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                                ForEach(group.nodes) { node in
                                    ProxyNodeTile(node: node) {
                                        runtime.appendLog(level: .info, "Selected \(node.name) in \(group.name)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Proxies")
    }

    private var filteredGroups: [ProxyGroup] {
        guard !searchText.isEmpty else {
            return runtime.proxies
        }
        return runtime.proxies.compactMap { group in
            let nodes = group.nodes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            if group.name.localizedCaseInsensitiveContains(searchText) || !nodes.isEmpty {
                var copy = group
                copy.nodes = nodes.isEmpty ? group.nodes : nodes
                return copy
            }
            return nil
        }
    }
}

private struct ProxyNodeTile: View {
    var node: ProxyNode
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(node.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if node.isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Text(node.type ?? "Proxy")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(delayText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(delayColor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private var delayText: String {
        if let delay = node.delay {
            "\(delay) ms"
        } else {
            "Timeout"
        }
    }

    private var delayColor: Color {
        guard let delay = node.delay else {
            return .secondary
        }
        if delay < 120 {
            return .green
        }
        if delay < 260 {
            return .orange
        }
        return .red
    }
}

