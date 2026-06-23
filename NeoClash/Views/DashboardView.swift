import NeoClashCore
import SwiftUI

struct DashboardView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false

    @State private var startedAt: Date?
    @State private var topRowHeights: [TopRowColumn: CGFloat] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case .crashed(let message) = runtime.status {
                    DiagnosticBanner(message: message) { restart() } openLogs: {}
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(alignment: .top, spacing: 14) {
                    StatusHero(
                        controller: "127.0.0.1:\(controllerPort)",
                        startedAt: startedAt
                    )
                    .frame(maxWidth: .infinity)
                    .readTopRowHeight(.status)
                    .frame(height: topRowHeight, alignment: .top)

                    NetworkStatusCard()
                        .frame(maxWidth: .infinity)
                        .readTopRowHeight(.side)
                        .frame(height: topRowHeight, alignment: .top)
                }
                .onPreferenceChange(TopRowHeightPreferenceKey.self) { topRowHeights = $0 }

                WeekTrendCard()
                TrafficCard()
                TrafficSummaryCard()
            }
            .padding(20)
            .animation(.smooth(duration: 0.3), value: runtime.status)
        }
        .navigationTitle("Overview")
        .onChange(of: runtime.status.isRunning) { _, running in
            startedAt = running ? Date() : nil
        }
        .onAppear { if runtime.status.isRunning, startedAt == nil { startedAt = Date() } }
    }

    private var topRowHeight: CGFloat? {
        guard let height = topRowHeights.values.max(), height > 0 else {
            return nil
        }
        return height
    }

    private func restart() {
        Task {
            await coordinator.stop()
            await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLan)
        }
    }
}

private enum TopRowColumn: Hashable {
    case status
    case side
}

private struct TopRowHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [TopRowColumn: CGFloat] = [:]

    static func reduce(value: inout [TopRowColumn: CGFloat], nextValue: () -> [TopRowColumn: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private extension View {
    func readTopRowHeight(_ column: TopRowColumn) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: TopRowHeightPreferenceKey.self, value: [column: proxy.size.height])
            }
        }
    }
}

// MARK: - Status hero

private struct StatusHero: View {
    @Environment(RuntimeStore.self) private var runtime
    var controller: String
    var startedAt: Date?

    static func uptimeString(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    var body: some View {
        GlassCard(padded: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.6)
                metaStrip
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        let s = StatusPresentation(runtime.status)
        return HStack {
            StatusDot(color: s.color, size: 12, pulse: runtime.status.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 20, weight: .bold))
                    .contentTransition(.numericText())
                Text(s.desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Badge(kind: s.badgeKind, dot: true, text: s.badgeText)
        }
        .padding(16)
        .animation(.smooth(duration: 0.3), value: runtime.status)
    }

    private var metaStrip: some View {
        let running = runtime.status.isRunning
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                MetaCell(systemImage: "doc.text", label: "Active Profile",
                         value: runtime.activeProfile?.name ?? "None")
                if running, let startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        MetaCell(systemImage: "clock", label: "Uptime",
                                 value: Self.uptimeString(since: startedAt, now: context.date),
                                 mono: true, border: true)
                    }
                } else {
                    MetaCell(systemImage: "clock", label: "Uptime", value: "—", mono: true, border: true)
                }
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
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        let status = runtime.networkStatus

