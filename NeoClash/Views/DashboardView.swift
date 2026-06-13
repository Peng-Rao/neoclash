import NeoClashCore
import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NeoClash")
                            .font(.largeTitle.weight(.semibold))
                        HStack(spacing: 8) {
                            StatusDot(status: runtime.status)
                            Text(runtime.status.label)
                                .font(.headline)
                            Text(runtime.coreVersion)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        runtime.status.isRunning ? runtime.markStopped() : runtime.markStarting()
                    } label: {
                        Label(runtime.status.isRunning ? "Stop" : "Start", systemImage: runtime.status.isRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.glass)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Upload", value: runtime.traffic.uploadPerSecond.bytesPerSecondString, systemImage: "arrow.up", color: .orange)
                    MetricTile(title: "Download", value: runtime.traffic.downloadPerSecond.bytesPerSecondString, systemImage: "arrow.down", color: .blue)
                    MetricTile(title: "Connections", value: "\(runtime.connections.count)", systemImage: "network", color: .green)
                    MetricTile(title: "Mode", value: runtime.mode.displayName, systemImage: "switch.2", color: .purple)
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runtime")
                            .font(.headline)
                        LabeledContent("Active Profile", value: runtime.activeProfile?.name ?? "None")
                        LabeledContent("System Proxy", value: runtime.isSystemProxyEnabled ? "Enabled" : "Disabled")
                        LabeledContent("TUN", value: runtime.isTUNEnabled ? "Enabled" : "Disabled")
                    }
                }

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Actions")
                            .font(.headline)
                        HStack {
                            Button {
                                runtime.appendLog(level: .info, "Requested runtime restart")
                            } label: {
                                Label("Restart", systemImage: "arrow.clockwise")
                            }
                            Button {
                                runtime.appendLog(level: .info, "Requested config reload")
                            } label: {
                                Label("Reload", systemImage: "doc.badge.gearshape")
                            }
                            Button {
                                runtime.appendLog(level: .info, "Requested subscription update")
                            } label: {
                                Label("Update", systemImage: "arrow.down.doc")
                            }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(runtime.diagnosticText, forType: .string)
                            } label: {
                                Label("Copy Diagnostics", systemImage: "doc.on.doc")
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }
}

private struct StatusDot: View {
    var status: CoreStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .symbolEffect(.pulse, isActive: status.isRunning)
    }

    private var color: Color {
        switch status {
        case .stopped: .secondary
        case .starting, .stopping: .orange
        case .running: .green
        case .crashed: .red
        }
    }
}
