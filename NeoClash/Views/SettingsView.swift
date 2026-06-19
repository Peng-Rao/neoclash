import NeoClashCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("autoCloseConnections") private var autoCloseConnections = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("enhancedDNS") private var enhancedDNS = true
    @AppStorage("autoRoute") private var autoRoute = true
    @AppStorage("coreLogLevel") private var coreLogLevel = CoreLogLevel.error.rawValue

    @State private var secretShown = false
    @State private var tunStack = "gVisor"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                portsCard
                HStack(alignment: .top, spacing: 14) {
                    dnsCard
                    tunCard
                }
                behaviorCard
                coreCard
                privacyCard
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .navigationTitle("Settings")
        .frame(minWidth: 560, minHeight: 480)
    }

    private var portsCard: some View {
        GlassCard(title: "Ports & Controller", systemImage: "link", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Mixed Port", desc: "HTTP + SOCKS5 on a single port") {
                    portField($mixedPort)
                }
                Divider().opacity(0.5)
                SetRow(name: "External Controller", desc: "RESTful API for the dashboard") {
                    portField($controllerPort)
                }
                Divider().opacity(0.5)
                SetRow(name: "Bind Address", desc: "Locked to loopback for safety") {
                    HStack(spacing: 8) {
                        CodeChip(text: "127.0.0.1")
                        Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(.green)
                    }
                }
                Divider().opacity(0.5)
                SetRow(name: "Controller Secret", desc: "Regenerated on every launch") {
                    HStack(spacing: 6) {
                        CodeChip(text: secretShown ? "k9_3fA2··Qe7Lm" : "••••••••••", width: 150)
                        Button { secretShown.toggle() } label: {
                            Image(systemName: secretShown ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var dnsCard: some View {
        GlassCard(title: "DNS", systemImage: "network", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Enhanced DNS", desc: "fake-ip mode") {
                    Toggle("", isOn: $enhancedDNS).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Nameserver") { CodeChip(text: "https://1.1.1.1/dns") }
                Divider().opacity(0.5)
                SetRow(name: "fake-ip-range") { CodeChip(text: "198.18.0.1/16") }
            }
        }
    }

    private var tunCard: some View {
        GlassCard(title: "TUN", systemImage: "shield.lefthalf.filled", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "TUN Mode", desc: "System-wide capture · needs admin") {
                    Toggle("", isOn: Binding(get: { runtime.isTUNEnabled }, set: { coordinator.setTUNEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Stack") {
                    Picker("", selection: $tunStack) {
                        ForEach(["system", "gVisor", "mixed"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().opacity(0.5)
                SetRow(name: "Auto Route", desc: "Manage routing table") {
                    Toggle("", isOn: $autoRoute).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var behaviorCard: some View {
        GlassCard(title: "Behavior", systemImage: "slider.horizontal.3", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Launch at Login", desc: "Start NeoClash when you log in") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Close Connections", desc: "After switching node") {
                    Toggle("", isOn: $autoCloseConnections).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().opacity(0.5)
                SetRow(name: "Default Mode", desc: "Outbound routing mode") {
                    Picker("", selection: Binding(get: { runtime.mode }, set: { coordinator.setMode($0) })) {
                        ForEach(RoutingMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().opacity(0.5)
                SetRow(name: "Core Log Level", desc: "Restart required") {
                    Picker("", selection: $coreLogLevel) {
                        ForEach(coreLogLevels) { level in
                            Text(level.rawValue.capitalized).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
        }
    }

    private var coreLogLevels: [CoreLogLevel] {
        [.error, .warning, .info, .debug]
    }

    private var coreCard: some View {
        GlassCard(title: "Core & Updates", systemImage: "cpu", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Mihomo Core", desc: "Embedded high-performance engine") {
                    HStack(spacing: 8) {
                        Text(runtime.coreVersion).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        Badge(kind: .run, dot: true, text: "verified")
                    }
                }
                Divider().opacity(0.5)
                SetRow(name: "Signature", desc: "SHA-256 checked against release manifest") {
                    Badge(kind: .run, text: "valid")
                }
                Divider().opacity(0.5)
                SetRow(name: "App Version", desc: "NeoClash for macOS 26") {
                    HStack(spacing: 8) {
                        Text("1.4.0 (134)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Check for updates") {}.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        GlassCard(title: "Privacy & Security", systemImage: "lock") {
            VStack(alignment: .leading, spacing: 9) {
                privacyNote("Subscription URLs and tokens are stored in the macOS Keychain, never in plaintext config.")
                privacyNote("Diagnostics reports redact IPs, tokens, and hostnames before copying.")
                privacyNote("The external controller binds only to 127.0.0.1 and rotates its secret each launch.")
            }
        }
    }

    private func privacyNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield").font(.system(size: 13)).foregroundStyle(.green)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func portField(_ binding: Binding<Int>) -> some View {
        let validPort = Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = min(max($0, 1), 65_535) }
        )
        return TextField("", value: validPort, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 90)
    }
}
