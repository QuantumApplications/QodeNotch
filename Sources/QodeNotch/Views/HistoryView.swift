import QodeNotchCore
import SwiftUI

/// All sessions stored by Claude Code, Codex and Copilot CLI – searchable, reopenable.
struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout
    @State private var query = ""
    @State private var agentFilter: Agent?

    private var filtered: [PastSession] {
        SessionHistory.filter(store.history.filter { agentFilter == nil || $0.agent == agentFilter }, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Zurück", shortcut: "←") { store.route = .list }
                Text("Alle Sessions").scaledFont(size: 13, weight: .bold)
                Text("\(store.history.count)").scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.45))
                Spacer()
                Text(strategyText).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.45))
                IconButton(symbol: "arrow.clockwise", help: "Neu laden") { store.loadHistory() }
            }
            HStack(spacing: 6) {
                PillButton(title: "Web-Sessions (claude.ai)", symbol: "globe", color: SessionStatus.working.color, filled: false) {
                    store.openURL(SessionActions.claudeWebCodeURL)
                }
                PillButton(title: "Claude Desktop", symbol: "macwindow", color: .purple, filled: false) {
                    Task { try? await SessionActions.openInClaudeDesktop(hostSessionId: nil) }
                }
                Spacer()
                Picker("", selection: $agentFilter) {
                    Text("Alle").tag(Agent?.none)
                    ForEach(Agent.allCases) { Text($0.label).tag(Agent?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 280)
            }
            NotchTextField(placeholder: "Suchen nach Titel, Pfad, Branch …", text: $query) {
                if let first = filtered.first { store.resume(first) }
            }

            if store.isLoadingHistory {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
            } else if filtered.isEmpty {
                Text(store.history.isEmpty ? "Keine gespeicherten Sessions in ~/.claude/projects gefunden." : "Keine Treffer.")
                    .scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.5))
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                FittingScrollView(maxHeight: maxListHeight) {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered.prefix(200)) { past in
                            HistoryRow(past: past, live: store.liveSession(for: past))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { store.loadHistory() }
    }

    private var maxListHeight: CGFloat {
        store.config.scaledMaxHeight - max(layout.geometry.notchHeight, 28) - 160 * store.config.scale
    }

    private var strategyText: String {
        SessionResumer.effectiveStrategy(store.config.resumeStrategy) == .airlock ? "öffnet mit airlock" : "claude --resume"
    }
}

private struct HistoryRow: View {
    var past: PastSession
    var live: ClaudeSession?

    @EnvironmentObject private var store: SessionStore
    @State private var hovering = false

    var body: some View {
        let exists = past.directoryExists
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let live { StatusOrb(status: live.status, size: 7) }
                    Image(systemName: past.agent.symbol).scaledFont(size: 9).foregroundStyle(past.agent.color).help(past.agent.label)
                    Text(past.title).scaledFont(size: 11.5, weight: .semibold).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(past.lastActivity.relative).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.4))
                }
                HStack(spacing: 5) {
                    Text(past.repoName).scaledFont(size: 10, weight: .medium).foregroundStyle(Color.primary.opacity(0.6))
                    if let b = past.branch, !b.isEmpty, b != "HEAD" { Chip(text: b, symbol: "arrow.triangle.branch") }
                    if let dir = past.workingDirectory {
                        Text(Paths.abbreviateHome(dir)).scaledFont(size: 9.5).foregroundStyle(Color.primary.opacity(0.35))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !exists { Chip(text: "Ordner fehlt", symbol: "exclamationmark.triangle", color: .orange) }
                }
                if let summary = past.summary, hovering {
                    Text(summary).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(2)
                }
            }
            if hovering || live != nil {
                if let live {
                    PillButton(title: "Läuft", symbol: "macwindow", color: live.status.color, filled: false) { store.focus(live) }
                } else {
                    PillButton(title: "Öffnen", symbol: "play.fill", color: SessionStatus.working.color) { store.resume(past) }
                        .disabled(!exists)
                        .opacity(exists ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(hovering ? 0.07 : 0.03)))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if exists { store.resume(past) } }
        .contextMenu {
            Button(live != nil ? "Zum Terminal" : "Öffnen") { store.resume(past) }.disabled(!exists && live == nil)
            if let dir = past.workingDirectory, exists {
                Button("Im Finder zeigen") { Task { try? await SessionActions.openInFinder(path: dir) } }
                Button("Pfad kopieren") { copy(dir) }
            }
            Button("Session-ID kopieren") { copy(past.id) }
            Button("Resume-Befehl kopieren") {
                let cmd = SessionResumer.command(for: past, config: store.config) ?? "claude --resume \(past.id)"
                copy("cd \(Shell.quote(past.workingDirectory ?? "~")) && \(cmd)")
            }
        }
        .help(past.summary ?? past.title)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
