import NeoClashMobileCore
import SwiftUI

struct IOSProxiesView: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        List {
            if runtime.proxies.isEmpty {
                MobileEmptyState(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "No proxy groups",
                    message: "Proxy data appears after a mobile core exposes the Mihomo controller API."
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(runtime.proxies) { group in
                    Section(group.name) {
                        ForEach(group.nodes) { node in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.name)
                                        .font(.body.weight(node.isSelected ? .semibold : .regular))
                                    Text(node.type ?? "Proxy")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if node.isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                                Text(delayLabel(node.delay))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(delayColor(node.delay))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Proxies")
    }

    private func delayLabel(_ delay: Int?) -> String {
        guard let delay, delay > 0 else {
            return "timeout"
        }
        return "\(delay) ms"
    }

    private func delayColor(_ delay: Int?) -> Color {
        guard let delay, delay > 0 else {
            return .secondary
        }
        if delay < 80 {
            return .green
        }
        if delay < 160 {
            return .orange
        }
        return .red
    }
}
