import NeoClashMobileCore
import SwiftUI

/// NeoClash's palette. The gradient comes from the app icon; status colours match the macOS app.
enum NC {
    static let blue = Color(red: 0.42, green: 0.51, blue: 1.00)
    static let indigo = Color(red: 0.39, green: 0.40, blue: 0.96)
    static let violet = Color(red: 0.58, green: 0.40, blue: 0.95)
    static let run = Color.green
    static let warn = Color.orange
    static let danger = Color.red

    static let brand = LinearGradient(colors: [blue, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brandAngular = AngularGradient(colors: [blue, indigo, violet, blue], center: .center)
    static let brandVertical = LinearGradient(colors: [blue, violet], startPoint: .top, endPoint: .bottom)

    static let pagePadding: CGFloat = 20
}

extension View {
    /// Readouts sit in SF Mono, matching the macOS app's instrument feel.
    func ncMono(_ style: Font.TextStyle = .caption, weight: Font.Weight = .medium) -> some View {
        font(.system(style, design: .monospaced, weight: weight))
    }
}

extension CoreStatus {
    var tint: Color {
        switch self {
        case .running: NC.run
        case .starting, .stopping: NC.warn
        case .crashed: NC.danger
        case .stopped: .secondary
        }
    }
}

/// Latency in the macOS app's bands. No value means the node has not answered yet.
struct LatencyLabel: View {
    var delay: Int?
    var isTesting = false

    var body: some View {
        Group {
            if isTesting {
                ProgressView()
                    .controlSize(.mini)
            } else if let delay {
                Text("\(delay) ms")
                    .foregroundStyle(Self.color(for: delay))
                    .contentTransition(.numericText())
            } else {
                Text("-")
                    .foregroundStyle(.tertiary)
            }
        }
        .ncMono(.caption)
        .frame(minWidth: 56, alignment: .trailing)
        .accessibilityLabel(delay.map { "\($0) milliseconds" } ?? "No latency measured")
    }

    static func color(for delay: Int) -> Color {
        switch delay {
        case ..<80: NC.run
        case ..<160: NC.warn
        default: NC.danger
        }
    }
}

struct NCEmptyState<Actions: View>: View {
    var systemImage: String
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            actions()
        }
    }
}

extension NCEmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Shown wherever a screen has nothing until the core runs.
struct StoppedState: View {
    @Environment(IOSAppCoordinator.self) private var coordinator
    var title: String
    var message: String

    var body: some View {
        NCEmptyState(systemImage: "bolt.horizontal", title: title, message: message) {
            Button("Start") {
                Task { await coordinator.startEngine() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.isBusy)
        }
    }
}

func byteString(_ value: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    // Readouts should say "0 KB", not the formatter's default "Zero KB" or a jump through bytes.
    formatter.allowsNonnumericFormatting = false
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: Int64(value))
}

func rateString(_ bytesPerSecond: Int) -> String {
    "\(byteString(bytesPerSecond))/s"
}
