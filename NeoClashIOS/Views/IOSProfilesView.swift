import NeoClashMobileCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSProfilesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @State private var isImporting = false
    @State private var showsAddSubscription = false

    /// Matches the macOS app's point for calling a subscription out of date.
    private static let staleInterval: TimeInterval = 2 * 24 * 60 * 60

    var body: some View {
        Group {
            if runtime.profiles.isEmpty {
                NCEmptyState(
                    systemImage: "doc.text",
                    title: "No profiles",
                    message: "Add a Clash subscription or import a YAML file to choose your proxies."
                ) {
                    Button("Add subscription") { showsAddSubscription = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import YAML file") { isImporting = true }
                }
            } else {
                profileList
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add subscription", systemImage: "link") { showsAddSubscription = true }
                    Button("Import YAML file", systemImage: "square.and.arrow.down") { isImporting = true }
                } label: {
                    Label("Add profile", systemImage: "plus")
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: yamlTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await coordinator.importLocalYAML(from: url) }
                }
            case .failure(let error):
                coordinator.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showsAddSubscription) {
            AddSubscriptionSheet()
        }
    }

    private var profileList: some View {
        List {
            ForEach(runtime.profiles) { profile in
                profileRow(profile)
                    .swipeActions(edge: .leading) {
                        if profile.kind == .remoteSubscription {
                            Button("Update", systemImage: "arrow.clockwise") {
                                Task { await coordinator.updateSubscription(profile) }
                            }
                            .tint(NC.indigo)
                        }
                    }
            }
            .onDelete { offsets in
                Task { await coordinator.deleteProfiles(at: offsets) }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await coordinator.loadProfiles()
        }
        .sensoryFeedback(.selection, trigger: runtime.activeProfile?.id)
    }

    private func profileRow(_ profile: ProxyProfile) -> some View {
        let isActive = runtime.activeProfile?.id == profile.id
        return Button {
            Task { await coordinator.applyProfile(profile) }
        } label: {
            HStack(spacing: 12) {
                Capsule()
                    .fill(NC.brandVertical)
                    .frame(width: 3, height: 30)
                    .opacity(isActive ? 1 : 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.body.weight(isActive ? .semibold : .regular))
                    Text(subtitle(for: profile))
                        .font(.caption)
                        .foregroundStyle(isStale(profile) ? AnyShapeStyle(NC.warn) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(profile.kind == .remoteSubscription ? "Swipe right to update" : "")
    }

    private func isStale(_ profile: ProxyProfile) -> Bool {
        guard profile.kind == .remoteSubscription, let updated = profile.lastUpdatedAt else {
            return false
        }
        return Date().timeIntervalSince(updated) > Self.staleInterval
    }

    private func subtitle(for profile: ProxyProfile) -> String {
        guard profile.kind == .remoteSubscription else {
            return "YAML file"
        }
        guard let updated = profile.lastUpdatedAt else {
            return "Subscription, never updated"
        }
        return "Subscription, updated \(updated.formatted(.relative(presentation: .named)))"
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
