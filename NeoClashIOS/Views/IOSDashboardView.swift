import NeoClashMobileCore
import SwiftUI

struct IOSDashboardView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @AppStorage("allowLan") private var allowLAN = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                profileCard
                trafficCard
                implementationCard
            }
            .padding(16)
            .padding(.bottom, 72)
        }
        .navigationTitle("NeoClash")
        .refreshable {
            await coordinator.refreshTunnelState()
        }
    }

    private var statusCard: some View {
        MobileCard(title: "Packet Tunnel", systemImage: "shield.lefthalf.filled") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(runtime.status.label)
                            .font(.largeTitle.bold())
                            .foregroundStyle(runtime.status.tint)
                        Text("VPN status: \(coordinator.tunnelStatus.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MobileStatusPill(text: coordinator.tunnelConfigurationState.label, color: coordinator.tunnelStatus.tint)
                }

                Picker("Mode", selection: Binding(get: { runtime.mode }, set: { coordinator.setMode($0) })) {
                    ForEach(RoutingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Enable packet tunnel config", isOn: Binding(get: {
                    runtime.isTUNEnabled
                }, set: {
                    coordinator.setTUNEnabled($0)
                }))
                .toggleStyle(.switch)

                Toggle("Allow LAN", isOn: $allowLAN)
                    .toggleStyle(.switch)

                if let error = coordinator.lastTunnelError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                tunnelActionButtons
            }
        }
    }

    private var tunnelActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                prepareButton
                startButton
                stopButton
            }

            VStack(spacing: 8) {
                prepareButton
                HStack(spacing: 8) {
                    startButton
                    stopButton
                }
            }
        }
        .controlSize(.regular)
    }

    private var prepareButton: some View {
        Button {
            Task { await coordinator.prepareTunnel() }
        } label: {
            actionLabel("Prepare", systemImage: "gearshape.2")
        }
        .buttonStyle(.bordered)
        .disabled(coordinator.isBusy)
    }

    private var startButton: some View {
        Button {
            Task { await coordinator.startTunnel() }
        } label: {
            actionLabel("Start", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(coordinator.isBusy)
    }

    private var stopButton: some View {
        Button {
            Task { await coordinator.stopTunnel() }
        } label: {
            actionLabel("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .disabled(coordinator.isBusy)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: 30)
    }

    private var profileCard: some View {
        MobileCard(title: "Active Profile", systemImage: "doc.text") {
            if let profile = runtime.activeProfile {
                MobileMetricRow(
                    systemImage: profile.kind == .localYAML ? "doc" : "arrow.down.circle",
                    title: profile.name,
                    value: profile.kind == .localYAML ? "Local" : "Subscription",
                    subtitle: profile.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not updated yet"
                )
            } else {
                MobileEmptyState(
                    systemImage: "doc.badge.plus",
                    title: "No profile selected",
                    message: "Import a YAML file or add a subscription from the Profiles tab."
                )
            }
        }
    }

    private var trafficCard: some View {
        MobileCard(title: "Session", systemImage: "chart.xyaxis.line") {
            VStack(spacing: 12) {
                MobileMetricRow(
                    systemImage: "arrow.up",
                    title: "Upload",
                    value: byteString(runtime.sessionUploadBytes),
                    subtitle: "\(byteString(runtime.traffic.uploadPerSecond))/s"
                )
                MobileMetricRow(
                    systemImage: "arrow.down",
                    title: "Download",
                    value: byteString(runtime.sessionDownloadBytes),
                    subtitle: "\(byteString(runtime.traffic.downloadPerSecond))/s"
                )
            }
        }
    }

    private var implementationCard: some View {
        MobileCard(title: "iOS Runtime Note", systemImage: "info.circle") {
            Text("This iOS target is wired like the reference app: the main app prepares shared config and controls a packet tunnel extension. The extension currently reports that no embedded iOS VPN engine is bundled yet, so routing will require integrating a Libclash/Mihomo mobile core next.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
