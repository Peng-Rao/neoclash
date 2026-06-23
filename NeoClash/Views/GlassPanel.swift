import SwiftUI
import Charts

// ============================================================
//  NeoClash — Liquid Glass design kit
//  Reusable surfaces & controls mirroring the HTML demo:
//  glass cards, badges, status dots, latency pills, toggle
//  rows, sparklines, donuts, meters, search fields.
// ============================================================

// MARK: - Palette

extension Color {
    static let ncRun = Color.green
    static let ncWarn = Color.orange
    static let ncDanger = Color.red
    static let ncViolet = Color(red: 0.55, green: 0.45, blue: 0.95)

    func soft(_ opacity: Double = 0.16) -> Color { self.opacity(opacity) }
}

// MARK: - Glass card

/// Primary glass surface. Optional header (icon + title + trailing tools).
struct GlassCard<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var padded: Bool = true
    var headerTrailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 9) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer(minLength: 8)
                    if let headerTrailing { headerTrailing }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                Divider().opacity(0.6)
            }
            if padded {
                content()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 13))
    }
}

/// Convenience init without trailing tools.
extension GlassCard {
    init(title: String? = nil, systemImage: String? = nil, padded: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, padded: padded,
                  headerTrailing: nil, content: content)
    }
}

// Legacy alias kept for any external reference.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 14))
    }
}

// MARK: - Status dot

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 9
    var glow: Bool = true
    var pulse: Bool = false
    @State private var on = false

    var body: some View {
        ZStack {
            if glow {
                Circle().fill(color.soft(0.20)).frame(width: size + 8, height: size + 8)
            }
            Circle().fill(color).frame(width: size, height: size)
                .opacity(pulse ? (on ? 0.35 : 1) : 1)
        }
        .frame(width: size + 8, height: size + 8)
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

// MARK: - Badge (pill)

struct Badge: View {
    enum Kind { case run, warn, err, neutral, accent }
    var kind: Kind = .neutral
    var dot: Bool = false
    var text: String

    private var fg: Color {
        switch kind {
        case .run: .ncRun
        case .warn: .ncWarn
        case .err: .ncDanger
        case .neutral: .secondary
        case .accent: .accentColor
        }
    }
    private var bg: Color {
        switch kind {
        case .neutral: Color.gray.soft(0.18)
        default: fg.soft(0.16)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(fg).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(bg, in: .capsule)
    }
}

// MARK: - Latency pill

struct LatencyPill: View {
    var delay: Int?
    var testing: Bool = false

    private var color: Color {
        guard let d = delay, d > 0 else { return .secondary }
        if d < 80 { return .ncRun }
        if d < 160 { return .ncWarn }
        return .ncDanger
    }
    private var label: String {
        if testing { return "testing" }
        guard let d = delay, d > 0 else { return "timeout" }
        return "\(d) ms"
    }

    var body: some View {
        HStack(spacing: 5) {
            if testing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.58)
                    .frame(width: 10, height: 10)
                    .tint(Color.accentColor)
            }
            Text(label)
        }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(testing ? Color.accentColor : color)
            .accessibilityLabel(testing ? "Testing latency" : label)
    }
}

// MARK: - Glyph box (rounded icon chip)

struct GlyphBox: View {
    var systemImage: String
    var size: CGFloat = 28
    var active: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
            }
    }
}

// MARK: - Toggle row

struct ToggleRow: View {
    var systemImage: String
    var title: String
    var hint: String
    @Binding var isOn: Bool
    var warn: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            GlyphBox(systemImage: systemImage, active: isOn)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(warn ? Color.ncWarn : .secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Metric (big number with unit)

struct MetricNumber: View {
    var systemImage: String
    var label: String
    var value: String
    var unit: String?
    var color: Color = .primary
    var dim: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color))
        }
    }
}

/// Small inner stat chip (icon + value + label).
struct MiniStat: View {
    var systemImage: String
    var value: String
    var label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// Legacy tile used elsewhere; kept compatible.
struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var color: Color

    var body: some View {
        GlassCard(padded: true) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title2).foregroundStyle(color).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Sparkline / charts

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var height: CGFloat = 52
    var fill: Bool = true

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { idx, value in
            if fill {
                AreaMark(x: .value("i", idx), y: .value("v", value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(color.opacity(0.18))
            }
            LineMark(x: .value("i", idx), y: .value("v", value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(values.max() ?? 1, 0.001))
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: values)
    }
}

struct WeekBars: View {
    var data: [Double]
    var labels: [String]
    var color: Color
    var height: CGFloat = 120

    private var peak: Double { data.max() ?? 0 }

    var body: some View {
        Chart(Array(data.enumerated()), id: \.offset) { idx, value in
            BarMark(
                x: .value("day", labels[idx]),
                y: .value("mb", value),
                width: .ratio(0.55)
            )
            .clipShape(.rect(cornerRadius: 4))
            .foregroundStyle(value == peak ? color : Color.primary.opacity(0.18))
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .frame(height: height)
    }
}

struct Donut: View {
    struct Segment: Identifiable { var id = UUID(); var value: Double; var color: Color }
    var segments: [Segment]
    var size: CGFloat = 120
    @ViewBuilder var center: () -> AnyView

    var body: some View {
        Chart(segments) { seg in
            SectorMark(
                angle: .value("v", seg.value),
                innerRadius: .ratio(0.72),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(seg.color)
        }
        .frame(width: size, height: size)
        .overlay { center() }
    }
}

// MARK: - Meter

struct Meter: View {
    var value: Double          // 0...1
    var color: Color = .accentColor
    var width: CGFloat? = nil

    private var clamped: Double { min(1, max(0, value)) }

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.12))
            .frame(width: width, height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(color).frame(width: geo.size.width * clamped)
                }
            }
    }
}

// MARK: - Search field

struct NCSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search"
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 28)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

// MARK: - Settings row

struct SetRow<Trailing: View>: View {
    var name: String
    var desc: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium))
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Inline mono "code" chip used for read-only config values.
struct CodeChip: View {
    var text: String
    var width: CGFloat? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(width: width, height: 28)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

// MARK: - Section divider used inside cards

struct CardDivider: View {
    var body: some View { Divider().opacity(0.6).padding(.vertical, 2) }
}

// MARK: - Byte formatting

extension BinaryInteger {
    var bytesPerSecondString: String {
        self == 0 ? "0 KB/s" : ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary) + "/s"
    }
    var byteString: String {
        // ByteCountFormatter renders 0 as "Zero KB"; prefer a tidy "0 B".
        self == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary)
    }
}

/// Split a per-second byte rate into value + unit for the big metric display.
func speedParts(_ bytesPerSecond: Int) -> (value: String, unit: String) {
    let kb = Double(bytesPerSecond) / 1024
    if kb < 1000 { return (String(format: "%.1f", kb), "KB/s") }
    return (String(format: "%.2f", kb / 1024), "MB/s")
}
