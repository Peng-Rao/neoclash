import NeoClashMobileCore
import SwiftUI

private enum ActivityPane: String, CaseIterable, Identifiable {
    case connections = "Connections"
    case logs = "Logs"
    case rules = "Rules"

    var id: String { rawValue }
}

struct IOSActivityView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var pane = ActivityPane.connections
    @State private var searchText = ""
    @State private var logLevel: CoreLogLevel?
    @State private var pausedLogs: [CoreLogEntry]?

    var body: some View {
        Group {
            switch pane {
            case .connections: connections
            case .logs: logs
            case .rules: rules
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $pane) {
                    ForEach(ActivityPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                paneAction
            }
        }
    }

    @ViewBuilder
    private var paneAction: some View {
        switch pane {
        case .connections:
            Button {
                Task { await coordinator.closeAllConnections() }
            } label: {
                Label("Close all connections", systemImage: "xmark.circle")
            }
            .disabled(runtime.connections.isEmpty)
        case .logs:
            Menu {
                Picker("Level", selection: $logLevel) {
                    Text("All levels").tag(CoreLogLevel?.none)
                    ForEach(CoreLogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(CoreLogLevel?.some(level))
                    }
                }
                Button(pausedLogs == nil ? "Pause" : "Resume") {
                    pausedLogs = pausedLogs == nil ? runtime.logs : nil
                }
            } label: {
                Label("Log options", systemImage: "line.3.horizontal.decrease")
            }
        case .rules:
            EmptyView()
        }
    }

    @ViewBuilder
    private var connections: some View {
        if !runtime.status.isRunning {
            StoppedState(title: "No connections", message: "Start NeoClash to see live connections.")
        } else if filteredConnections.isEmpty {
            NCEmptyState(systemImage: "network", title: "No connections", message: emptyMessage("Connections appear here as they open."))
        } else {
            List(filteredConnections) { connection in
                ConnectionRow(connection: connection)
                    .swipeActions {
                        Button("Close", role: .destructive) {
                            Task { await coordinator.closeConnection(id: connection.id) }
                        }
                    }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var logs: some View {
        if filteredLogs.isEmpty {
            NCEmptyState(systemImage: "text.alignleft", title: "No logs", message: emptyMessage("Core messages appear here while it runs."))
        } else {
            List(filteredLogs.reversed()) { entry in
                LogRow(entry: entry)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var rules: some View {
        if !runtime.status.isRunning {
            StoppedState(title: "No rules", message: "Start NeoClash to see the rules in your profile.")
        } else if filteredRules.isEmpty {
            NCEmptyState(systemImage: "list.bullet", title: "No rules", message: emptyMessage("This profile has no rules."))
        } else {
            List(filteredRules) { rule in
                RuleRow(rule: rule)
            }
            .listStyle(.plain)
        }
    }

    private func emptyMessage(_ message: String) -> String {
        searchText.isEmpty ? message : "Nothing matches \"\(searchText)\"."
    }

    private var filteredConnections: [ConnectionEntry] {
        guard !searchText.isEmpty else {
            return runtime.connections
        }
        return runtime.connections.filter {
            $0.host.localizedCaseInsensitiveContains(searchText)
                || $0.exitNode.localizedCaseInsensitiveContains(searchText)
                || ($0.rule ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredLogs: [CoreLogEntry] {
        (pausedLogs ?? runtime.logs).filter { entry in
            (logLevel == nil || entry.level == logLevel)
                && (searchText.isEmpty || entry.message.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var filteredRules: [RuleEntry] {
        guard !searchText.isEmpty else {
            return runtime.rules
        }
        return runtime.rules.filter {
            $0.payload.localizedCaseInsensitiveContains(searchText)
                || $0.proxy.localizedCaseInsensitiveContains(searchText)
                || $0.type.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct ConnectionRow: View {
    var connection: ConnectionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(connection.host)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Text(connection.exitNode)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Image(systemName: "arrow.down"))\(byteString(connection.download))")
                Text("\(Image(systemName: "arrow.up"))\(byteString(connection.upload))")
            }
            .ncMono(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LogRow: View {
    var entry: CoreLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(color)
            Text(entry.message)
                .ncMono(.caption2, weight: .regular)
                .lineLimit(6)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = entry.message
            }
        }
    }

    private var color: Color {
        switch entry.level {
        case .error: NC.danger
        case .warning: NC.warn
        case .debug, .info: .secondary
        }
    }
}

private struct RuleRow: View {
    var rule: RuleEntry

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.payload.isEmpty ? rule.type : rule.payload)
                    .ncMono(.caption, weight: .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rule.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(rule.proxy)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
