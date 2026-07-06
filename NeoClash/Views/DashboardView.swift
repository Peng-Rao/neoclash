import Charts
import NeoClashCore
import SwiftUI

/// Time scale shared by the Traffic Split and Traffic Timeline cards.
private enum StatRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case month = "Month"

    var id: String { rawValue }
}

struct DashboardView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage("mixedPort") private var mixedPort = 7897
    @AppStorage("controllerPort") private var controllerPort = 9097
    @AppStorage("allowLan") private var allowLan = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case .crashed(let message) = runtime.status {
                    DiagnosticBanner(message: message) { restart() } openLogs: {}
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                StatsStrip()

                HStack(alignment: .top, spacing: 14) {
                    TrafficTrendCard()
                        .frame(maxWidth: .infinity)
                    VStack(spacing: 14) {
                        ActiveConnectionsCard()
                        KernelMemoryCard()
                        AppMemoryCard()
                    }
                    .frame(width: 300)
                }

                HStack(alignment: .top, spacing: 14) {
                    TrafficSplitCard()
                        .frame(maxWidth: .infinity)
                    PolicyGroupsCard()
                        .frame(maxWidth: .infinity)
                }

                TrafficTimelineCard()

                HStack(alignment: .top, spacing: 14) {
                    TopListCard(icon: "list.bullet.rectangle", tint: .red, title: "Top Rules",
                                items: ConnectionStats.ranked(runtime.connectionStats.byRule))
                    TopListCard(icon: "globe", tint: .cyan, title: "Top Domains",
                                items: ConnectionStats.ranked(runtime.connectionStats.byDomain))
                    TopListCard(icon: "server.rack", tint: .orange, title: "Top Nodes",
                                items: ConnectionStats.ranked(runtime.connectionStats.byNode))
                }

                HStack(alignment: .top, spacing: 14) {
                    TopListCard(icon: "display", tint: .teal, title: "Client Sources",
                                items: ConnectionStats.ranked(runtime.connectionStats.bySource))
                    TopListCard(icon: "shield.lefthalf.filled", tint: .blue, title: "Tunnel Endpoints",
                                items: ConnectionStats.ranked(runtime.connectionStats.byInbound))
                    TopListCard(icon: "globe.asia.australia", tint: .purple, title: "Target Countries",
                                items: countryItems)
                }
            }
            .padding(20)
            .animation(.smooth(duration: 0.3), value: runtime.status)
        }
        .navigationTitle("Overview")
    }

    private var countryItems: [RankedStat] {
        ConnectionStats.ranked(runtime.connectionStats.byCountry).map { item in
            RankedStat(
                name: "\(CountryGuesser.flagEmoji(for: item.name)) \(CountryGuesser.countryName(for: item.name))",
                bytes: item.bytes
            )
        }
    }

    private func restart() {
        Task {
            await coordinator.stop()
            await coordinator.start(mixedPort: mixedPort, controllerPort: controllerPort, allowLAN: allowLan)
        }
    }
}

// MARK: - Shared building blocks

/// Colored icon + title header used by every Overview card.
private struct CardHeader<Trailing: View>: View {
    var icon: String
    var tint: Color
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
            Spacer(minLength: 8)
            trailing()
        }
    }
}

private extension CardHeader where Trailing == EmptyView {
    init(icon: String, tint: Color, title: String) {
        self.init(icon: icon, tint: tint, title: title) { EmptyView() }
    }
}

/// Compact Today / Month pill switcher, mirroring the mockup's segmented control.
private struct RangePicker: View {
    @Binding var range: StatRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatRange.allCases) { candidate in
                Button {
                    range = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(range == candidate ? Color.white : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 21)
                        .background(
                            range == candidate ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 8))
        .animation(.smooth(duration: 0.2), value: range)
    }
}

private struct NoDataPlaceholder: View {
    var minHeight: CGFloat = 120

