import AppKit
import QodeNotchCore
import SwiftUI

struct NewSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout

    @State private var repos: [RepoInfo] = []
    @State private var filter = ""
    @State private var repoPath = ""
    @State private var useWorktree = false
    @State private var branch = ""
    @State private var baseBranch = ""
    @State private var branches: [String] = []
    @State private var prompt = ""
    @State private var tmuxSessions: [TerminalDetector.TmuxSessionInfo] = []
    @State private var tmuxChoice = ""
    @State private var creating = false

    private var filteredRepos: [RepoInfo] {
        filter.isEmpty ? repos : repos.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconButton(symbol: "chevron.left", help: "Zurück") { store.route = .list }
                Text("Neue Claude-Session").font(.system(size: 13, weight: .bold))
                Spacer()
            }

            // Repository
            section("Repository") {
                HStack(spacing: 6) {
                    NotchTextField(placeholder: repos.isEmpty ? "Pfad zum Repository" : "Suchen oder Pfad eingeben …", text: $filter) {
                        if let first = filteredRepos.first { pick(first.path) } else if !filter.isEmpty { pick(Paths.expandTilde(filter)) }
                    }
                    IconButton(symbol: "folder.badge.plus", help: "Ordner wählen …") { chooseFolder() }
                }
                if !repoPath.isEmpty {
                    Label(Paths.abbreviateHome(repoPath), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                }
                if !filteredRepos.isEmpty && (repoPath.isEmpty || !filter.isEmpty) {
                    FittingScrollView(maxHeight: 120) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredRepos.prefix(60)) { repo in
                                Button { pick(repo.path) } label: {
                                    HStack {
                                        Image(systemName: "folder").font(.system(size: 10))
                                        Text(repo.name).font(.system(size: 11, weight: .medium))
                                        Text(Paths.abbreviateHome(repo.path)).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                    }
                                    .padding(.vertical, 3)
                                    .padding(.horizontal, 6)
                                    .background(repo.path == repoPath ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else if repos.isEmpty && store.config.codeDirectories.isEmpty {
                    Text("Tipp: Code-Verzeichnisse in den Einstellungen hinterlegen, um Repos hier aufzulisten.")
                        .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.4))
                }
            }

            // Worktree
            section("Branch") {
                Toggle(isOn: $useWorktree) {
                    Text("In neuem Git-Worktree arbeiten").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                if useWorktree {
                    HStack(spacing: 6) {
                        NotchTextField(placeholder: "Neuer Branch, z. B. feat/login", text: $branch)
                        Picker("von", selection: $baseBranch) {
                            ForEach(branches.isEmpty ? [store.config.defaultBaseBranch] : branches, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .controlSize(.small)
                    }
                    if !branch.isEmpty && !SessionActions.isValidBranchName(branch) {
                        Text("Ungültiger Branch-Name").font(.system(size: 10)).foregroundStyle(.red)
                    } else if !branch.isEmpty && !repoPath.isEmpty {
                        Text("→ \(Paths.abbreviateHome(SessionActions.worktreePath(repo: repoPath, branch: branch)))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.4))
                    }
                }
            }

            // tmux
            if store.config.terminalUseTmux && store.config.terminalTmuxMode == .choose {
                section("tmux-Session") {
                    Picker("", selection: $tmuxChoice) {
                        Text("Neue Session").tag("")
                        ForEach(tmuxSessions) { t in Text("\(t.name) (\(t.windows) Fenster)").tag(t.name) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            // Prompt
            section("Erster Prompt (optional)") {
                TextEditor(text: $prompt)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 64)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }

            HStack {
                Text("\(store.config.terminalApp.displayName) · \(store.config.terminalOpenIn == .tab ? "neuer Tab" : "neues Fenster")\(store.config.terminalUseTmux ? " · tmux" : "")")
                    .font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.4))
                Spacer()
                PillButton(title: creating ? "Starte …" : "Session starten", symbol: "play.fill", color: SessionStatus.working.color) { create() }
                    .disabled(!canCreate || creating)
                    .opacity(canCreate ? 1 : 0.5)
            }
        }
        .onAppear(perform: load)
        .onChange(of: useWorktree) { _, on in
            if on && prompt.isEmpty { prompt = store.config.initialPrompt }
            if !on && prompt == store.config.initialPrompt { prompt = "" }
        }
        .onDisappear { layout.isEditing = false }
    }

    private var canCreate: Bool {
        !repoPath.isEmpty && (!useWorktree || SessionActions.isValidBranchName(branch))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.primary.opacity(0.4))
            content()
        }
    }

    private func load() {
        layout.isEditing = true // keep the notch open while filling the form
        let dirs = store.config.codeDirectories
        Task.detached {
            let found = SessionActions.scanRepos(in: dirs)
            await MainActor.run { repos = found }
        }
        Task { tmuxSessions = await TerminalDetector.tmuxSessions() }
        if repoPath.isEmpty, let current = store.selectedSession {
            pick(current.parentRepo ?? current.workingDirectory, clearFilter: true)
        }
    }

    private func pick(_ path: String, clearFilter: Bool = true) {
        repoPath = path
        if clearFilter { filter = "" }
        Task {
            let list = await GitInfo.localBranches(repo: path)
            branches = list
            let def = store.config.defaultBaseBranch
            baseBranch = list.contains(def) ? def : (list.first ?? def)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { pick(url.path) }
    }

    private func create() {
        creating = true
        let req = SessionActions.NewSessionRequest(
            repoPath: repoPath,
            branchName: useWorktree ? branch : nil,
            baseBranch: useWorktree ? baseBranch : nil,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt,
            tmuxSession: tmuxChoice.isEmpty ? nil : tmuxChoice)
        Task {
            _ = await store.createSession(req)
            creating = false
            layout.isEditing = false
        }
    }
}
