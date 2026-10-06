import PodVizCore
import SwiftUI

enum Theme {
    static let red = Color(red: 0.98, green: 0.32, blue: 0.30)
    static let orange = Color(red: 1.00, green: 0.57, blue: 0.22)
    static let yellow = Color(red: 0.97, green: 0.76, blue: 0.20)
    static let green = Color(red: 0.20, green: 0.76, blue: 0.45)
    static let teal = Color(red: 0.15, green: 0.70, blue: 0.78)
    static let blue = Color(red: 0.27, green: 0.55, blue: 1.00)
    static let purple = Color(red: 0.60, green: 0.42, blue: 0.97)
    static let pink = Color(red: 0.94, green: 0.38, blue: 0.67)

    static let accent = LinearGradient(colors: [red, orange], startPoint: .leading, endPoint: .trailing)
    static let glyph = LinearGradient(colors: [Color(red: 1.0, green: 0.47, blue: 0.30), Color(red: 0.90, green: 0.20, blue: 0.40)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Size breakdown colours, largest pod first.
    static let palette: [Color] = [red, orange, yellow, green, teal, blue, purple, pink]

    static let card = Color.primary.opacity(0.045)
    static let cardStroke = Color.primary.opacity(0.06)
    static let track = Color.primary.opacity(0.08)

    static func color(for phase: Phase) -> Color {
        switch phase {
        case .preparing, .analyzing: blue
        case .downloading: orange
        case .generating: purple
        case .integrating: teal
        case .done: green
        case .failed: red
        }
    }

    /// Largest pods get palette colours, shared by the size bar and the pod rows.
    static func sizeColors(_ items: [SizeItem]) -> [String: Color] {
        let ranked = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var map: [String: Color] = [:]
        for (i, item) in ranked.prefix(palette.count).enumerated() { map[item.name] = palette[i] }
        return map
    }

    static func color(for kind: RequestKind) -> Color {
        switch kind {
        case .cdn: teal
        case .git: orange
        case .http: purple
        case .other: .gray
        }
    }
}

enum Fmt {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()

    static func bytes(_ b: Int64) -> String { b <= 0 ? "0 KB" : byteFormatter.string(fromByteCount: b) }
    static func speed(_ bps: Double) -> String { bytes(Int64(bps)) + "/s" }

    static func duration(_ t: TimeInterval) -> String {
        if t < 1 { return "\(Int(t * 1000)) ms" }
        return PodSession.durationText(t)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func count(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : n.formatted()
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

// MARK: - Small components

struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.glyph)
            .overlay(
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.red.opacity(0.28), radius: size * 0.14, y: size * 0.06)
    }
}

struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .background(
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(pulsing && on ? 2.4 : 1)
                    .opacity(pulsing && on ? 0 : 1)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

struct Spinner: View {
    var color: Color
    var lineWidth: CGFloat = 2
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct GradientBar: View {
    var value: Double
    var failed = false
    var live = false
    var height: CGFloat = 6
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = max(height, geo.size.width * min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(failed ? AnyShapeStyle(Theme.red) : AnyShapeStyle(Theme.accent))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        if live {
                            LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 48)
                                .offset(x: sweep ? width : -48)
                        }
                    }
                    .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.45), value: value)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

/// Wraps children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