    var body: some View {
        Text("No data yet")
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}

/// "12.3 KB/s" with the trailing ".0" trimmed so an idle link reads "0 KB/s".
private func speedString(_ bytesPerSecond: Int) -> String {
    let parts = speedParts(bytesPerSecond)
    let value = parts.value.hasSuffix(".0") ? String(parts.value.dropLast(2)) : parts.value
    return "\(value) \(parts.unit)"
}

/// Terse axis-scale byte label ("1 B", "24 KB"), unlike ByteCountFormatter's "1 byte".
private func compactByteLabel(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    let formatted = value < 10 && value != value.rounded()
        ? String(format: "%.1f", value)
        : String(format: "%.0f", value)
    return "\(formatted) \(units[unit])"
}

/// Two-decimal memory readout ("80.69 MB") matching the mockup's precision.
private func preciseMemoryString(_ bytes: Int?) -> String {
    guard let bytes, bytes > 0 else { return "0 B" }
    let mb = Double(bytes) / 1_048_576
    if mb < 1 { return String(format: "%.0f KB", Double(bytes) / 1024) }
    if mb < 1024 { return String(format: "%.2f MB", mb) }
    return String(format: "%.2f GB", mb / 1024)
}

// MARK: - Stats strip

private struct StatsStrip: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        GlassCard(padded: false) {
            HStack(spacing: 0) {
                cell(icon: "arrow.down.circle", tint: .blue, label: "Download",
                     value: runtime.sessionDownloadBytes.byteString)
                Divider().opacity(0.6).frame(height: 40)
                cell(icon: "arrow.up.circle", tint: .red, label: "Upload",
                     value: runtime.sessionUploadBytes.byteString)
                Divider().opacity(0.6).frame(height: 40)
                cell(icon: "link.circle", tint: .cyan, label: "Connections",
                     value: "\(runtime.connections.count)")
                Divider().opacity(0.6).frame(height: 40)
                cell(icon: "safari", tint: .purple, label: "Destinations",
                     value: "\(runtime.connectionStats.seenDestinations.count)")
            }
            .padding(.vertical, 14)
        }
        .animation(.smooth(duration: 0.3), value: runtime.sessionDownloadBytes + runtime.sessionUploadBytes)
        .animation(.snappy(duration: 0.25), value: runtime.connections.count)
    }

    private func cell(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 21, weight: .bold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Traffic trend

private struct TrafficTrendCard: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        let live = runtime.status.isRunning
        let down = paddedHistory(runtime.trafficHistory.map(\.downloadPerSecond), live: live)
        let up = paddedHistory(runtime.trafficHistory.map(\.uploadPerSecond), live: live)

        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(icon: "chart.line.uptrend.xyaxis", tint: .blue, title: "Traffic Trend")
                HStack(alignment: .top, spacing: 44) {
                    speedBlock(arrow: "arrow.down", tint: .blue,
                               speed: live ? runtime.traffic.downloadPerSecond : 0,
                               total: runtime.sessionDownloadBytes)
                    speedBlock(arrow: "arrow.up", tint: .red,
                               speed: live ? runtime.traffic.uploadPerSecond : 0,
                               total: runtime.sessionUploadBytes)
                    Spacer(minLength: 0)
                }
                TrendChart(download: down, upload: up)
            }
            .animation(.smooth(duration: 0.3), value: runtime.traffic)
        }
    }

    private func speedBlock(arrow: String, tint: Color, speed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: arrow)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                Text(speedString(speed))
                    .font(.system(size: 26, weight: .bold))
                    .contentTransition(.numericText())
            }
            Text(total.byteString)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
        }
    }

    private func paddedHistory(_ values: [Int], live: Bool, count: Int = 44) -> [Int] {
        guard live else {
            return Array(repeating: 0, count: count)
        }
        let suffix = Array(values.suffix(count))
        return Array(repeating: 0, count: max(0, count - suffix.count)) + suffix
    }
}

private struct TrendChart: View {
    var download: [Int]
    var upload: [Int]
    var height: CGFloat = 178

    var body: some View {
        // A fully idle history renders as a blank plot (mockup style), not two flat lines.
        if download.allSatisfy({ $0 == 0 }) && upload.allSatisfy({ $0 == 0 }) {
            Color.clear.frame(height: height)
        } else {
            chart
        }
    }

    private var chart: some View {
        let peak = max(download.max() ?? 0, upload.max() ?? 0, 1)
        return Chart {
            ForEach(Array(download.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("down", value), series: .value("series", "down"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [Color.blue.opacity(0.22), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("t", index), y: .value("down", value), series: .value("series", "down"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(upload.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("up", value), series: .value("series", "up"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [Color.red.opacity(0.18), .clear],
                                       startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("t", index), y: .value("up", value), series: .value("series", "up"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...peak)
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: download)
    }
}

// MARK: - Side stat cards

private struct ActiveConnectionsCard: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "link", tint: .cyan, title: "Active Connections")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(runtime.connections.count)")
                        .font(.system(size: 26, weight: .bold))
                        .contentTransition(.numericText())
                    Text("closed \(runtime.connectionStats.closedCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .animation(.snappy(duration: 0.25), value: runtime.connections.count)
        }
    }
}

private struct KernelMemoryCard: View {
    @Environment(RuntimeStore.self) private var runtime

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "memorychip", tint: .ncViolet, title: "Kernel Memory")
                Text((runtime.coreResource.memoryBytes ?? 0).byteString)
                    .font(.system(size: 26, weight: .bold))
                    .contentTransition(.numericText())
            }
            .animation(.smooth(duration: 0.3), value: runtime.coreResource)
        }
    }
}

private struct AppMemoryCard: View {
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "app.dashed", tint: .red, title: "App Memory")
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Text(preciseMemoryString(AppMemoryInfo.footprintBytes()))
                        .font(.system(size: 26, weight: .bold))
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

// MARK: - Traffic split

