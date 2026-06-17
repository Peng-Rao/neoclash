import AppKit
import NeoClashCore
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false

    var body: some View {
        @Bindable var runtime = runtime
        let running = runtime.status.isRunning

        VStack(spacing: 8) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor, .ncViolet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                        .overlay(Image(systemName: "bolt.horizontal.fill").font(.system(size: 12)).foregroundStyle(.white))
                    Text("NeoClash").font(.system(size: 14, weight: .bold))
                }
                Spacer()
                Button { startOrStop() } label: {
                    HStack(spacing: 6) {
                        StatusDot(color: running ? .ncRun : .secondary, size: 7, glow: false)
                        Text(running ? "Running" : "Stopped")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(running ? Color.ncRun : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            // Traffic card
            VStack(spacing: 6) {
                HStack {
                    Label("\(runtime.connections.count)", systemImage: "link")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor)
                    Spacer()
                    Label(runtime.traffic.uploadPerSecond.bytesPerSecondString, systemImage: "arrow.up")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor)
                }
                HStack {
                    Label(runtime.coreVersion == "Not running" ? "—" : "core", systemImage: "memorychip")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.ncViolet)
                    Spacer()
                    Label(runtime.traffic.downloadPerSecond.bytesPerSecondString, systemImage: "arrow.down")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.ncRun)
                }
            }
            .labelStyle(.titleAndIcon)
            .padding(10)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08), lineWidth: 1))

            Divider()

            modeSelector

            Divider()

            // Quick toggles
            menuToggle("System Proxy", systemImage: "globe",
                       isOn: Binding(get: { runtime.isSystemProxyEnabled },
                                     set: { coordinator.setSystemProxyEnabled($0) }))
            menuToggle("TUN / Enhanced Mode", systemImage: "shield.lefthalf.filled", isOn: $runtime.isTUNEnabled)

            Divider()

            // Proxy groups
            if !runtime.proxies.isEmpty {
                ForEach(runtime.proxies.prefix(6)) { group in
                    HStack(spacing: 8) {
                        Image(systemName: "globe.asia.australia").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(group.name).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(group.now ?? "—").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                Divider()
            }

            // Footer actions
            HStack(spacing: 8) {
                Button { startOrStop() } label: {
                    Label(running ? "Stop Core" : "Start Core", systemImage: running ? "stop.fill" : "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? .red : .accentColor)

                Button { quit() } label: {
                    Label("Quit", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Outbound Mode", systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(runtime.mode.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(RoutingMode.allCases) { mode in
                    Button {
                        coordinator.setMode(mode)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                                .opacity(runtime.mode == mode ? 1 : 0)
                                .frame(width: 12)
                            Text(mode.displayName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(runtime.mode == mode ? Color.accentColor : Color.primary)
                    .background(
                        runtime.mode == mode ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
                        in: .rect(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(runtime.mode == mode ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07), lineWidth: 1)
                    }
                }
            }
            .animation(.snappy(duration: 0.2), value: runtime.mode)
        }
    }

    private func menuToggle(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage).font(.system(size: 12.5))
        }
        .toggleStyle(.switch).controlSize(.small)
    }

    private func startOrStop() {
        Task {
            if runtime.status.isRunning { await coordinator.stop() }
            else { await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLan) }
        }
    }

    private func quit() {
        Task { @MainActor in
            if runtime.status != .stopped {
                await coordinator.stop()
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
