import NeoClashCore
import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false

    @State private var copied = false
    @State private var upHist: [Double] = DashboardView.seedWave
    @State private var dnHist: [Double] = DashboardView.seedWave
    @State private var startedAt: Date?

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case .crashed(let message) = runtime.status {
                    DiagnosticBanner(message: message) { restart() } openLogs: {}
                }

                HStack(alignment: .top, spacing: 14) {
                    StatusHero(
                        copied: $copied,
                        allowLan: $allowLan,
                        onStart: { startOrStop() },
                        onReload: { Task { await coordinator.reloadRuntimeData() } },
                        onUpdate: { Task { await coordinator.updateSelectedSubscription() } },
                        onCopyDiag: { copyDiag() },
                        controller: "127.0.0.1:\(controllerPort)",
                        uptime: uptimeString
                    )
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 14) {
                        NetworkStatusCard(live: runtime.status.isRunning)
                        WeekTrendCard()
                    }
                    .frame(maxWidth: .infinity)
                }

                TrafficCard(upHist: upHist, dnHist: dnHist)
                TrafficSummaryCard()
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .onChange(of: runtime.status.isRunning) { _, running in
            startedAt = running ? Date() : nil
        }
        .onAppear { if runtime.status.isRunning, startedAt == nil { startedAt = Date() } }
        .onReceive(tick) { _ in
            let up = min(1, (Double(runtime.traffic.uploadPerSecond) / 1024) / 900)
            let dn = min(1, (Double(runtime.traffic.downloadPerSecond) / 1024) / 4200)
            upHist = Array(upHist.dropFirst()) + [up]
            dnHist = Array(dnHist.dropFirst()) + [dn]
        }
    }

    private var uptimeString: String {
        guard runtime.status.isRunning, let startedAt else { return "—" }
        let s = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func startOrStop() {
        Task {
            if runtime.status.isRunning { await coordinator.stop() }
            else { await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort) }
        }
    }
    private func restart() {
        Task { await coordinator.stop(); await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort) }
    }
    private func copyDiag() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(runtime.diagnosticText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    static let seedWave: [Double] = (0..<44).map { (i: Int) -> Double in
        let x = Double(i)
        return 0.18 + 0.16 * sin(x / 3.4) + 0.08 * sin(x / 1.7)
    }
}

// MARK: - Status hero

private struct StatusHero: View {
    @Environment(RuntimeStore.self) private var runtime
    @Binding var copied: Bool
    @Binding var allowLan: Bool
    var onStart: () -> Void
    var onReload: () -> Void
    var onUpdate: () -> Void
    var onCopyDiag: () -> Void
    var controller: String
    var uptime: String