private struct TrafficSplitCard: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var range: StatRange = .today

    var body: some View {
        let (direct, proxy) = splitTotals()

        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(icon: "arrow.triangle.branch", tint: .ncViolet, title: "Traffic Split") {
                    RangePicker(range: $range)
                }
                Text((direct + proxy).byteString)
                    .font(.system(size: 28, weight: .bold))
                    .contentTransition(.numericText())
                SplitBar(direct: direct, proxy: proxy)
                HStack(alignment: .top, spacing: 28) {
                    legend(color: .cyan, value: direct.byteString, label: "Direct")
                    legend(color: .ncViolet, value: proxy.byteString, label: "Proxy")
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 168, alignment: .top)
            .animation(.smooth(duration: 0.3), value: direct + proxy)
        }
    }

    private func splitTotals() -> (direct: Int, proxy: Int) {
        let samples = runtime.recentDailyTraffic(days: range == .today ? 1 : 31)
        return (
            samples.reduce(0) { $0 + $1.directBytes },
            samples.reduce(0) { $0 + $1.proxyBytes }
        )
    }

    private func legend(color: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.numericText())
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.leading, 15)
        }
    }
}

private struct SplitBar: View {
    var direct: Int
    var proxy: Int

    var body: some View {
        let total = direct + proxy
        Capsule()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 9)
            .overlay(alignment: .leading) {
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: direct > 0 && proxy > 0 ? 2 : 0) {
                            if direct > 0 {
                                Capsule().fill(Color.cyan)
                                    .frame(width: geo.size.width * Double(direct) / Double(total))
                            }
                            if proxy > 0 {
                                Capsule().fill(Color.ncViolet)
                            }
                        }
                    }
                }
            }
            .clipShape(.capsule)
    }
}

// MARK: - Policy groups

private struct PolicyGroupsCard: View {
    @Environment(RuntimeStore.self) private var runtime

    private var groups: [ProxyGroup] {
        runtime.proxies.filter { $0.name != "GLOBAL" }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "rectangle.3.group", tint: .blue, title: "Policy Groups")
                if groups.isEmpty {
                    NoDataPlaceholder(minHeight: 148)
                } else {
                    VStack(spacing: 0) {
                        ForEach(groups.prefix(5)) { group in
                            row(group)
                            if group.id != groups.prefix(5).last?.id {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    if groups.count > 5 {
                        Text("+\(groups.count - 5) more in Proxies")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 168, alignment: .top)
        }
    }

    private func row(_ group: ProxyGroup) -> some View {
        HStack(spacing: 10) {
            Text(group.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Badge(kind: .neutral, text: group.type ?? "Selector")
            Spacer(minLength: 10)
            Text(group.now ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(group.nodes.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Traffic timeline

private struct TrafficTimelineCard: View {
    @Environment(RuntimeStore.self) private var runtime
    @State private var range: StatRange = .today

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter
    }()

    private struct Bucket: Identifiable {
        var label: String
        var download: Int
        var upload: Int
        var id: String { label }
        var total: Int { download + upload }
    }

    var body: some View {
        let buckets = makeBuckets()

        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(icon: "chart.bar.xaxis", tint: .blue, title: "Traffic Timeline") {
                    RangePicker(range: $range)
                }
                chart(buckets)
            }
        }
    }

    private func makeBuckets() -> [Bucket] {
        switch range {
        case .today:
            return runtime.todayHourlyTraffic().enumerated().map { hour, sample in
                Bucket(label: String(format: "%02d", hour),
                       download: sample.downloadBytes, upload: sample.uploadBytes)
            }
        case .month:
            return runtime.recentDailyTraffic(days: 31).map { sample in
                Bucket(label: Self.dayFormatter.string(from: sample.date),
                       download: sample.downloadBytes, upload: sample.uploadBytes)
            }
        }
    }

    private func chart(_ buckets: [Bucket]) -> some View {
        let peak = max(buckets.map(\.total).max() ?? 0, 1)
        let axisLabels = range == .today
            ? ["00", "06", "12", "18"]
            : stride(from: 0, to: buckets.count, by: 6).map { buckets[$0].label }

        return Chart(buckets) { bucket in
            BarMark(x: .value("t", bucket.label), y: .value("down", bucket.download), width: .ratio(0.55))
                .foregroundStyle(Color.blue.opacity(0.85))
                .clipShape(.rect(cornerRadius: 2))
            BarMark(x: .value("t", bucket.label), y: .value("up", bucket.upload), width: .ratio(0.55))
                .foregroundStyle(Color.red.opacity(0.85))
                .clipShape(.rect(cornerRadius: 2))
        }
        .chartXAxis {
            AxisMarks(values: axisLabels) { _ in
                AxisValueLabel()
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, peak]) { value in
                AxisValueLabel {
                    if let bytes = value.as(Int.self) {
                        Text(compactByteLabel(bytes))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...peak)
        .frame(height: 190)
        .animation(.smooth(duration: 0.3), value: buckets.map(\.total))
    }
}

// MARK: - Top usage lists

private struct TopListCard: View {
    var icon: String
    var tint: Color
    var title: String
    var items: [RankedStat]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: icon, tint: tint, title: title)
                if items.isEmpty {
                    NoDataPlaceholder(minHeight: 118)
                } else {
                    let peak = max(items.first?.bytes ?? 1, 1)
                    VStack(spacing: 9) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 10) {
                                    Text(item.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(item.bytes.byteString)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Meter(value: Double(item.bytes) / Double(peak), color: tint.opacity(0.85))
                            }
                        }
                    }
                    .frame(minHeight: 118, alignment: .top)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.3), value: items)
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
