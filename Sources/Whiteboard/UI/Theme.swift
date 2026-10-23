import SwiftUI

/// "Darkroom": dark everywhere, the board is the brightest thing on screen, one pastel-green accent.
enum Theme {
    static let accent = Color(red: 0.65, green: 0.89, blue: 0.69)      // pastel green; dark text on it
    static let onAccent = Color.black
    static let card = Color(white: 0.11)
    static let warning = Color.orange
    static let failure = Color.red
    static let secondaryText = Color(white: 0.63)
}

extension View {
    /// Liquid Glass on iOS 26, a material elsewhere.
    @ViewBuilder func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

/// The big pastel capsule ("Save to Photos", "Flatten board").
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 54)
                .padding(.horizontal, 20)
                .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A round glass icon button (Share, Import, Search, Cancel).
struct GlassCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, size: size) }

    private struct Styled: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glass(in: Circle(), interactive: true)
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// The pastel disc: the primary action as a round icon button (landscape side rails).
struct PrimaryCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 54
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, size: size) }

    private struct Styled: View {
        let configuration: Configuration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: Circle())
                .contentShape(Circle())
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == PrimaryCircleButtonStyle { static var primaryCircle: PrimaryCircleButtonStyle { .init() } }
extension ButtonStyle where Self == GlassCircleButtonStyle {
    static var glassCircle: GlassCircleButtonStyle { .init() }
    static func glassCircle(size: CGFloat) -> GlassCircleButtonStyle { .init(size: size) }
}

/// Camera-style shutter: white disc inside a ring that can fill up (`progress`, 0...1) in `ringColor`.
struct ShutterLabel: View {
    var progress: Double = 0
    var ringColor: Color = Theme.accent
    var size: CGFloat = 76
    var icon: String?
    var dimmed = false

    var body: some View {
        let line = size * 0.065
        ZStack {
            Circle().stroke(.white.opacity(0.35), lineWidth: line)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(ringColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
            Circle().fill(.white.opacity(dimmed ? 0.5 : 1)).padding(line * 2.2)
            if let icon { Image(systemName: icon).font(.system(size: size * 0.32, weight: .semibold)).foregroundStyle(.black) }
        }
        .frame(width: size, height: size)
        .padding(line / 2)
    }
}

/// Small status line: coloured dot + text, or a spinner while processing.
struct StatusBadge: View {
    let board: Board
    let stage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let stage {
                ProgressView().controlSize(.mini).tint(.white)
                Text(stage)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text)
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(stage == nil ? color : Theme.secondaryText)
        .lineLimit(1)
    }

    private var text: String {
        switch board.status {
        case .draft: "Not flattened"
        case .failed: "Failed"
        case .done: board.warnings.isEmpty ? "Done" : "\(board.warnings.count) warning\(board.warnings.count == 1 ? "" : "s")"
        }
    }

    private var color: Color {
        switch board.status {
        case .draft: Theme.secondaryText
        case .failed: Theme.failure
        case .done: board.warnings.isEmpty ? Theme.accent : Theme.warning
        }
    }
}

extension Board {
    /// "Today, 14:05" / "Yesterday, 09:12" / "17 Oct, 14:05" / "17 Oct 2025".
    func whenText(now: Date = .now, calendar: Calendar = .current) -> String {
        let time = created.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(created, inSameDayAs: now) { return "Today, \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(created, inSameDayAs: y) { return "Yesterday, \(time)" }
        if calendar.isDate(created, equalTo: now, toGranularity: .year) {
            return "\(created.formatted(.dateTime.day().month(.abbreviated))), \(time)"
        }
        return created.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "6 photos" or "5 of 6 photos" when some were left out.
    var photoCountText: String {
        let n = photos.count, used = usedPhotoCount
        let noun = n == 1 ? "photo" : "photos"
        return used < n ? "\(used) of \(n) \(noun)" : "\(n) \(noun)"
    }
}

/// Boards grouped for the home screen: Today and Yesterday as big cards, then one compact group per month.
struct BoardSection: Identifiable, Equatable {
    var title: String
    var boards: [Board]
    var compact: Bool
    var id: String { title }

    static func group(_ boards: [Board], now: Date = .now, calendar: Calendar = .current) -> [BoardSection] {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        var out: [BoardSection] = []
        func add(_ title: String, _ b: Board, compact: Bool) {
            if out.last?.title == title { out[out.count - 1].boards.append(b) } else { out.append(.init(title: title, boards: [b], compact: compact)) }
        }
        for b in boards.sorted(by: { $0.created > $1.created }) {
            if calendar.isDate(b.created, inSameDayAs: now) { add("Today", b, compact: false) }
            else if calendar.isDate(b.created, inSameDayAs: yesterday) { add("Yesterday", b, compact: false) }
            else if calendar.isDate(b.created, equalTo: now, toGranularity: .month) {
                add("Earlier in \(now.formatted(.dateTime.month(.wide)))", b, compact: true)
            } else if calendar.isDate(b.created, equalTo: now, toGranularity: .year) {
                add(b.created.formatted(.dateTime.month(.wide)), b, compact: true)
            } else {
                add(b.created.formatted(.dateTime.month(.wide).year()), b, compact: true)
            }
        }
        return out
    }
}
