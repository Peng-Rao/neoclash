import NeoClashCore
import SwiftUI

struct UnlockTestView: View {
    @Environment(RuntimeStore.self) private var runtime
    @AppStorage("mixedPort") private var mixedPort = 7897
    @State private var results: [UnlockTestService.Service: UnlockTestService.Result] = [:]
    @State private var testing: Set<UnlockTestService.Service> = []

    var body: some View {
        Group {
            if !runtime.status.isRunning {
                EmptyState(systemImage: "lock.open", title: "Core not running",
                           message: "Start the Mihomo core to test which services the current proxy exit unlocks.")
            } else {
                VStack(spacing: 14) {
                    header
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(UnlockTestService.Service.allCases) { service in
                                UnlockCard(
                                    service: service,
                                    result: results[service],
                                    testing: testing.contains(service)
                                ) {
                                    test([service])
                                }
                            }
                        }
                        .animation(.snappy(duration: 0.2), value: results)
                        .animation(.snappy(duration: 0.2), value: testing)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Unlock Test")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unlock Test").font(.system(size: 15, weight: .semibold))
                Text("Checks run through the proxy (127.0.0.1:\(mixedPort)) — results reflect the current exit node.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                test(UnlockTestService.Service.allCases)
            } label: {
                if testing.isEmpty {
                    Label("Test All", systemImage: "bolt.fill")
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Testing \(UnlockTestService.Service.allCases.count - testing.count)/\(UnlockTestService.Service.allCases.count)")
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!testing.isEmpty)
            .frame(minWidth: 112)
        }
    }

    private func test(_ services: [UnlockTestService.Service]) {
        let pending = services.filter { !testing.contains($0) }
        guard !pending.isEmpty else { return }
        testing.formUnion(pending)
        let prober = UnlockTestService(proxyPort: mixedPort)
        for service in pending {
            Task {
                let result = await prober.test(service)
                results[service] = result
                testing.remove(service)
            }
        }
    }
}

private struct UnlockCard: View {
    var service: UnlockTestService.Service
    var result: UnlockTestService.Result?
    var testing: Bool
    var retest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(service.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button(action: retest) {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .disabled(testing)
                .help("Retest \(service.displayName)")
            }

            HStack(spacing: 8) {
                statusBadge
                if let region = result?.region, !region.isEmpty {
                    regionPill(region)
                }
                Spacer()
            }
            .frame(height: 22)

            Divider().opacity(0.5)

            HStack {
                Spacer()
                Text(result.map { Self.timestampFormatter.string(from: $0.testedAt) } ?? "Not tested")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if testing {
            capsuleLabel("Testing", systemImage: "hourglass", color: .secondary)
        } else {
            switch result?.status {
            case .unlocked:
                capsuleLabel("Yes", systemImage: "checkmark.circle", color: .ncRun)
            case .locked:
                capsuleLabel("No", systemImage: "xmark.circle", color: .ncDanger)
            case .failed:
                capsuleLabel("Failed", systemImage: "questionmark.circle", color: .ncWarn)
            case nil:
                capsuleLabel("—", systemImage: "circle.dashed", color: .secondary)
            }
        }
    }

    private func capsuleLabel(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((color == .secondary ? Color.primary : color).opacity(0.12), in: .capsule)
    }

    private func regionPill(_ region: String) -> some View {
        HStack(spacing: 4) {
            if let flag = UnlockTestService.flagEmoji(forRegion: region) {
                Text(flag).font(.system(size: 11))
            }
            Text(region.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: .capsule)
        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
