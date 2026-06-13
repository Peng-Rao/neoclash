import NeoClashCore
import SwiftUI

struct ConnectionsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connections")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button {
                    Task {
                        await coordinator.closeAllConnections()
                    }
                } label: {
                    Label("Close All", systemImage: "xmark.circle")
                }
                .buttonStyle(.glass)
            }

            GlassPanel {
                Table(filteredConnections) {
                    TableColumn("Destination") { connection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connection.host)
                            if let process = connection.process {
                                Text(process)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Rule") { connection in
                        Text(connection.rule ?? "-")
                    }
                    TableColumn("Chain") { connection in
                        Text(connection.chain.joined(separator: " -> "))
                            .lineLimit(1)
                    }
                    TableColumn("Upload") { connection in
                        Text(connection.upload.bytesPerSecondString)
                            .font(.caption.monospacedDigit())
                    }
                    TableColumn("Download") { connection in
                        Text(connection.download.bytesPerSecondString)
                            .font(.caption.monospacedDigit())
                    }
                }
                .frame(minHeight: 440)
            }
        }
        .padding(24)
        .navigationTitle("Connections")
    }

    private var filteredConnections: [ConnectionEntry] {
        guard !searchText.isEmpty else {
            return runtime.connections
        }
        return runtime.connections.filter {
            $0.host.localizedCaseInsensitiveContains(searchText)
                || ($0.process?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.rule?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
}
