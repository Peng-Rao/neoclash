import SwiftUI

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

struct MetricTile: View {
    var title: String
    var value: String
    var systemImage: String
    var color: Color

    var body: some View {
        GlassPanel {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

extension BinaryInteger {
    var bytesPerSecondString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary) + "/s"
    }
}

