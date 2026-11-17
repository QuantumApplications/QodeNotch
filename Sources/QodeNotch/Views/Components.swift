import QodeNotchCore
import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .working: return Color(red: 0.36, green: 0.62, blue: 1.0)
        case .waiting: return Color(red: 1.0, green: 0.66, blue: 0.22)
        case .idle: return Color(red: 0.35, green: 0.85, blue: 0.5)
        case .errored: return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .finished: return Color.gray
        }
    }

    var symbol: String {
        switch self {
        case .working: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .idle: return "checkmark"
        case .errored: return "exclamationmark.triangle.fill"
        case .finished: return "stop.fill"
        }
    }
}

/// Notch silhouette: concave "ears" at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.height - t) / 2, rect.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Animated status indicator: pulses while working, bounces while waiting.
struct StatusOrb: View {
    var status: SessionStatus?
    var size: CGFloat = 10

    @State private var animate = false

    var body: some View {
        let color = status?.color ?? .gray.opacity(0.5)
        ZStack {
            if status == .working || status == .waiting {
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 1.5)
                    .scaleEffect(animate ? 2.0 : 1.0)
                    .opacity(animate ? 0 : 0.9)
            }
            Circle()
                .fill(color)
                .shadow(color: color.opacity(0.8), radius: status == nil ? 0 : 3)
                .offset(y: status == .waiting && animate ? -1.5 : 0)
        }
        .frame(width: size, height: size)
        .onAppear { restart() }
        .onChange(of: status) { _, _ in restart() }
    }

    private func restart() {
        animate = false
        guard status == .working || status == .waiting else { return }
        withAnimation(.easeOut(duration: status == .waiting ? 0.7 : 1.3).repeatForever(autoreverses: status == .waiting)) {
            animate = true
        }
    }
}

struct StatusPill: View {
    var status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).font(.system(size: 8, weight: .bold))
            Text(status.label).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(status.color)
        .background(status.color.opacity(0.15), in: Capsule())
    }
}

struct Chip: View {
    var text: String
    var symbol: String?
    var color: Color = Color.primary.opacity(0.6)

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .semibold)) }
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct GitStatsView: View {
    var git: GitSummary

    var body: some View {
        HStack(spacing: 5) {
            if git.isClean {
                Text("sauber").foregroundStyle(Color.primary.opacity(0.4))
            } else {
                if git.additions > 0 { Text("+\(git.additions)").foregroundStyle(.green) }
                if git.deletions > 0 { Text("−\(git.deletions)").foregroundStyle(.red.opacity(0.9)) }
                Text("\(git.changedFiles + git.untrackedFiles) Dat.").foregroundStyle(Color.primary.opacity(0.45))
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }
}

struct PrBadge: View {
    var url: String
    var status: PrStatus?

    var body: some View {
        let (color, symbol) = style
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text("#\(status?.number ?? url.split(separator: "/").last.map(String.init) ?? "PR")")
                .font(.system(size: 10, weight: .semibold))
            if let s = status {
                if s.unresolvedThreads > 0 {
                    Image(systemName: "text.bubble").font(.system(size: 8))
                    Text("\(s.unresolvedThreads)").font(.system(size: 9))
                }
                if s.mergeable == "CONFLICTING" {
                    Image(systemName: "arrow.triangle.merge").font(.system(size: 8)).foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .help(tooltip)
    }

    private var style: (Color, String) {
        guard let s = status else { return (Color.primary.opacity(0.6), "arrow.triangle.pull") }
        if s.state == "MERGED" { return (.purple, "arrow.triangle.merge") }
        if s.state == "CLOSED" { return (.gray, "xmark.circle") }
        if s.reviewDecision == "CHANGES_REQUESTED" { return (.orange, "exclamationmark.bubble") }
        switch s.checks {
        case .failing: return (.red, "xmark")
        case .pending: return (.yellow, "clock")
        case .passing: return (s.reviewDecision == "APPROVED" ? .green : .mint, "checkmark")
        case .none: return (Color.primary.opacity(0.7), "arrow.triangle.pull")
        }
    }

    private var tooltip: String {
        guard let s = status else { return url }
        var parts = ["Status: \(s.state)"]
        if s.checksTotal > 0 { parts.append("Checks: \(s.checksPassing)/\(s.checksTotal) ok, \(s.checksFailing) fehlgeschlagen, \(s.checksPending) laufend") }
        if let r = s.reviewDecision { parts.append("Review: \(r)") }
        if s.unresolvedThreads > 0 { parts.append("\(s.unresolvedThreads) offene Threads") }
        if s.mergeable == "CONFLICTING" { parts.append("Merge-Konflikte") }
        return parts.joined(separator: "\n")
    }
}

/// Small icon button used in action bars.
struct IconButton: View {
    var symbol: String
    var help: String
    var shortcut: String?
    var tint: Color = Color.primary
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.7))
                .background(Color.primary.opacity(hovering ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(help) (\($0))" } ?? help)
    }
}

/// Prominent text button (approve/reject etc.).
struct PillButton: View {
    var title: String
    var symbol: String?
    var color: Color
    var filled = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(filled ? Color.black : color)
            .background(filled ? color.opacity(hovering ? 1 : 0.88) : color.opacity(hovering ? 0.25 : 0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Text field that tells the panel controller while it is being edited
/// (prevents the notch from collapsing under the user's cursor).
struct NotchTextField: View {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    @EnvironmentObject private var layout: NotchLayout
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(focused ? 0.25 : 0.08)))
            .focused($focused)
            .onSubmit(onSubmit)
            .onChange(of: focused) { _, f in layout.isEditing = f }
    }
}

extension Date {
    var relative: String {
        let s = Int(Date().timeIntervalSince(self))
        if s < 10 { return "jetzt" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// Measures a view's height.
struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func measureHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            .onPreferenceChange(HeightKey.self, perform: onChange)
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// ScrollView that is only as tall as its content (up to `maxHeight`).
struct FittingScrollView<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 40

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            content.background(GeometryReader { g in
                Color.clear.preference(key: ScrollContentHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(ScrollContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}