        GlassCard(title: "Network Status", systemImage: "globe") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    latencyMetric(systemImage: "globe", label: "Internet", value: status.internetLatencyMS)
                    latencyMetric(systemImage: "network", label: "DNS", value: status.dnsLatencyMS)
                    latencyMetric(systemImage: "wifi.router", label: "Router", value: status.routerLatencyMS)
                }
                CardDivider().padding(.vertical, 12)
                HStack(spacing: 14) {
                    SmallKV(systemImage: networkSystemImage(status.interfaceKind), label: "Network", value: networkValue(status))
                    SmallKV(systemImage: "mappin.and.ellipse", label: "Local IP", value: maskedIPAddress(status.localIPAddress))
                    SmallKV(systemImage: "globe.asia.australia", label: "Egress", value: egressValue(status))
                }
            }
        }
    }

    private func latencyMetric(systemImage: String, label: String, value: Int?) -> some View {
        MetricNumber(
            systemImage: systemImage,
            label: label,
            value: value.map(String.init) ?? "—",
            unit: value == nil ? nil : "ms",
            color: .ncRun,
            dim: value == nil
        )
    }

    private func networkValue(_ status: NetworkStatusSnapshot) -> String {
        var parts = [status.serviceName ?? status.interfaceKind.displayName]
        if let ssid = status.wifiSSID, !ssid.isEmpty {
            parts.append(ssid)
        } else if let band = status.wifiBand, !band.isEmpty {
            parts.append(band)
        } else if let interfaceName = status.interfaceName, !interfaceName.isEmpty {
            parts.append(interfaceName)
        }
        return parts.joined(separator: " · ")
    }

    private func egressValue(_ status: NetworkStatusSnapshot) -> String {
        guard let ipAddress = status.egressIPAddress else {
            return "—"
        }
        if let countryCode = status.egressCountryCode, !countryCode.isEmpty {
            return "\(countryCode) · \(maskedIPAddress(ipAddress))"
        }
        return maskedIPAddress(ipAddress)
    }

    private func maskedIPAddress(_ ipAddress: String?) -> String {
        guard let ipAddress, !ipAddress.isEmpty else {
            return "—"
        }

        let ipv4Parts = ipAddress.split(separator: ".")
        if ipv4Parts.count == 4 {
            return "\(ipv4Parts[0]).\(ipv4Parts[1]).•••.\(ipv4Parts[3])"
        }

        let ipv6Parts = ipAddress.split(separator: ":")
        if ipv6Parts.count > 3 {
            return "\(ipv6Parts[0]):\(ipv6Parts[1]):•••:\(ipv6Parts[ipv6Parts.count - 1])"
        }

        return ipAddress
    }

    private func networkSystemImage(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .tunnel: "point.topleft.down.to.point.bottomright.curvepath"
        case .loopback: "arrow.trianglehead.2.clockwise.rotate.90"
        case .other, .unknown: "network"
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
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 7-day trend

private struct WeekTrendCard: View {
    @Environment(RuntimeStore.self) private var runtime

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    var body: some View {
        let samples = runtime.recentDailyTraffic(days: 7)
        let bars = samples.map { Double($0.totalBytes) / 1_048_576 }
        let labels = samples.map { Self.weekdayFormatter.string(from: $0.date) }
        let totalBytes = samples.reduce(0) { $0 + $1.totalBytes }
        let activeDays = max(1, samples.filter { $0.totalBytes > 0 }.count)
        let averageMB = Double(totalBytes) / Double(activeDays) / 1_048_576
        let todayBytes = samples.last?.totalBytes ?? 0

        GlassCard(title: "7-Day Traffic", systemImage: "chart.bar",
                  headerTrailing: AnyView(Text("measured").font(.system(size: 11)).foregroundStyle(.tertiary))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Daily average").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", averageMB))
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .contentTransition(.numericText())
                            Text("MB").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Badge(kind: .accent, text: "today \(todayBytes.byteString)")
                }
                WeekBars(data: bars, labels: labels, color: .accentColor, height: 110)
            }
            .animation(.smooth(duration: 0.3), value: totalBytes)
        }
    }
}

// MARK: - Traffic

private struct TrafficCard: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        let live = runtime.status.isRunning
        let up = speedParts(runtime.traffic.uploadPerSecond)
        let dn = speedParts(runtime.traffic.downloadPerSecond)
        let upHistory = normalizedHistory(runtime.trafficHistory.map(\.uploadPerSecond), live: live)
        let dnHistory = normalizedHistory(runtime.trafficHistory.map(\.downloadPerSecond), live: live)

        GlassCard(title: "Traffic", systemImage: "chart.line.uptrend.xyaxis",
                  headerTrailing: AnyView(Badge(kind: live ? .run : .neutral, dot: true, text: live ? "live" : "idle"))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        MetricNumber(systemImage: "arrow.up", label: "Upload",
                                     value: live ? up.value : "0.0", unit: live ? up.unit : "KB/s", color: .accentColor)
                        Sparkline(values: upHistory, color: .accentColor, height: 50)
                        Text("Session ↑ \(live ? runtime.sessionUploadBytes.byteString : "0 B")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        MetricNumber(systemImage: "arrow.down", label: "Download",
                                     value: live ? dn.value : "0.0", unit: live ? dn.unit : "KB/s", color: .ncRun)
                        Sparkline(values: dnHistory, color: .ncRun, height: 50)
                        Text("Session ↓ \(live ? runtime.sessionDownloadBytes.byteString : "0 B")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
                CardDivider()
                HStack(spacing: 12) {
                    MiniStat(systemImage: "link", value: "\(runtime.connections.count)", label: "Connections")
                    MiniStat(systemImage: "memorychip", value: memoryValue(live: live), label: "Core Memory")
                    MiniStat(systemImage: "cpu", value: cpuValue(live: live), label: "Core CPU")
                }
            }
            .animation(.smooth(duration: 0.3), value: runtime.traffic)
            .animation(.snappy(duration: 0.25), value: runtime.connections.count)
        }
    }

    private func normalizedHistory(_ values: [Int], live: Bool) -> [Double] {
        let count = 44
        guard live else {
            return Array(repeating: 0, count: count)
        }

        let suffix = values.suffix(count)
        let padded = Array(repeating: 0, count: max(0, count - suffix.count)) + suffix
        let peak = max(padded.max() ?? 0, 1)
        return padded.map { Double($0) / Double(peak) }
    }

    private func memoryValue(live: Bool) -> String {
        guard live, let memoryBytes = runtime.coreResource.memoryBytes else {
            return "—"
        }
        return memoryBytes.byteString
    }

    private func cpuValue(live: Bool) -> String {
        guard live, let cpuPercent = runtime.coreResource.cpuPercent else {
            return "—"
        }
        return String(format: "%.1f%%", cpuPercent)
    }
}