    var body: some View {
        GlassCard(padded: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.6)
                metaStrip
                Divider().opacity(0.6)
                togglesAndActions
            }
        }
    }

    private var header: some View {
        @Bindable var runtime = runtime
        let s = StatusPresentation(runtime.status)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusDot(color: s.color, size: 12, pulse: runtime.status.isRunning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 20, weight: .bold))
                    Text(s.desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Badge(kind: s.badgeKind, dot: true, text: s.badgeText)
            }
            HStack(spacing: 10) {
                Button(action: onStart) {
                    Label(runtime.status.isRunning ? "Stop Core" : "Start Core",
                          systemImage: runtime.status.isRunning ? "stop.fill" : "power")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(runtime.status.isRunning ? .red : .accentColor)

                Picker("", selection: $runtime.mode) {
                    ForEach(RoutingMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
        }
        .padding(16)
    }

    private var metaStrip: some View {
        let running = runtime.status.isRunning
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                MetaCell(systemImage: "doc.text", label: "Active Profile",
                         value: runtime.activeProfile?.name ?? "None")
                MetaCell(systemImage: "clock", label: "Uptime",
                         value: running ? uptime : "—", mono: true, border: true)
            }
            Divider().opacity(0.6).gridCellColumns(2)
            GridRow {
                MetaCell(systemImage: "cpu", label: "Core Version",
                         value: running ? runtime.coreVersion : "—", mono: true)
                MetaCell(systemImage: "checkmark.shield", label: "Controller",
                         value: controller, mono: true, border: true,
                         tag: AnyView(Badge(kind: running ? .run : .neutral, text: running ? "live" : "idle")))
            }
        }
    }

    private var togglesAndActions: some View {
        @Bindable var runtime = runtime
        return VStack(spacing: 2) {
            ToggleRow(systemImage: "globe", title: "System Proxy",
                      hint: "Set macOS HTTP/SOCKS proxy", isOn: $runtime.isSystemProxyEnabled)
            ToggleRow(systemImage: "shield.lefthalf.filled", title: "TUN / Enhanced Mode",
                      hint: "Virtual NIC captures all traffic", isOn: $runtime.isTUNEnabled)
            ToggleRow(systemImage: "wifi.router", title: "Allow LAN",
                      hint: "Accept connections from local network", isOn: $allowLan)
            HStack(spacing: 6) {
                Button(action: onReload) { Label("Reload", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                Button(action: onUpdate) { Label("Update Sub", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                Button(action: onCopyDiag) { Label(copied ? "Copied!" : "Copy Diag", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct MetaCell: View {
    var systemImage: String
    var label: String
    var value: String
    var mono: Bool = false
    var border: Bool = false
    var tag: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 13.5, weight: .semibold, design: mono ? .monospaced : .default))
                    .lineLimit(1)
                if let tag { tag }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .leading) {
            if border { Divider().opacity(0.6) }
        }
    }
}

// MARK: - Network status

private struct NetworkStatusCard: View {
    var live: Bool

    var body: some View {
        GlassCard(title: "Network Status", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    MetricNumber(systemImage: "globe", label: "Internet", value: live ? "213" : "—", unit: live ? "ms" : nil, color: .ncRun, dim: !live)
                    MetricNumber(systemImage: "network", label: "DNS", value: live ? "48" : "—", unit: live ? "ms" : nil, color: .ncRun, dim: !live)
                    MetricNumber(systemImage: "wifi.router", label: "Router", value: live ? "6" : "—", unit: live ? "ms" : nil, color: .ncRun, dim: !live)
                }
                CardDivider().padding(.vertical, 12)
                HStack(spacing: 14) {
                    SmallKV(systemImage: "wifi", label: "Network", value: "Wi-Fi · 5GHz")
                    SmallKV(systemImage: "mappin.and.ellipse", label: "Local IP", value: "192.168.···.41")
                    SmallKV(systemImage: "globe.asia.australia", label: "Egress", value: live ? "HK · 18···.249" : "—")
                }
            }
        }
    }
}

private struct SmallKV: View {
    var systemImage: String
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 7-day trend

private struct WeekTrendCard: View {
    private let bars: [Double] = [620, 880, 540, 1240, 760, 980, 1180]
    private let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        GlassCard(title: "7-Day Traffic", systemImage: "chart.bar",
                  headerTrailing: AnyView(Text("this week").font(.system(size: 11)).foregroundStyle(.tertiary))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily average").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("883.5").font(.system(size: 24, weight: .bold, design: .monospaced))
                            Text("MB").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Badge(kind: .accent, text: "↓ 12% vs last week")
                }
                WeekBars(data: bars, labels: labels, color: .accentColor, height: 110)
            }
        }
    }
}

// MARK: - Traffic

private struct TrafficCard: View {
    @Environment(RuntimeStore.self) private var runtime
    var upHist: [Double]
    var dnHist: [Double]

    var body: some View {
        let live = runtime.status.isRunning
        let up = speedParts(runtime.traffic.uploadPerSecond)
        let dn = speedParts(runtime.traffic.downloadPerSecond)

        GlassCard(title: "Traffic", systemImage: "chart.line.uptrend.xyaxis",
                  headerTrailing: AnyView(Badge(kind: live ? .run : .neutral, dot: true, text: live ? "live" : "idle"))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        MetricNumber(systemImage: "arrow.up", label: "Upload",
                                     value: live ? up.value : "0.0", unit: live ? up.unit : "KB/s", color: .accentColor)
                        Sparkline(values: live ? upHist : upHist.map { _ in 0.04 }, color: .accentColor, height: 50)
                        Text("Session ↑ \(live ? runtime.traffic.uploadPerSecond.byteString : "0 B")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        MetricNumber(systemImage: "arrow.down", label: "Download",
                                     value: live ? dn.value : "0.0", unit: live ? dn.unit : "KB/s", color: .ncRun)
                        Sparkline(values: live ? dnHist : dnHist.map { _ in 0.04 }, color: .ncRun, height: 50)
                        Text("Session ↓ \(live ? runtime.traffic.downloadPerSecond.byteString : "0 B")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                CardDivider()
                HStack(spacing: 12) {
                    MiniStat(systemImage: "link", value: "\(runtime.connections.count)", label: "Connections")
                    MiniStat(systemImage: "memorychip", value: live ? "63 MB" : "—", label: "Core Memory")
                    MiniStat(systemImage: "cpu", value: live ? "1.2%" : "—", label: "Core CPU")
                }
            }
        }
    }
}

// MARK: - Traffic summary (donut + ranking)

private struct TrafficSummaryCard: View {
    @State private var range = "Today"
    private let ranking: [(flag: String, name: String, pct: Double, mb: String)] = [
        ("🇺🇸", "api.openai.com", 1.0, "18.4"),
        ("🇭🇰", "netflix.com", 0.62, "11.2"),
        ("🇸🇬", "github.com", 0.38, "6.8"),
        ("🇯🇵", "cdn.jsdelivr.net", 0.21, "3.9")
    ]

    var body: some View {
        GlassCard(title: "Traffic Summary", systemImage: "sparkles",
                  headerTrailing: AnyView(
                    Picker("", selection: $range) {
                        ForEach(["Today", "This Month", "Last Month"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                  )) {
            HStack(alignment: .center, spacing: 24) {
                HStack(spacing: 18) {
                    Donut(segments: [
                        .init(value: 0.95, color: .accentColor),
                        .init(value: 0.05, color: .ncViolet)
                    ], size: 120) {
                        AnyView(
                            VStack(spacing: 1) {
                                Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text("49.3").font(.system(size: 17, weight: .bold, design: .monospaced))
                                Text("MB").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        SummaryLine(systemImage: "arrow.up", color: .accentColor, label: "Upload", value: "16.3 MB")
                        SummaryLine(systemImage: "arrow.down", color: .ncRun, label: "Download", value: "33.1 MB")
                        Divider().opacity(0.6).frame(width: 150)
                        SummaryLine(dotColor: .ncViolet, label: "Direct", value: "2.5 MB")
                        SummaryLine(dotColor: .accentColor, label: "Proxy", value: "46.8 MB")
                    }
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Top usage", systemImage: "list.bullet")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    ForEach(ranking, id: \.name) { r in
                        HStack(spacing: 10) {
                            Text(r.flag).font(.system(size: 14)).frame(width: 18)
                            Text(r.name).font(.system(size: 12)).lineLimit(1).frame(width: 130, alignment: .leading)
                            Meter(value: r.pct, color: .accentColor)
                            Text("\(r.mb) MB")
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SummaryLine: View {
    var systemImage: String? = nil
    var color: Color = .accentColor
    var dotColor: Color? = nil
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(color)
            } else if let dotColor {
                RoundedRectangle(cornerRadius: 2).fill(dotColor).frame(width: 8, height: 8)
            }
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 18)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }
}

// MARK: - Diagnostics banner

struct DiagnosticBanner: View {
    var message: String
    var onRetry: () -> Void
    var openLogs: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Core failed to start").font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Badge(kind: .err, text: "exit 1")
            }
            Text(message)
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.soft(0.10), in: .rect(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.red.soft(0.30), lineWidth: 1))
    }
}

// MARK: - Status presentation helper

struct StatusPresentation {
    var color: Color
    var title: String
    var desc: String
    var badgeKind: Badge.Kind
    var badgeText: String

    init(_ status: CoreStatus) {
        switch status {
        case .running:
            color = .ncRun; title = "Running"; desc = "All traffic routed through Mihomo core"
            badgeKind = .run; badgeText = "healthy"
        case .starting:
            color = .accentColor; title = "Starting…"; desc = "Loading config and initializing core"
            badgeKind = .accent; badgeText = "starting"
        case .stopping:
            color = .accentColor; title = "Stopping…"; desc = "Shutting down core"
            badgeKind = .accent; badgeText = "stopping"
        case .crashed:
            color = .ncDanger; title = "Start Failed"; desc = "Core exited during startup"
            badgeKind = .err; badgeText = "exit 1"
        case .stopped:
            color = .secondary; title = "Stopped"; desc = "Core is not running · traffic is direct"
            badgeKind = .neutral; badgeText = "idle"
        }
    }
}

// MARK: - Background mesh

struct WindowMesh: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.45, 0.5], [1, 0.55],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: [
                .accentColor.opacity(0.16), .mint.opacity(0.10), .clear,
                .clear, .purple.opacity(0.06), .blue.opacity(0.10),
                .clear, .teal.opacity(0.10), .clear
            ]
        )
        .ignoresSafeArea()
    }
}
