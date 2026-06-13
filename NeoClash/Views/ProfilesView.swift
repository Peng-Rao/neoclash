import NeoClashCore
import SwiftUI

struct ProfilesView: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var subscriptionURL = ""
    @State private var profileName = ""

    var body: some View {
        @Bindable var runtime = runtime

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Profiles")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Button {
                    runtime.appendLog(level: .info, "Import local YAML requested")
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
                            runtime.appendLog(level: .info, "Add subscription requested: \(profileName)")
                            subscriptionURL = ""
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
    }
}
