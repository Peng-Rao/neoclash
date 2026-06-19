import NeoClashMobileCore
import SwiftUI

struct IOSLogsView: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        List {
            if runtime.logs.isEmpty {
                MobileEmptyState(
                    systemImage: "text.alignleft",
                    title: "No logs yet",
                    message: "Runtime and tunnel events will appear here."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(runtime.logs.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(for: entry.level))
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.message)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Logs")
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
