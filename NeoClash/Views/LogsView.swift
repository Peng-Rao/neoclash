import NeoClashCore
import AppKit
import SwiftUI

struct LogsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var selectedLevel: CoreLogLevel?
    @State private var isPaused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Logs")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Picker("Level", selection: $selectedLevel) {
                    Text("All").tag(CoreLogLevel?.none)
                    ForEach(CoreLogLevel.allCases) { level in
                        Text(level.rawValue.capitalized).tag(CoreLogLevel?.some(level))
                    }
                }
                .frame(width: 160)
                Toggle(isOn: $isPaused) {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .toggleStyle(.button)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runtime.logs.map(\.message).joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
            }

            GlassPanel {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption2.weight(.bold).monospaced())
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 58, alignment: .leading)
                                Text(entry.message)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 440)
            }
        }
        .padding(24)
        .navigationTitle("Logs")
    }

    private var filteredLogs: [CoreLogEntry] {
        let source = isPaused ? runtime.logs : runtime.logs
        guard let selectedLevel else {
            return source
        }
        return source.filter { $0.level == selectedLevel }
    }

    private func color(for level: CoreLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
