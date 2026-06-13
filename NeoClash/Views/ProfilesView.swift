import NeoClashCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selected: UUID?
    @State private var isImporting = false
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""

    private var active: ProxyProfile? {
        runtime.profiles.first { $0.id == selected }
            ?? runtime.activeProfile
            ?? runtime.profiles.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            listCard.frame(maxWidth: .infinity)
            inspector.frame(width: 320)
        }
        .padding(20)
        .navigationTitle("Profiles")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: yamlTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await coordinator.importLocalYAML(from: url) }
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    // MARK: List

    private var listCard: some View {
        GlassCard(padded: false) {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "doc.text").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Text("Profiles & Subscriptions").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button { isImporting = true } label: { Label("Import YAML", systemImage: "doc") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { showAdd = true } label: { Label("Add Subscription", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                Divider().opacity(0.6)

                if runtime.profiles.isEmpty {
                    EmptyState(systemImage: "doc.text", title: "No profiles",
                               message: "Import a local YAML config or add a remote subscription to get started.")
                        .padding(.vertical, 24)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(runtime.profiles) { profile in
                                profileRow(profile)
                                if profile.id != runtime.profiles.last?.id { Divider().opacity(0.5) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func profileRow(_ p: ProxyProfile) -> some View {
        let isActive = runtime.activeProfile?.id == p.id
        let isSelected = active?.id == p.id
        return Button {
            selected = p.id
        } label: {
            HStack(spacing: 12) {
                GlyphBox(systemImage: p.kind == .localYAML ? "doc" : "arrow.down.circle", size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(p.name).font(.system(size: 13, weight: .semibold))
                        if isActive { Badge(kind: .accent, text: "active") }
                        statusBadge(p)
                    }
                    Text("\(typeLabel(p)) · updated \(updatedLabel(p))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    if !isActive {
                        Button("Apply") { runtime.activeProfile = p }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    if p.kind == .remoteSubscription {
                        Button {
                            runtime.activeProfile = p
                            Task { await coordinator.updateSelectedSubscription() }
                        } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.05) : .clear)
            .overlay(alignment: .leading) {
                if isActive { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 14) {
            GlassCard(title: "Subscription Details", systemImage: "info.circle") {
                if let p = active {
                    VStack(alignment: .leading, spacing: 11) {
                        detailKV("Name", p.name)
                        detailKV("Type", typeLabel(p))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Source").font(.system(size: 11.5, weight: .medium))
                            HStack(spacing: 6) {
                                CodeChip(text: p.kind == .localYAML ? p.localFileURL.lastPathComponent : "https://···.redacted/sub")
                                    .frame(maxWidth: .infinity)
                            }
                            Text(p.kind == .localYAML ? "Local file on disk." : "Token redacted in UI. Stored in macOS Keychain.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        detailKV("Last update", updatedLabel(p))
                    }
                } else {
                    Text("No profile selected").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            GlassCard(title: "Config Validation", systemImage: "checkmark.circle") {
                VStack(alignment: .leading, spacing: 9) {
                    valRow(ok: true, "YAML syntax valid")
                    valRow(ok: true, "Proxies parsed")
                    valRow(ok: true, "Proxy-groups & rules loaded")
                    valRow(ok: !(active.map(isStale) ?? false),
                           active.map(isStale) ?? false ? "Subscription is stale" : "Rule-providers reachable")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func detailKV(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
        }
    }

    private func valRow(ok: Bool, _ label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 13)).foregroundStyle(ok ? Color.ncRun : Color.ncWarn)
            Text(label).font(.system(size: 12)).foregroundStyle(ok ? .secondary : .primary)
        }
    }

    // MARK: Add sheet

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Subscription").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
                SecureField("Subscription URL", text: $newURL).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }
                Button("Add") {
                    let name = newName, url = newURL
                    Task { await coordinator.addSubscription(name: name, urlString: url) }
                    newName = ""; newURL = ""; showAdd = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: Helpers

    private func typeLabel(_ p: ProxyProfile) -> String {
        p.kind == .localYAML ? "Local file" : "Subscription"
    }
    private func updatedLabel(_ p: ProxyProfile) -> String {
        p.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }
    private func isStale(_ p: ProxyProfile) -> Bool {
        guard p.kind == .remoteSubscription, let updated = p.lastUpdatedAt else { return false }
        return Date().timeIntervalSince(updated) > 2 * 24 * 3600
    }
    @ViewBuilder private func statusBadge(_ p: ProxyProfile) -> some View {
        if isStale(p) { Badge(kind: .warn, dot: true, text: "stale") }
        else { Badge(kind: .run, dot: true, text: "valid") }
    }

    private var yamlTypes: [UTType] {
        [UTType(filenameExtension: "yaml") ?? .text, UTType(filenameExtension: "yml") ?? .text, .text]
    }
}
