import NeoClashCore
import SwiftUI

// ============================================================
//  Engine pages — the sidebar's Engine section. Each page hosts
//  the matching settings cards inside the main window.
// ============================================================

struct EngineGeneralView: View {
    var body: some View {
        GeneralSettingsView()
            .navigationTitle("General")
    }
}

struct EngineNetworkView: View {
    var body: some View {
        SettingsScaffold {
            PortsControllerCard()
            BehaviorSettingsCard()
        }
        .navigationTitle("Network")
    }
}

struct EngineDNSView: View {
    var body: some View {
        SettingsScaffold {
            DNSSettingsCard()
        }
        .navigationTitle("DNS")
    }
}

struct EngineTUNView: View {
    var body: some View {
        SettingsScaffold {
            TUNSettingsCard()
        }
        .navigationTitle("TUN")
    }
}

struct EngineSnifferView: View {
    var body: some View {
        SettingsScaffold {
            snifferCard
            protocolsCard
        }
        .navigationTitle("Sniffer")
    }

    /// Mirrors `RuntimeConfigBuilder.defaultSniffer()` — the block NeoClash injects
    /// when a profile ships no `sniffer:` section of its own.
    private var snifferCard: some View {
        GlassCard(title: "Domain Sniffing", systemImage: "scope", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "Sniffer", desc: "Recover domains for flows opened by raw IP") {
                    Badge(kind: .run, dot: true, text: "enabled")
                }
                Divider().opacity(0.5)
                SetRow(name: "Force DNS Mapping", desc: "Apply sniffed names to DNS mappings") {
                    Badge(kind: .run, text: "on")
                }
                Divider().opacity(0.5)
                SetRow(name: "Parse Pure IP", desc: "Sniff flows the client dialed by address") {
                    Badge(kind: .run, text: "on")
                }
                Divider().opacity(0.5)
                SetRow(name: "Override Destination", desc: "Keep the sniffed name as metadata only") {
                    Badge(kind: .neutral, text: "off")
                }
            }
        }
    }

    private var protocolsCard: some View {
        GlassCard(title: "Sniffed Protocols", systemImage: "waveform.badge.magnifyingglass", padded: false) {
            VStack(spacing: 0) {
                SetRow(name: "HTTP") { CodeChip(text: "80, 8080-8880") }
                Divider().opacity(0.5)
                SetRow(name: "TLS") { CodeChip(text: "443, 8443") }
                Divider().opacity(0.5)
                SetRow(name: "QUIC") { CodeChip(text: "443, 8443") }
                Divider().opacity(0.5)
                Text("A profile that defines its own sniffer block takes precedence over these defaults.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }
}
