import NeoClashMobileCore
import SwiftUI

struct IOSHomeView: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @Binding var selection: IOSAppTab

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ConnectDial()
                statusText
                speeds
                TrafficTrace(samples: runtime.trafficHistory, isLive: runtime.status.isRunning)
                    .frame(height: 72)
                    .accessibilityHidden(true)
                modePicker
                details
                if !coordinator.engine.routesDeviceTraffic {
                    localEngineNote
                }
            }
            .padding(.bottom, 24)
        }
        .background { connectedWash }
        .navigationTitle("NeoClash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                profileMenu
            }
        }
    }

    /// The colour says the core is on; it is never there as decoration.
    private var connectedWash: some View {
        LinearGradient(
            colors: [NC.indigo.opacity(0.30), NC.violet.opacity(0.10), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
        .opacity(runtime.status.isRunning ? 1 : 0)
        .animation(.smooth(duration: 0.6), value: runtime.status.isRunning)
    }

    private var statusText: some View {
        VStack(spacing: 4) {
            Text(statusTitle)
                .font(.title2.weight(.semibold))
                .contentTransition(.opacity)
            Text(statusDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, NC.pagePadding)
        .animation(.smooth(duration: 0.25), value: statusTitle)
    }

    private var statusTitle: String {
        switch runtime.status {
        case .stopped: "Not connected"
        case .starting: "Connecting"
        case .running: "Connected"
        case .stopping: "Disconnecting"
        case .crashed: "Connection failed"
        }
    }

    private var statusDetail: String {
        if case .crashed = runtime.status {
            return "Tap the button to try again."
        }
        return runtime.activeProfile?.name ?? "No profile: traffic goes direct"
    }

    private var speeds: some View {
        HStack(spacing: 0) {
            SpeedReadout(systemImage: "arrow.down", title: "Download", bytesPerSecond: runtime.traffic.downloadPerSecond)
            SpeedReadout(systemImage: "arrow.up", title: "Upload", bytesPerSecond: runtime.traffic.uploadPerSecond)
        }
        .padding(.horizontal, NC.pagePadding)
    }

    private var modePicker: some View {
        Picker("Routing mode", selection: modeBinding) {
            ForEach(RoutingMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, NC.pagePadding)
    }

    private var modeBinding: Binding<RoutingMode> {
        Binding {
            runtime.mode
        } set: { mode in
            Task { await coordinator.setMode(mode) }
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            Button {
                selection = .proxies
            } label: {
                DetailRow(title: "Node", value: currentNode, showsChevron: true)
            }
            .buttonStyle(.plain)
            Divider()
            DetailRow(title: "This session", value: sessionTotal)
            Divider()
            DetailRow(title: "Connections", value: "\(runtime.connections.count)")
        }
        .padding(.horizontal, NC.pagePadding)
    }

    private var sessionTotal: String {
        "\(byteString(runtime.sessionDownloadBytes)) down, \(byteString(runtime.sessionUploadBytes)) up"
    }

    /// The first group the rules are likely to use, resolved down to a node when it points to one.
    private var currentNode: String {
        guard runtime.status.isRunning,
              let group = runtime.proxies.first(where: { $0.name != "GLOBAL" && $0.now != nil }),
              let now = group.now else {
            return "None"
        }
        return runtime.proxies.first(where: { $0.name == now })?.now ?? now
    }

    private var localEngineNote: some View {
        Label {
            Text("The core runs inside this app and only while it's open. Your iPhone's traffic doesn't go through it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NC.pagePadding)
    }

    private var profileMenu: some View {
        Menu {
            ForEach(runtime.profiles) { profile in
                Button {
                    Task { await coordinator.applyProfile(profile) }
                } label: {
                    if profile.id == runtime.activeProfile?.id {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Manage profiles") {
                selection = .profiles
            }
        } label: {
            Label("Choose profile", systemImage: "doc.text")
        }
    }
}

private struct SpeedReadout: View {
    var systemImage: String
    var title: String
    var bytesPerSecond: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(rateString(bytesPerSecond))
                .ncMono(.title3, weight: .semibold)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: bytesPerSecond)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(rateString(bytesPerSecond))")
    }
}

private struct DetailRow: View {
    var title: String
    var value: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .ncMono(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

/// The connect control. The ring reads as the state: empty when off, sweeping while it changes,
/// closed when connected.
private struct ConnectDial: View {
    @Environment(RuntimeStore.self) private var runtime
    @Environment(IOSAppCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tapCount = 0

    private let size: CGFloat = 156
    private let ringWidth: CGFloat = 6

    var body: some View {
        Button {
            tapCount += 1
            Task { await coordinator.toggleEngine() }
        } label: {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: ringWidth)
                ring
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(isConnected ? AnyShapeStyle(NC.brand) : AnyShapeStyle(.secondary))
                    .frame(width: size - 36, height: size - 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .frame(width: size, height: size)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(isChanging)
        .sensoryFeedback(.impact(weight: .medium), trigger: tapCount)
        .sensoryFeedback(.success, trigger: isConnected) { _, connected in connected }
        .sensoryFeedback(.error, trigger: runtime.status.isCrashed) { _, crashed in crashed }
        .animation(.smooth(duration: 0.5), value: isConnected)
        .accessibilityLabel(isConnected ? "Disconnect" : "Connect")
        .accessibilityValue(runtime.status.label)
    }

    private var isConnected: Bool {
        runtime.status.isRunning
    }

    private var isChanging: Bool {
        runtime.status == .starting || runtime.status == .stopping
    }

    @ViewBuilder
    private var ring: some View {
        if isChanging && !reduceMotion {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                progressArc(trim: 0.28)
                    .rotationEffect(.degrees(turn * 360))
            }
        } else {
            progressArc(trim: isConnected || isChanging ? 1 : 0)
        }
    }

    private func progressArc(trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(NC.brandAngular, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// The app icon's horizontal bolt as a live instrument: a flat line at rest, and a trace of recent
/// throughput that scrolls steadily between the core's once-a-second samples when connected.
struct TrafficTrace: View {
    var samples: [TrafficSnapshot]
    var isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let capacity = 44
    private static let minimumScale = 16.0 * 1_024

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isLive || reduceMotion)) { context in
            Canvas { canvas, size in
                draw(in: &canvas, size: size, now: context.date)
            }
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let step = size.width / CGFloat(Self.capacity - 1)
        // Slide by the time since the newest sample, so 1 Hz data moves continuously.
        let elapsed = samples.last.map { min(max(now.timeIntervalSince($0.timestamp), 0), 1) } ?? 0
        let offset = reduceMotion ? 0 : step * CGFloat(elapsed)
        let scale = max(samples.map { Double($0.downloadPerSecond + $0.uploadPerSecond) }.max() ?? 0, Self.minimumScale)
        let baseline = size.height - 2

        func x(_ index: Int) -> CGFloat {
            size.width + step - CGFloat(samples.count - index) * step - offset
        }
        func y(_ value: Int) -> CGFloat {
            baseline - CGFloat(Double(value) / scale) * (size.height - 8)
        }

        guard isLive, samples.count > 1 else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: baseline))
            flat.addLine(to: CGPoint(x: size.width, y: baseline))
            canvas.stroke(flat, with: .color(.secondary.opacity(0.35)), lineWidth: 1.5)
            return
        }

        // Until history fills the width, the trace leads in from the left edge at rest.
        let leadIn = x(0) > 0 ? [CGPoint(x: 0, y: baseline)] : []
        let trace = samples.indices.map {
            CGPoint(x: x($0), y: y(samples[$0].downloadPerSecond + samples[$0].uploadPerSecond))
        }
        // The newest sample slides in from the right, so hold its level out to the edge.
        let tail = trace.last.map { [CGPoint(x: size.width, y: $0.y)] } ?? []
        let total = smoothPath(points: leadIn + trace + tail)
        var area = total
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: min(x(0), 0), y: size.height))
        area.closeSubpath()

        let brand = Gradient(colors: [NC.blue, NC.indigo, NC.violet])
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: size.width, y: 0)
        canvas.fill(area, with: .linearGradient(
            Gradient(colors: [NC.violet.opacity(0.28), NC.indigo.opacity(0)]),
            startPoint: start,
            endPoint: CGPoint(x: 0, y: size.height)
        ))
        canvas.stroke(total, with: .linearGradient(brand, startPoint: start, endPoint: end), lineWidth: 2)
    }

    /// Horizontal-tangent curves, which never overshoot below the baseline.
    private func smoothPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        for (previous, point) in zip(points, points.dropFirst()) {
            let middle = (previous.x + point.x) / 2
            path.addCurve(
                to: point,
                control1: CGPoint(x: middle, y: previous.y),
                control2: CGPoint(x: middle, y: point.y)
            )
        }
        return path
    }
}
