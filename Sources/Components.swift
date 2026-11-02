import SwiftUI
import AppKit

// MARK: - Formatting

func level(_ v: Double) -> Color {
    v < 0.6 ? .green : v < 0.85 ? .orange : .red
}

/// Apple Silicon runs comfortably up to ~70°C and throttles in the 90s.
func temperatureColor(_ celsius: Double?) -> Color {
    guard let celsius else { return .secondary }
    return celsius < 70 ? .green : celsius < 85 ? .orange : .red
}

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .memory
    f.allowsNonnumericFormatting = false
    return f
}()

/// Clamps to a range that converts to Int safely (NaN/inf/negative/huge would trap).
private func safe(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 9e18) : 0 }

func bytes(_ b: Double) -> String { byteFormatter.string(fromByteCount: Int64(safe(b))) }
func rate(_ b: Double) -> String { bytes(b) + "/s" }
func percent(_ v: Double) -> String { "\(Int(safe(v * 100).rounded()))%" }
func gigabytes(_ b: UInt64) -> String { String(format: "%.1fG", Double(b) / 1_073_741_824) }

/// "3h 20m", "45m".
func duration(_ seconds: Double) -> String {
    let minutes = Int(safe(seconds) / 60)
    return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

/// Compact form for the pill, e.g. "830K", "1.2M".
func shortBytes(_ value: Double) -> String {
    let b = safe(value)
    return switch b {
    case ..<1_000: "\(Int(b))B"
    case ..<1_000_000: "\(Int(b / 1_000))K"
    case ..<1_000_000_000: String(format: "%.1fM", b / 1_000_000)
    default: String(format: "%.1fG", b / 1_000_000_000)
    }
}

// MARK: - Small views

struct Sparkline: Shape {
    var values: [Double]   // 0...1
    var capacity: Int
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, capacity > 1 else { return path }
        let step = rect.width / CGFloat(capacity - 1)
        let start = rect.width - step * CGFloat(values.count - 1)
        // NaN marks time the app wasn't running: draw each run of real samples as its own segment.
        var segment: [CGPoint] = []
        func flush() {
            defer { segment.removeAll() }
            guard let first = segment.first, let last = segment.last, segment.count > 1 else { return }
            path.move(to: first)
            segment.dropFirst().forEach { path.addLine(to: $0) }
            if closed {
                path.addLine(to: CGPoint(x: last.x, y: rect.height))
                path.addLine(to: CGPoint(x: first.x, y: rect.height))
                path.closeSubpath()
            }
        }
        for (i, v) in values.enumerated() {
            guard v.isFinite else { flush(); continue }
            segment.append(CGPoint(x: start + step * CGFloat(i), y: rect.height * (1 - CGFloat(min(max(v, 0), 1)))))
        }
        flush()
        return path
    }
}

struct Ring: View {
    let value: Double
    var color: Color?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: 2.5)
            Circle().trim(from: 0, to: max(value, 0.001))
                .stroke(color ?? level(value), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}

struct MetricChip: View {
    let label: String
    var ring: Double?
    var color: Color?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let ring { Ring(value: ring, color: color) }
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color
    let history: [Double]
    let capacity: Int
    /// For rate series: scale the graph to its own peak, but never below this floor.
    var autoScaleFloor: Double?
    let lines: [String]
    /// Seconds between graph points, used to show the time of a hovered point.
    var secondsPerPoint: Double = 1.5
    /// Formats a raw history value for the hover readout.
    var format: (Double) -> String = percent
    /// What was behind each point (e.g. the top app), aligned with `history`.
    var labels: [String]?

    @State private var hovered: Int?

    private var normalized: [Double] {
        guard let floor = autoScaleFloor else { return history }
        let peak = max(history.filter(\.isFinite).max() ?? 0, floor)
        return history.map { $0 / peak }
    }

    /// Hover readout: the time and value of the point under the mouse, then its label if any.
    private var hoverLines: [String]? {
        guard let i = hovered, history.indices.contains(i) else { return nil }
        let secondsAgo = Double(history.count - 1 - i) * secondsPerPoint
        let when = secondsAgo < 30 ? "Now" : pointTime(Date().addingTimeInterval(-secondsAgo))
        let value = history[i]
        guard value.isFinite else { return [when, "No data · Glass Monitor wasn't running"] }
        let label = labels.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? ""
        return ["\(when) · \(format(value))", label.isEmpty ? " " : label]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            ZStack {
                Sparkline(values: normalized, capacity: capacity, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                Sparkline(values: normalized, capacity: capacity).stroke(tint, lineWidth: 1.5)
            }
            .frame(height: 22)
            .overlay { hoverLayer }
            ForEach(Array((hoverLines ?? lines).enumerated()), id: \.offset) { index, line in
                Text(line).font(.system(size: 9.5, weight: hoverLines != nil && index == 0 ? .semibold : .regular))
                    .foregroundStyle(hoverLines != nil && index == 0 ? Color.primary : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Tracks the mouse over the graph (same x mapping as `Sparkline`) and marks the hovered point.
    private var hoverLayer: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(capacity - 1, 1))
            let start = geo.size.width - step * CGFloat(max(history.count - 1, 0))
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                if let i = hovered {
                    Rectangle().fill(Color.primary.opacity(0.5))
                        .frame(width: 1, height: geo.size.height)
                        .offset(x: start + step * CGFloat(i))
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where !history.isEmpty && point.x >= start - step / 2:
                    hovered = min(max(Int(((point.x - start) / step).rounded()), 0), history.count - 1)
                default:
                    hovered = nil
                }
            }
        }
    }
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return f
}()

/// "14:32", or "Yesterday 22:10" for points from the previous day.
func pointTime(_ date: Date) -> String {
    let time = timeFormatter.string(from: date)
    return Calendar.current.isDateInToday(date) ? time : "Yesterday \(time)"
}

struct PillButton: View {
    let title: String
    /// nil = neutral.
    var color: Color?
    let action: () -> Void

    init(_ title: String, _ color: Color? = nil, action: @escaping () -> Void) {
        self.title = title
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(color == nil ? Color.primary : .white)
                .background(color ?? Color.primary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ProcessIcon: View {
    let bundlePath: String?
    let user: String
    var symbol: String?

    var body: some View {
        if let bundlePath {
            Image(nsImage: Icons.app(bundlePath)).resizable().interpolation(.high).frame(width: 22, height: 22)
        } else {
            Image(systemName: symbol ?? (user == "root" || user.hasPrefix("_") ? "gearshape.2.fill" : "terminal.fill"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }
}

/// A list row: icon, title + subtitle, and trailing content that knows whether the row is hovered.
struct HoverRow<Trailing: View>: View {
    var leading: CGFloat = 8
    let icon: AnyView
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: (Bool) -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(hovering)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(hovering ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
