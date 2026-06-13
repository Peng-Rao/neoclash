import NeoClashCore
import SwiftUI

struct RulesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var tab: Tab = .rules
    @State private var query = ""

    enum Tab: Hashable { case rules, providers }

    private var rules: [RuleEntry] {
        let source = runtime.rules.isEmpty ? Self.previewRules : runtime.rules
        guard !query.isEmpty else { return source }
        return source.filter { $0.displayText.localizedCaseInsensitiveContains(query) }
    }
    private var providers: [Provider] {
        guard !query.isEmpty else { return Self.sampleProviders }
        return Self.sampleProviders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text("Rules · \(runtime.rules.isEmpty ? Self.previewRules.count : runtime.rules.count)").tag(Tab.rules)
                    Text("Providers · \(Self.sampleProviders.count)").tag(Tab.providers)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                NCSearchField(text: $query, placeholder: tab == .rules ? "Search rules" : "Search providers", width: 220)
                Spacer()
                Button { Task { await coordinator.reloadRuntimeData() } } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small)
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
                    EmptyState(systemImage: "magnifyingglass", title: "No rules match", message: "Nothing matches “\(query)”.")
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("PROVIDER").frame(maxWidth: .infinity, alignment: .leading)
                Text("BEHAVIOR").frame(width: 110, alignment: .leading)
                Text("RULES").frame(width: 80, alignment: .trailing)
                Text("UPDATED").frame(width: 110, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            Divider().opacity(0.6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(providers) { p in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").font(.system(size: 13)).foregroundStyle(.secondary)
                                Text(p.name).font(.system(size: 12.5, weight: .semibold))
                                if p.stale { Badge(kind: .warn, text: "stale") }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(p.behavior).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text("\(p.count)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(width: 80, alignment: .trailing)
                            Text(p.updated).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    // MARK: Sample data

    struct Provider: Identifiable { let id = UUID(); var name: String; var behavior: String; var count: Int; var updated: String; var stale: Bool }

    static let sampleProviders: [Provider] = [
        .init(name: "reject", behavior: "domain", count: 9534, updated: "2h ago", stale: false),
        .init(name: "proxy", behavior: "classical", count: 412, updated: "2h ago", stale: false),
        .init(name: "direct", behavior: "domain", count: 7281, updated: "2 days ago", stale: true),
        .init(name: "telegramcidr", behavior: "ipcidr", count: 28, updated: "2h ago", stale: false)
    ]

    static let previewRules: [RuleEntry] = [
        RuleEntry(type: "DOMAIN-SUFFIX", payload: "apple.com", proxy: "DIRECT"),
        RuleEntry(type: "DOMAIN-SUFFIX", payload: "github.com", proxy: "Proxy"),
        RuleEntry(type: "DOMAIN-KEYWORD", payload: "openai", proxy: "AI"),
        RuleEntry(type: "GEOIP", payload: "CN", proxy: "DIRECT"),
        RuleEntry(type: "DOMAIN-SUFFIX", payload: "doubleclick.net", proxy: "REJECT"),
        RuleEntry(type: "MATCH", payload: "", proxy: "Proxy")
    ]
}
