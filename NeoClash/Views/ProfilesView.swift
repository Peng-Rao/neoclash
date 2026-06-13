import NeoClashCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @State private var subscriptionURL = ""
    @State private var profileName = ""
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Profiles")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glass)
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Subscription")
                        .font(.headline)
                    HStack {
                        TextField("Name", text: $profileName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        SecureField("URL", text: $subscriptionURL)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            let name = profileName
                            let url = subscriptionURL
                            Task {
                                await coordinator.addSubscription(name: name, urlString: url)
                                subscriptionURL = ""
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .buttonStyle(.glass)
                        .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subscriptionURL.isEmpty)
                    }
                }
            }

            GlassPanel {
                List(runtime.profiles) { profile in
                    Button {
                        runtime.activeProfile = profile
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: runtime.activeProfile?.id == profile.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(runtime.activeProfile?.id == profile.id ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.headline)
                                Text(profile.kind == .localYAML ? "Local YAML" : "Remote Subscription")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(profile.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 360)
            }
        }
        .padding(24)
        .navigationTitle("Profiles")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: yamlContentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                Task {
                    await coordinator.importLocalYAML(from: url)
                }
            case .failure(let error):
                runtime.reportError("Import profile failed", diagnostics: error.localizedDescription)
            }
        }
    }

    private var yamlContentTypes: [UTType] {
        [
            UTType(filenameExtension: "yaml") ?? .text,
            UTType(filenameExtension: "yml") ?? .text,
            .text
        ]
    }
}
