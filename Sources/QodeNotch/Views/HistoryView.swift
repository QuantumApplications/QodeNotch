import QodeNotchCore
import SwiftUI

/// All sessions Claude Code has stored, searchable, reopenable.
struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout
    @State private var query = ""

    private var filtered: [PastSession] { SessionHistory.filter(store.history, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Zurück", shortcut: "←") { store.route = .list }
                Text("Alle Sessions").font(.system(size: 13, weight: .bold))
                Text("\(store.history.count)").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.45))
                Spacer()
                Text(strategyText).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.45))
                IconButton(symbol: "arrow.clockwise", help: "Neu laden") { store.loadHistory() }
            }
            NotchTextField(placeholder: "Suchen nach Titel, Pfad, Branch …", text: $query) {
                if let first = filtered.first { store.resume(first) }
            }

            if store.isLoadingHistory {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(.vertical, 20)
            } else if filtered.isEmpty {
                Text(store.history.isEmpty ? "Keine gespeicherten Sessions in ~/.claude/projects gefunden." : "Keine Treffer.")
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
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
        CGFloat(store.config.maxExpandedHeight) - max(layout.geometry.notchHeight, 28) - 100
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
                    Text(past.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(past.lastActivity.relative).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.4))
                }
                HStack(spacing: 5) {
                    Text(past.repoName).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(0.6))
                    if let b = past.branch, !b.isEmpty, b != "HEAD" { Chip(text: b, symbol: "arrow.triangle.branch") }
                    if let dir = past.workingDirectory {
                        Text(Paths.abbreviateHome(dir)).font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.35))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !exists { Chip(text: "Ordner fehlt", symbol: "exclamationmark.triangle", color: .orange) }
                }
                if let summary = past.summary, hovering {
                    Text(summary).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(2)
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
                copy("cd \(Shell.quote(past.workingDirectory ?? "~")) && claude --resume \(past.id)")
            }
        }
        .help(past.summary ?? past.title)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
