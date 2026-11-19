import QodeNotchCore
import SwiftUI

/// Plan limits (from Anthropic, like `/usage` in Claude Code) and local token usage.
struct UsageView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Zurück", shortcut: "←") { store.route = .list }
                Text("Limits & Nutzung").scaledFont(size: 13, weight: .bold)
                if let plan = store.limits?.plan {
                    Chip(text: plan.capitalized, symbol: "person.crop.circle", help: "Dein Claude-Abo")
                }
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Aktualisieren") {
                    store.refreshLimits(force: true)
                    store.refreshUsage()
                }
            }

            section("Claude-Abo (Anthropic)") { limitsBlock }
            if let codex = store.codexLimits {
                section("Codex (OpenAI\(codex.plan.map { " · " + $0.capitalized } ?? ""))") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(codex.limits) { LimitRow(limit: $0) }
                        Text("Aus der letzten Codex-Session, Stand \(codex.fetchedAt.formatted(date: .omitted, time: .shortened))")
                            .scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.35))
                    }
                }
            }
            section("Token-Nutzung dieses Macs – alle Agents (7 Tage)") { usageBlock }
        }
        .onAppear {
            store.refreshLimits()
            store.refreshUsage()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).scaledFont(size: 9, weight: .bold).foregroundStyle(Color.primary.opacity(0.45))
            content()
        }
    }

    @ViewBuilder
    private var limitsBlock: some View {
        if !store.config.showLimits {
            Text("Abfrage ist in den Einstellungen ausgeschaltet.").scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.5))
        } else if let limits = store.limits {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(limits.limits) { LimitRow(limit: $0) }
                Text("Stand \(limits.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.35))
            }
        } else if let err = store.limitsError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.7))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var usageBlock: some View {
        if let r = store.usageReport {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    stat("Heute", r.today.total)
                    stat("7 Tage", r.total.total)
                    stat("Ausgabe 7 Tage", r.total.output)
                }
                DailyBars(days: r.days)
                ForEach(r.byModel.prefix(4), id: \.model) { item in
                    HStack {
                        Text(ModelName.pretty(item.model)).scaledFont(size: 11, weight: .medium)
                        Spacer()
                        Text(TokenFormat.short(item.usage.total)).scaledFont(size: 11, design: .monospaced)
                            .foregroundStyle(Color.primary.opacity(0.7))
                    }
                }
                Text("Summe aller Tokens (Eingabe, Cache, Ausgabe) aus den lokalen Verläufen von Claude Code, Codex und Copilot CLI – Sessions auf anderen Geräten oder im Web sind nicht enthalten. Copilot schreibt Token-Zahlen nicht immer mit.")
                    .scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.35))
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TokenFormat.short(value)).scaledFont(size: 16, weight: .bold, design: .rounded)
            Text(label).scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.5))
        }
    }
}

/// One plan limit: label + percent in text ink, a single-hue bar; above 80 %
/// a warning icon is added (status never by color alone).
struct LimitRow: View {
    var limit: UsageLimit
    var compact = false
    @Environment(\.notchScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if limit.percent >= 80 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(size: 9).foregroundStyle(limit.percent >= 95 ? Color.red : SessionStatus.waiting.color)
                }
                Text(limit.title).scaledFont(size: 11, weight: .medium)
                Spacer()
                Text("\(Int(limit.percent.rounded())) %").scaledFont(size: 11, weight: .semibold, design: .monospaced)
                if let reset = limit.resetsAt {
                    Text("· zurück \(resetText(reset))").scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.45))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(barColor)
                        .frame(width: max(4, g.size.width * min(limit.percent, 100) / 100))
                }
            }
            .frame(height: 5 * scale)
        }
    }

    private var barColor: Color {
        if limit.percent >= 95 { return .red }
        if limit.percent >= 80 { return SessionStatus.waiting.color }
        return SessionStatus.working.color
    }

    private func resetText(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "jetzt" }
        if secs < 3600 { return "in \(Int(secs / 60)) min" }
        if secs < 86400 { return "in \(Int(secs / 3600)) h \(Int(secs.truncatingRemainder(dividingBy: 3600) / 60)) min" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Tokens per day, one bar per day (single series → no legend; hover shows the value).
private struct DailyBars: View {
    var days: [DailyUsage]
    @Environment(\.notchScale) private var scale

    var body: some View {
        let maxValue = max(days.map(\.total.total).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { d in
                VStack(spacing: 3) {
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                        .fill(SessionStatus.working.color.opacity(Calendar.current.isDateInToday(d.day) ? 1 : 0.6))
                        .frame(height: max(2, 44 * scale * CGFloat(d.total.total) / CGFloat(maxValue)))
                        .help("\(d.day.formatted(date: .abbreviated, time: .omitted)): \(TokenFormat.short(d.total.total)) Tokens")
                    Text(d.day.formatted(.dateTime.weekday(.narrow))).scaledFont(size: 9).foregroundStyle(Color.primary.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 44 * scale + 16 * scale, alignment: .bottom)
    }
}

/// Compact limit indicator for the header: the 5-hour window.
struct LimitBadge: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if store.config.showLimits, let limit = store.limits?.limits.first {
            Button { store.route = .usage } label: {
                HStack(spacing: 3) {
                    if limit.percent >= 80 { Image(systemName: "exclamationmark.triangle.fill").scaledFont(size: 8) }
                    Text("\(limit.shortTitle) \(Int(limit.percent.rounded())) %").scaledFont(size: 10, weight: .semibold, design: .monospaced)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(limit.percent >= 80 ? SessionStatus.waiting.color : Color.primary.opacity(0.7))
                .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Limits & Nutzung (U)")
        }
    }
}
