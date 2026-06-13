import NeoClashCore
import SwiftUI

struct RulesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rules")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Button {
                    Task {
                        await coordinator.reloadRuntimeData()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }

            GlassPanel {
                List(filteredRules) { rule in
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                        Text(rule.displayText)
                            .font(.callout.monospaced())
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 440)
            }
        }
        .padding(24)
        .navigationTitle("Rules")
    }

    private var filteredRules: [RuleEntry] {
        let source = runtime.rules.isEmpty ? previewRules : runtime.rules
        guard !searchText.isEmpty else {
            return source
        }
        return source.filter { $0.displayText.localizedCaseInsensitiveContains(searchText) }
    }

    private var previewRules: [RuleEntry] {
        [
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
            RuleEntry(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
            RuleEntry(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
            RuleEntry(type: "MATCH", payload: "", proxy: "Proxy")
        ]
    }
}
