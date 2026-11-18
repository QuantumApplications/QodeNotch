import QodeNotchCore
import SwiftUI

/// How a CI/pipeline status is shown: label + icon + color (never color alone).
struct PipelineStyle {
    var label: String
    var symbol: String
    var color: Color

    init(_ raw: String?) {
        switch (raw ?? "").lowercased() {
        case "success", "passing":
            self.init("Pipeline erfolgreich", "checkmark.circle.fill", .green)
        case "failed", "failure", "failing", "error":
            self.init("Pipeline fehlgeschlagen", "xmark.octagon.fill", .red)
        case "running":
            self.init("Pipeline läuft", "arrow.triangle.2.circlepath", SessionStatus.working.color)
        case "pending", "created", "preparing", "waiting_for_resource", "scheduled", "waiting_for_callback":
            self.init("Pipeline wartet", "clock.fill", .yellow)
        case "manual":
            self.init("Manueller Schritt", "hand.tap.fill", SessionStatus.waiting.color)
        case "canceled", "cancelled", "canceling":
            self.init("Pipeline abgebrochen", "stop.circle", .gray)
        case "skipped":
            self.init("Pipeline übersprungen", "forward.circle", .gray)
        case "", "none":
            self.init("Keine Pipeline", "minus.circle", .gray)
        default:
            self.init("Pipeline: \(raw ?? "?")", "questionmark.circle", .gray)
        }
    }

    private init(_ label: String, _ symbol: String, _ color: Color) {
        self.label = label
        self.symbol = symbol
        self.color = color
    }
}

extension PrStatus {
    var stateLabel: (text: String, symbol: String, color: Color) {
        switch state {
        case "MERGED": return ("Gemergt", "arrow.triangle.merge", .purple)
        case "CLOSED": return ("Geschlossen", "xmark.circle", .gray)
        default: return isDraft ? ("Entwurf", "pencil.circle", .gray) : ("Offen", "circle.dotted", .green)
        }
    }
}

/// One PR/MR: reference, title, state and pipeline – all clickable.
struct PullRequestRow: View {
    var url: String
    var status: PrStatus?
    var compact = false

    @EnvironmentObject private var store: SessionStore
    @State private var hovering = false

    private var isMR: Bool { PullRequestService.isMergeRequestURL(url) }
    private var reference: String { status?.reference ?? ((isMR ? "!" : "#") + (url.split(separator: "/").last.map(String.init) ?? "")) }
    private var projectName: String {
        if let mr = PullRequestService.gitLabMR(url) { return Paths.repoName(from: mr.project) }
        let parts = url.split(separator: "/")
        return parts.count >= 4 ? String(parts[parts.count - 3]) : ""
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isMR ? "arrow.triangle.merge" : "arrow.triangle.pull")
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(Color.primary.opacity(0.5))
            Text(reference).scaledFont(size: 10.5, weight: .bold, design: .monospaced)
            if let s = status {
                let st = s.stateLabel
                Label(st.text, systemImage: st.symbol)
                    .scaledFont(size: 9.5, weight: .semibold)
                    .foregroundStyle(st.color)
                    .labelStyle(.titleAndIcon)
                Text(s.title ?? projectName)
                    .scaledFont(size: 10.5)
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(projectName).scaledFont(size: 10.5).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
            }
            Spacer(minLength: 4)
            if let s = status {
                if s.mergeable == "CONFLICTING" {
                    Image(systemName: "exclamationmark.triangle.fill").scaledFont(size: 9).foregroundStyle(.orange)
                        .help("Merge-Konflikte")
                }
                if s.unresolvedThreads > 0 {
                    Label("\(s.unresolvedThreads)", systemImage: "text.bubble")
                        .scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.6))
                        .help("\(s.unresolvedThreads) offene Diskussionen")
                }
                if s.reviewDecision == "APPROVED" {
                    Image(systemName: "hand.thumbsup.fill").scaledFont(size: 9).foregroundStyle(.green).help("Freigegeben (Approved)")
                } else if s.reviewDecision == "CHANGES_REQUESTED" {
                    Image(systemName: "exclamationmark.bubble.fill").scaledFont(size: 9).foregroundStyle(.orange).help("Änderungen angefordert")
                }
                pipelineButton(s)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 2.5 : 4)
        .background(Color.primary.opacity(hovering ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openURL(url) }
        .help("\(isMR ? "Merge Request" : "Pull Request") öffnen: \(url)")
        .contextMenu {
            Button(isMR ? "Merge Request öffnen" : "Pull Request öffnen") { store.openURL(url) }
            if let p = status?.pipelineUrl { Button("Pipeline öffnen") { store.openURL(p) } }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func pipelineButton(_ s: PrStatus) -> some View {
        let style = PipelineStyle(s.pipelineStatus)
        Button {
            store.openURL(s.pipelineUrl ?? url)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: style.symbol).scaledFont(size: 9, weight: .bold)
                if !compact { Text(style.label).scaledFont(size: 9.5, weight: .medium) }
            }
            .foregroundStyle(style.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(style.color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(style.label + (s.checksTotal > 1 ? " (\(s.checksPassing)/\(s.checksTotal) Checks ok)" : "") + " – öffnen")
    }
}

/// PR/MR list of a session.
struct SessionPullRequests: View {
    var session: ClaudeSession
    var limit: Int = 3
    var compact = true

    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if !session.linkedPRs.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(session.linkedPRs.prefix(limit), id: \.self) { url in
                    PullRequestRow(url: url, status: store.prStatuses[url], compact: compact)
                }
                if session.linkedPRs.count > limit {
                    Button("+ \(session.linkedPRs.count - limit) weitere") { store.openDetail(session.id) }
                        .buttonStyle(.plain)
                        .scaledFont(size: 9.5)
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
            }
        }
    }
}

/// Every PR/MR of all running sessions in one place.
struct PullRequestsOverview: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout

    private var sessions: [ClaudeSession] { store.sessions.filter { !$0.linkedPRs.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Zurück", shortcut: "←") { store.route = .list }
                Text("Pull & Merge Requests").scaledFont(size: 13, weight: .bold)
                Text(summary).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.45))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Status neu laden") { store.refreshPullRequests(force: true) }
            }
            if sessions.isEmpty {
                Text("Keine PRs/MRs in den laufenden Sessions – weder zum aktuellen Branch noch im Verlauf erwähnt.")
                    .scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.5))
                    .padding(.vertical, 12)
            } else {
                FittingScrollView(maxHeight: maxHeight) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sessions) { s in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    StatusOrb(status: s.status, size: 7)
                                    Text(s.repoName).scaledFont(size: 11, weight: .bold)
                                    if let name = s.sessionLabel {
                                        Text("· " + name).scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.6)).lineLimit(1)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { store.openDetail(s.id) }
                                SessionPullRequests(session: s, limit: 10, compact: false)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { store.refreshPullRequests(force: false) }
    }

    private var maxHeight: CGFloat {
        store.config.scaledMaxHeight - max(layout.geometry.notchHeight, 28) - 130 * store.config.scale
    }

    private var summary: String {
        let all = Set(sessions.flatMap(\.linkedPRs))
        let statuses = all.compactMap { store.prStatuses[$0] }
        let failing = statuses.filter { ["failed", "failure", "failing", "error"].contains(($0.pipelineStatus ?? "").lowercased()) }.count
        let open = statuses.filter { $0.state == "OPEN" }.count
        var parts = ["\(all.count) gesamt", "\(open) offen"]
        if failing > 0 { parts.append("\(failing) Pipeline fehlgeschlagen") }
        return parts.joined(separator: " · ")
    }
}
