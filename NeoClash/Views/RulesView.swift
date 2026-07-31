import NeoClashCore
import SwiftUI

struct RulesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var tab: Tab = .rules
    @State private var query = ""

    enum Tab: Hashable { case rules, providers }

    private var rules: [RuleEntry] {
        guard !query.isEmpty else { return runtime.rules }
        return runtime.rules.filter { $0.displayText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text("Rules · \(runtime.rules.count)").tag(Tab.rules)
                    Text("Providers · unavailable").tag(Tab.providers)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if tab == .rules {
                    NCSearchField(text: $query, placeholder: "Search rules", width: 220)
                }
                Spacer()
                Button { Task { await coordinator.reloadRuntimeData() } } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!runtime.status.isRunning)
                .help(runtime.status.isRunning ? "Refresh rules from the running core" : "Start the core to refresh rules")
            }

            GlassCard(padded: false) {
                if tab == .rules { rulesTable } else { providersTable }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .navigationTitle("Rules")
    }

    // MARK: Rules table

    private var rulesTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("#").frame(width: 34, alignment: .leading)
                Text("TYPE").frame(width: 170, alignment: .leading)
                Text("PAYLOAD").frame(maxWidth: .infinity, alignment: .leading)
                Text("TARGET").frame(width: 110, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            Divider().opacity(0.6)
            ScrollView {
                if rules.isEmpty {
                    EmptyState(
                        systemImage: query.isEmpty ? "doc.plaintext" : "magnifyingglass",
                        title: emptyRulesTitle,
                        message: emptyRulesMessage
                    )
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                            HStack(spacing: 12) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                    .frame(width: 34, alignment: .leading)
                                Text(rule.type)
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 170, alignment: .leading)
                                Group {
                                    if rule.payload.isEmpty {
                                        Text("— fallback —").foregroundStyle(.tertiary)
                                    } else {
                                        Text(rule.payload).fontWeight(.medium)
                                    }
                                }
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                HStack { Spacer(); targetBadge(rule.proxy) }.frame(width: 110)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func targetBadge(_ target: String) -> some View {
        let kind: Badge.Kind = target == "REJECT" ? .err : target == "DIRECT" ? .neutral : .accent
        return Badge(kind: kind, text: target)
    }

    // MARK: Providers table

    private var providersTable: some View {
        EmptyState(
            systemImage: "shippingbox",
            title: "Provider data unavailable",
            message: "NeoClash does not currently load rule-provider status from the core. No sample data is shown."
        )
    }

    private var emptyRulesTitle: String {
        if !query.isEmpty { return "No rules match" }
        return runtime.status.isRunning ? "No rule data" : "Core not running"
    }

    private var emptyRulesMessage: String {
        if !query.isEmpty { return "Nothing matches “\(query)”." }
        if runtime.status.isRunning {
            return "The running core returned no rules. Refresh after its configuration finishes loading."
        }
        return "Start the Mihomo core to load its active routing rules."
    }
}
