import NeoClashCore
import AppKit
import SwiftUI

struct LogsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var level: CoreLogLevel?
    @State private var query = ""
    @State private var frozen: [CoreLogEntry]?

    private var isPaused: Bool { frozen != nil }

    private var source: [CoreLogEntry] { frozen ?? runtime.logs }

    private var filtered: [CoreLogEntry] {
        source.reversed().filter { entry in
            (level == nil || entry.level == level)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if case .crashed(let message) = runtime.status {
                DiagnosticBanner(message: message, onRetry: {}, openLogs: {})
            }

            toolbar

            GlassCard(padded: false) {
                VStack(spacing: 0) {
                    statusBar
                    Divider().opacity(0.6)
                    ScrollView {
                        if filtered.isEmpty {
                            EmptyState(systemImage: "text.alignleft", title: "No logs",
                                       message: runtime.status.isRunning ? "Adjust the level filter or search query." : "Start the core to see live routing and DNS events.")
                                .padding(.vertical, 30)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { logLine($0) }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle("Logs")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $level) {
                Text("All").tag(CoreLogLevel?.none)
                ForEach(CoreLogLevel.allCases) { lvl in
                    Text(lvl.rawValue.capitalized).tag(CoreLogLevel?.some(lvl))
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            NCSearchField(text: $query, placeholder: "Search logs", width: 220)
            Spacer()
            Toggle(isOn: Binding(get: { isPaused }, set: { paused in
                frozen = paused ? runtime.logs : nil
            })) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .toggleStyle(.button).controlSize(.small)

            Button { runtime.logs.removeAll(); frozen = nil } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.map(\.message).joined(separator: "\n"), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private var statusBar: some View {
        let streaming = runtime.status.isRunning && !isPaused
        return HStack {
            Text("\(filtered.count) lines").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: streaming ? .ncRun : .secondary, size: 7, glow: false)
                Text(!runtime.status.isRunning ? "core stopped" : isPaused ? "paused" : "streaming")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private func logLine(_ entry: CoreLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.date.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(entry.level.rawValue.uppercased())
                .fontWeight(.bold)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 52, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private func color(for level: CoreLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .accentColor
        case .warning: .ncWarn
        case .error: .ncDanger
        }
    }
}
