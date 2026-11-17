import QodeNotchCore
import SwiftUI

struct SessionCardView: View {
    var session: ClaudeSession
    var index: Int?
    var isSelected: Bool

    @EnvironmentObject private var store: SessionStore
    @State private var hovering = false
    @State private var reply = ""
    @State private var confirmCleanup = false

    private var s: ClaudeSession { session }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            metaRow
            previewBlock
            if s.awaitingPermission && s.canSendInput {
                approvalRow
            } else if s.status == .waiting && s.isDesktop {
                PillButton(title: "In Claude Desktop beantworten", symbol: "arrow.up.forward.app", color: SessionStatus.waiting.color) { store.focus(s) }
            }
            if isSelected {
                actionRow
                if s.canSendInput && s.status != .working {
                    HStack(spacing: 6) {
                        NotchTextField(placeholder: "Antwort an Claude …", text: $reply) { sendReply() }
                        IconButton(symbol: "paperplane.fill", help: "Senden", tint: SessionStatus.working.color) { sendReply() }
                    }
                }
                if confirmCleanup { cleanupConfirmation }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(isSelected ? 0.09 : (hovering ? 0.06 : 0.035)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(s.status == .waiting ? SessionStatus.waiting.color.opacity(0.55) : Color.primary.opacity(isSelected ? 0.14 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.openDetail(s.id) }
        .onTapGesture { store.selectedId = s.id }
        .contextMenu { contextMenu }
        .opacity(s.status == .finished ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: Rows

    private var titleRow: some View {
        HStack(spacing: 6) {
            if let index, index <= 9 {
                Text("\(index)")
                    .scaledFont(size: 9, weight: .bold, design: .monospaced)
                    .frame(width: 14, height: 14)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            StatusOrb(status: s.status, size: 8)
            Text(s.repoName)
                .scaledFont(size: 12, weight: .bold)
                .lineLimit(1)
                .layoutPriority(1)
            if let name = s.sessionLabel {
                Text("·").scaledFont(size: 12).foregroundStyle(Color.primary.opacity(0.35))
                Text(name)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(name)
            }
            if s.taskSummary?.source == .linear, let ticket = s.taskSummary?.ticketId {
                Chip(text: ticket, symbol: "ticket", color: .indigo)
            }
            Spacer(minLength: 4)
            StatusPill(status: s.status)
            Text(s.lastActivity.relative).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.4))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 5) {
            if let branch = s.branch {
                Chip(text: branch, symbol: "arrow.triangle.branch")
            }
            if s.isWorktree { Chip(text: "Worktree", symbol: "square.stack.3d.up", color: .teal, help: "Läuft in einem separaten Git-Worktree") }
            if s.isContainerized {
                Chip(text: s.isAirlock ? "airlock" : "Container", symbol: "shippingbox", color: .cyan,
                     help: s.isAirlock ? "Claude läuft isoliert in einem airlock-Container (Podman)" : "Claude läuft in einem Container")
            }
            if s.isDesktop { Chip(text: "Claude Desktop", symbol: "macwindow", color: .purple, help: "Session aus dem Code-Tab von Claude Desktop") }
            if let git = s.git { GitStatsView(git: git) }
            if let url = s.prUrl { PrBadge(url: url, status: store.prStatuses[url]) }
            Spacer(minLength: 0)
            if s.orphaned { Chip(text: s.tmuxSession != nil ? "tmux getrennt" : "verwaist", symbol: "link.badge.plus", color: .orange) }
            if let term = s.terminalName { Text(term).scaledFont(size: 9).foregroundStyle(Color.primary.opacity(0.3)).lineLimit(1) }
        }
    }

    @ViewBuilder
    private var previewBlock: some View {
        if s.status == .waiting, let tool = s.preview.lastTools.first {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver").scaledFont(size: 9)
                    Text(tool.name).scaledFont(size: 10, weight: .bold)
                    if let d = tool.description, d != tool.input { Text(d).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1) }
                }
                .foregroundStyle(SessionStatus.waiting.color)
                if let input = tool.input {
                    Text(input)
                        .scaledFont(size: 10.5, design: .monospaced)
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(isSelected ? 6 : 2)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                ForEach(tool.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(size: 9.5, weight: .medium)
                        .foregroundStyle(.orange)
                }
            }
        } else if let text = s.preview.assistantIsNewer ? s.preview.lastAssistantText : s.preview.lastUserMessage {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: s.preview.assistantIsNewer ? "sparkle" : "person.fill")
                    .scaledFont(size: 9)
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .padding(.top, 2)
                Text(text)
                    .scaledFont(size: 11)
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineLimit(isSelected ? 4 : 2)
            }
            if s.status == .working, let tool = s.preview.lastTools.last {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
                    Text(tool.name).scaledFont(size: 10, weight: .semibold)
                    if let input = tool.input { Text(input).scaledFont(size: 10, design: .monospaced).lineLimit(1).truncationMode(.middle) }
                }
                .foregroundStyle(SessionStatus.working.color.opacity(0.9))
            }
        } else if let d = s.taskSummary?.description, isSelected {
            Text(d).scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(3)
        }
    }

    private var approvalRow: some View {
        HStack(spacing: 6) {
            PillButton(title: "Erlauben", symbol: "checkmark", color: .green) { store.approve(s) }
            PillButton(title: "Immer erlauben", symbol: "checkmark.seal", color: .green, filled: false) { store.alwaysAllow(s) }
            PillButton(title: "Ablehnen", symbol: "xmark", color: .red, filled: false) { store.reject(s) }
            Spacer()
            IconButton(symbol: "macwindow", help: "Zum Terminal", shortcut: "↩") { store.focus(s) }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            if s.pid != nil {
                IconButton(symbol: "macwindow", help: s.isDesktop ? "In Claude Desktop öffnen" : "Zum Terminal", shortcut: "↩") { store.focus(s) }
            }
            if store.config.editorOption != nil {
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Im Editor öffnen", shortcut: "E") { store.openEditor(s) }
            }
            if store.config.gitGuiOption != nil {
                IconButton(symbol: "arrow.triangle.branch", help: "Im Git-Client öffnen", shortcut: "G") { store.openGitGui(s) }
            }
            IconButton(symbol: "folder", help: "Im Finder zeigen", shortcut: "F") { store.openFinder(s) }
            if let _ = s.prUrl {
                IconButton(symbol: "arrow.up.right.square", help: "Pull Request öffnen", shortcut: "P", tint: .green) { store.openPR(s) }
            } else if s.canSendInput && s.status == .idle {
                IconButton(symbol: "arrow.triangle.pull", help: "Pull Request erstellen lassen", shortcut: "P") { store.createPR(s) }
            }
            if s.orphaned && s.tmuxSession != nil {
                IconButton(symbol: "link", help: "tmux-Session wieder anhängen", tint: .orange) { store.reattach(s) }
            }
            Spacer()
            if s.status == .finished {
                IconButton(symbol: "xmark", help: "Ausblenden") { store.dismissFinished(s) }
            }
            if s.isWorktree {
                IconButton(symbol: "trash", help: "Worktree aufräumen", tint: .red) { confirmCleanup = true }
            }
            IconButton(symbol: "chevron.right", help: "Details", shortcut: "D") { store.openDetail(s.id) }
        }
    }

    private var cleanupConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worktree aufräumen?").scaledFont(size: 11, weight: .bold)
            Text("Beendet die Session, entfernt \(Paths.abbreviateHome(s.workingDirectory)) (auch ungespeicherte Änderungen) und löscht den lokalen Branch \(s.branch ?? "").")
                .scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.6))
            HStack {
                PillButton(title: "Endgültig aufräumen", symbol: "trash", color: .red) {
                    confirmCleanup = false
                    store.cleanup(s)
                }
                PillButton(title: "Abbrechen", color: Color.primary, filled: false) { confirmCleanup = false }
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Zum Terminal") { store.focus(s) }.disabled(s.pid == nil)
        Button("Details") { store.openDetail(s.id) }
        Divider()
        Button("Im Editor öffnen") { store.openEditor(s) }
        Button("Im Git-Client öffnen") { store.openGitGui(s) }
        Button("Im Finder zeigen") { store.openFinder(s) }
        if s.prUrl != nil { Button("Pull Request öffnen") { store.openPR(s) } }
        Divider()
        Button("Pfad kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s.workingDirectory, forType: .string)
        }
        if s.pid != nil {
            Divider()
            Button("Session beenden", role: .destructive) { store.kill(s) }
        }
        if s.isWorktree {
            Button("Worktree aufräumen …", role: .destructive) {
                store.selectedId = s.id
                confirmCleanup = true
            }
        }
    }

    private func sendReply() {
        store.send(s, message: reply)
        reply = ""
    }
}
