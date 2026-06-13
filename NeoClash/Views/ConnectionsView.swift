import NeoClashCore
import SwiftUI

struct ConnectionsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var query = ""
    @State private var sort: Sort = .download

    enum Sort: String, CaseIterable { case download = "↓ Down", upload = "↑ Up", host = "Host" }

    private var filtered: [ConnectionEntry] {
        let base = runtime.connections.filter {
            query.isEmpty
                || $0.host.localizedCaseInsensitiveContains(query)
                || ($0.process?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.rule?.localizedCaseInsensitiveContains(query) ?? false)
        }
        switch sort {
        case .download: return base.sorted { $0.download > $1.download }
        case .upload: return base.sorted { $0.upload > $1.upload }
        case .host: return base.sorted { $0.host < $1.host }
        }
    }

    var body: some View {
        Group {
            if !runtime.status.isRunning {
                EmptyState(systemImage: "network", title: "Core not running",
                           message: "Start the Mihomo core to inspect active connections and live traffic.")
            } else {
                VStack(spacing: 14) {
                    toolbar
                    GlassCard(padded: false) {
                        VStack(spacing: 0) {
                            header
                            Divider().opacity(0.6)
                            ScrollView {
                                if filtered.isEmpty {
                                    EmptyState(systemImage: "checkmark.circle", title: "No active connections",
                                               message: "Nothing is being routed right now. New flows appear here in real time.")
                                        .padding(.vertical, 30)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(filtered) { row($0) }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .padding(20)
            }
        }
        .navigationTitle("Connections")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            NCSearchField(text: $query, placeholder: "Filter host, process, rule…", width: 280)
            Picker("", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            HStack(spacing: 14) {
                summary("Active", "\(filtered.count)", .secondary)
                summary("↑", runtime.connections.reduce(0) { $0 + $1.upload }.byteString, .accentColor)
                summary("↓", runtime.connections.reduce(0) { $0 + $1.download }.byteString, .ncRun)
            }
            Button(role: .destructive) {
                Task { await coordinator.closeAllConnections() }
            } label: {
                Label("Close All", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .disabled(filtered.isEmpty)
        }
    }

    private func summary(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(color == .secondary ? .secondary : color)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }

    private var header: some View {
        cells(
            host: Text("HOST"), process: Text("PROCESS"), rule: Text("RULE"),
            chain: Text("CHAIN"), traffic: Text("↑ / ↓")
        )
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }

    private func row(_ c: ConnectionEntry) -> some View {
        VStack(spacing: 0) {
            cells(
                host: VStack(alignment: .leading, spacing: 1) {
                    Text(c.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let process = c.process {
                        Text(process).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                },
                process: Text(c.process ?? "—").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1),
                rule: Text(c.rule ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1),
                chain: chainView(c.chain),
                traffic: VStack(alignment: .trailing, spacing: 1) {
                    Text(c.upload.byteString).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.accentColor)
                    Text(c.download.byteString).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.ncRun)
                }
            )
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider().opacity(0.5)
        }
    }

    @ViewBuilder
    private func chainView(_ chain: [String]) -> some View {
        let text = chain.joined(separator: " → ")
        if chain == ["DIRECT"] || chain.isEmpty {
            Badge(text: chain.first ?? "DIRECT")
        } else {
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor).lineLimit(1)
        }
    }

    // Shared column layout for header + rows.
    private func cells<H: View, P: View, R: View, C: View, T: View>(
        host: H, process: P, rule: R, chain: C, traffic: T
    ) -> some View {
        HStack(spacing: 12) {
            host.frame(maxWidth: .infinity, alignment: .leading)
            process.frame(width: 120, alignment: .leading)
            rule.frame(width: 120, alignment: .leading)
            chain.frame(maxWidth: .infinity, alignment: .leading)
            traffic.frame(width: 84, alignment: .trailing)
        }
    }
}
