import NeoClashCore
import SwiftUI

struct RulesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var searchText = ""

    private let placeholderRules = [
        "DOMAIN-SUFFIX,apple.com,DIRECT",
        "DOMAIN-SUFFIX,github.com,Proxy",
        "GEOIP,CN,DIRECT",
        "MATCH,Proxy"
    ]

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
                    runtime.appendLog(level: .info, "Rule refresh requested")
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }

            GlassPanel {
                List(filteredRules, id: \.self) { rule in
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundStyle(.secondary)
                        Text(rule)
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

    private var filteredRules: [String] {
        guard !searchText.isEmpty else {
            return placeholderRules
        }
        return placeholderRules.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
}

