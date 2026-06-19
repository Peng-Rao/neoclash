import NeoClashMobileCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSProfilesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var isImporting = false
    @State private var showsAddSubscription = false

    var body: some View {
        List {
            if runtime.profiles.isEmpty {
                MobileEmptyState(
                    systemImage: "doc.text",
                    title: "No profiles",
                    message: "Import a local YAML file or add a remote subscription."
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Profiles") {
                    ForEach(runtime.profiles) { profile in
                        profileRow(profile)
                    }
                    .onDelete { offsets in
                        Task { await coordinator.deleteProfiles(at: offsets) }
                    }
                }
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                Button {
                    showsAddSubscription = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: yamlTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await coordinator.importLocalYAML(from: url) }
            }
        }
        .sheet(isPresented: $showsAddSubscription) {
            AddSubscriptionSheet()
        }
        .refreshable {
            await coordinator.loadProfiles()
        }
    }

    private func profileRow(_ profile: ProxyProfile) -> some View {
        let isActive = runtime.activeProfile?.id == profile.id
        return Button {
            coordinator.applyProfile(profile)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: profile.kind == .localYAML ? "doc" : "arrow.down.circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.body.weight(.semibold))
                        if isActive {
                            Text("Active")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(subtitle(for: profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profile.kind == .remoteSubscription {
                    Button {
                        coordinator.applyProfile(profile)
                        Task { await coordinator.updateSelectedSubscription() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func subtitle(for profile: ProxyProfile) -> String {
        let kind = profile.kind == .localYAML ? "Local YAML" : "Subscription"
        let updated = profile.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never updated"
        return "\(kind) - \(updated)"
    }

    private var yamlTypes: [UTType] {
        [UTType(filenameExtension: "yaml") ?? .text, UTType(filenameExtension: "yml") ?? .text, .text]
    }
}

private struct AddSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var name = ""
    @State private var urlString = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("Add Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = name
                        let urlString = urlString
                        Task { await coordinator.addSubscription(name: name, urlString: urlString) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || urlString.isEmpty)
                }
            }
        }
    }
}
