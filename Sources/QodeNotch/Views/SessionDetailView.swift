import QodeNotchCore
import SwiftUI

struct SessionDetailView: View {
    var session: ClaudeSession

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout
    @State private var conversation: [ConversationMessage] = []
    @State private var diffStat: String?
    @State private var reply = ""
    @State private var editing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var tab: Tab = .conversation

    enum Tab: String, CaseIterable { case conversation = "Verlauf", changes = "Änderungen", info = "Info" }

    private var s: ClaudeSession { session }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if editing { editor }
            if s.status == .waiting { approvalBox }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Group {
                switch tab {
                case .conversation: conversationView
                case .changes: changesView
                case .info: infoView
                }
            }

            if s.pid != nil {
                HStack(spacing: 6) {
                    NotchTextField(placeholder: s.status == .working ? "Nachricht (wird nach der Arbeit gelesen) …" : "Antwort an Claude …", text: $reply) { sendReply() }
                    IconButton(symbol: "paperplane.fill", help: "Senden", tint: SessionStatus.working.color) { sendReply() }
                }
            }
        }
        .task(id: s.jsonlPath.map { $0 + "\(s.lastActivity.timeIntervalSince1970)" } ?? s.id) {
            conversation = await store.loadConversation(s)
            diffStat = await store.loadDiffStat(s)
        }
    }

    private var maxBodyHeight: CGFloat {
        CGFloat(store.config.maxExpandedHeight) - max(layout.geometry.notchHeight, 28) - 190
    }

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Zurück", shortcut: "←") { store.route = .list }
            StatusOrb(status: s.status, size: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(Paths.abbreviateHome(s.workingDirectory)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            StatusPill(status: s.status)
            IconButton(symbol: "pencil", help: "Titel bearbeiten") {
                editTitle = s.taskSummary?.source == .user ? (s.taskSummary?.title ?? "") : ""
                editDescription = s.taskSummary?.description ?? ""
                editing.toggle()
            }
            if s.pid != nil { IconButton(symbol: "macwindow", help: "Zum Terminal", shortcut: "↩") { store.focus(s) } }
            if store.config.editorOption != nil {
                IconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Editor", shortcut: "E") { store.openEditor(s) }
            }
            if store.config.gitGuiOption != nil {
                IconButton(symbol: "arrow.triangle.branch", help: "Git-Client", shortcut: "G") { store.openGitGui(s) }
            }
            IconButton(symbol: "folder", help: "Finder", shortcut: "F") { store.openFinder(s) }
            if s.prUrl != nil {
                IconButton(symbol: "arrow.up.right.square", help: "PR öffnen", shortcut: "P", tint: .green) { store.openPR(s) }
            } else if s.pid != nil {
                IconButton(symbol: "arrow.triangle.pull", help: "PR erstellen lassen", shortcut: "P") { store.createPR(s) }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchTextField(placeholder: "Eigener Titel (leer = automatisch)", text: $editTitle)
            NotchTextField(placeholder: "Beschreibung", text: $editDescription)
            HStack {
                PillButton(title: "Speichern", symbol: "checkmark", color: SessionStatus.working.color) {
                    store.rename(s, title: editTitle, description: editDescription)
                    editing = false
                }
                PillButton(title: "Abbrechen", color: .white, filled: false) { editing = false }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var approvalBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(s.preview.lastTools.enumerated()), id: \.offset) { _, tool in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.name).font(.system(size: 11, weight: .bold)).foregroundStyle(SessionStatus.waiting.color)
                    if let input = tool.input {
                        Text(input).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(10)
                    }
                    ForEach(tool.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            HStack(spacing: 6) {
                PillButton(title: "Erlauben", symbol: "checkmark", color: .green) { store.approve(s) }
                PillButton(title: "Immer erlauben", symbol: "checkmark.seal", color: .green, filled: false) { store.alwaysAllow(s) }
                PillButton(title: "Ablehnen", symbol: "xmark", color: .red, filled: false) { store.reject(s) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SessionStatus.waiting.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            FittingScrollView(maxHeight: maxBodyHeight) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if conversation.isEmpty {
                        Text("Kein Verlauf gefunden.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                    ForEach(conversation.suffix(150)) { m in
                        MessageBubble(message: m).id(m.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: conversation.count) { _, _ in
                if let last = conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = conversation.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var changesView: some View {
        FittingScrollView(maxHeight: maxBodyHeight) {
            VStack(alignment: .leading, spacing: 6) {
                if let git = s.git {
                    HStack {
                        Chip(text: git.branch, symbol: "arrow.triangle.branch")
                        GitStatsView(git: git)
                        if git.untrackedFiles > 0 { Text("\(git.untrackedFiles) neu").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)) }
                    }
                }
                Text(diffStat ?? "Keine Änderungen gegenüber HEAD.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var infoView: some View {
        VStack(alignment: .leading, spacing: 4) {
            info("Pfad", Paths.abbreviateHome(s.workingDirectory))
            if let p = s.parentRepo { info("Haupt-Repo", Paths.abbreviateHome(p)) }
            if let b = s.branch { info("Branch", b) }
            info("Session-ID", s.id)
            if let pid = s.pid {
                info("PID", s.isContainerized ? "\(pid) (\(Paths.repoName(from: s.containerRuntime ?? "podman"))-Client)" : "\(pid) · CPU \(String(format: "%.0f", s.cpuPercent)) %")
            }
            if let t = s.terminalName { info("Terminal", t) }
            if let t = s.tmuxSession { info("tmux", t) }
            if let c = s.containerName { info("Container", c) }
            if let start = s.startedAt { info("Gestartet", start.formatted(date: .abbreviated, time: .shortened)) }
            info("Letzte Aktivität", s.lastActivity.formatted(date: .omitted, time: .standard))
            info("Nachrichten", "\(s.preview.messageCount)")
            if let ticket = s.taskSummary?.ticketUrl {
                Button { store.openURL(ticket) } label: { info("Ticket", s.taskSummary?.ticketId ?? ticket) }.buttonStyle(.plain)
            }
            if let url = s.prUrl, let pr = store.prStatuses[url] {
                info("Pull Request", "#\(pr.number ?? "") · \(pr.state) · Checks \(pr.checksPassing)/\(pr.checksTotal)" + (pr.reviewDecision.map { " · \($0)" } ?? ""))
            }
            HStack {
                if s.pid != nil {
                    PillButton(title: "Session beenden", symbol: "stop.fill", color: .red, filled: false) { store.kill(s) }
                }
            }
            .padding(.top, 4)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 100, alignment: .leading)
            Text(value).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.8)).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func sendReply() {
        store.send(s, message: reply)
        reply = ""
    }
}

private struct MessageBubble: View {
    var message: ConversationMessage

    var body: some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                if let text = message.text {
                    Text(markdown(text))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(isUser ? 0.95 : 0.8))
                        .textSelection(.enabled)
                        .lineLimit(isUser ? 8 : 24)
                }
                ForEach(Array(message.toolUses.enumerated()), id: \.offset) { _, tool in
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver").font(.system(size: 8))
                        Text(tool.name).font(.system(size: 9.5, weight: .bold))
                        if let summary = tool.summary {
                            Text(summary).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(7)
            .background(isUser ? SessionStatus.working.color.opacity(0.22) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