// MARK: - Traffic summary (donut + ranking)

private struct TrafficSummaryCard: View {
    @Environment(RuntimeStore.self) private var runtime

    private struct HostUsage: Identifiable {
        var host: String
        var bytes: Int
        var fraction: Double
        var id: String { host }
    }

    var body: some View {
        let live = runtime.status.isRunning
        let up = runtime.sessionUploadBytes
        let down = runtime.sessionDownloadBytes
        let total = up + down
        let connections = runtime.connections
        let directCount = connections.filter { isDirect($0.chain) }.count
        let proxyCount = connections.count - directCount
        let topHosts = topHosts(connections)

        GlassCard(title: "Traffic Summary", systemImage: "sparkles",
                  headerTrailing: AnyView(Badge(kind: live ? .run : .neutral, dot: true,
                                                text: live ? "session" : "idle"))) {
            HStack(alignment: .center, spacing: 24) {
                HStack(spacing: 18) {
                    Donut(segments: donutSegments(up: up, down: down), size: 120) {
                        AnyView(
                            VStack(spacing: 1) {
                                Text("Total").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(totalParts(total).value)
                                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                                    .contentTransition(.numericText())
                                Text(totalParts(total).unit).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        SummaryLine(systemImage: "arrow.up", color: .accentColor, label: "Upload", value: up.byteString)
                        SummaryLine(systemImage: "arrow.down", color: .ncRun, label: "Download", value: down.byteString)
                        Divider().opacity(0.6).frame(width: 150)
                        SummaryLine(dotColor: .ncViolet, label: "Direct flows", value: "\(directCount)")
                        SummaryLine(dotColor: .accentColor, label: "Proxy flows", value: "\(proxyCount)")
                    }
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Top usage", systemImage: "list.bullet")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    if topHosts.isEmpty {
                        Text(live ? "No active flows right now." : "Start the core to see live usage.")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(topHosts) { item in
                            HStack(spacing: 10) {
                                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                                Text(item.host).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 130, alignment: .leading)
                                Meter(value: item.fraction, color: .accentColor)
                                Text(item.bytes.byteString)
                                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(.smooth(duration: 0.3), value: connections)
            .animation(.smooth(duration: 0.3), value: total)
        }
    }

    private func isDirect(_ chain: [String]) -> Bool {
        chain.isEmpty || chain.allSatisfy { $0 == "DIRECT" }
    }

    private func topHosts(_ connections: [ConnectionEntry]) -> [HostUsage] {
        var totals: [String: Int] = [:]
        for connection in connections {
            totals[connection.host, default: 0] += connection.upload + connection.download
        }
        let ranked = totals.sorted { $0.value > $1.value }.prefix(5)
        let peak = Double(ranked.first?.value ?? 0)
        return ranked.map { entry in
            HostUsage(host: entry.key, bytes: entry.value, fraction: peak > 0 ? Double(entry.value) / peak : 0)
        }
    }

    private func donutSegments(up: Int, down: Int) -> [Donut.Segment] {
        guard up + down > 0 else {
            return [.init(value: 1, color: .primary.opacity(0.12))]
        }
        return [
            .init(value: Double(down), color: .ncRun),
            .init(value: Double(up), color: .accentColor)
        ]
    }

    private func totalParts(_ bytes: Int) -> (value: String, unit: String) {
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return (String(format: "%.0f", Double(bytes) / 1024), "KB") }
        if mb < 1024 { return (String(format: "%.1f", mb), "MB") }
        return (String(format: "%.2f", mb / 1024), "GB")
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
        case .crashed(let message):
            color = .ncDanger; title = "Start Failed"; desc = message
            badgeKind = .err; badgeText = "exit 1"
        case .stopped:
            color = .secondary; title = "Stopped"; desc = "Enable System Proxy or TUN to start the core"
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
