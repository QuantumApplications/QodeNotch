import Foundation

public struct RepoInfo: Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var id: String { path }
}

public enum ActionError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case let .message(m) = self { return m }
        return nil
    }
}

/// Everything the user can do with a session: quick links, worktrees, new sessions, cleanup.
public enum SessionActions {

    // MARK: Quick links

    public static func openInEditor(path: String, config: AppConfig) async throws {
        guard let editor = config.editorOption else { throw ActionError.message("Kein Editor konfiguriert.") }
        if Shell.which(editor.command) != nil {
            try await Shell.runChecked(editor.command, [path], timeout: 10)
            return
        }
        // No CLI launcher installed: open the app bundle, trying known variants (e.g. PyCharm CE).
        var lastError = ""
        for app in [editor.appName] + editor.alternateAppNames {
            let r = await Shell.run("/usr/bin/open", ["-a", app, path], timeout: 10)
            if r.ok { return }
            lastError = r.stderr
        }
        throw ActionError.message("\(editor.label) konnte nicht geöffnet werden. " + lastError.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func openInGitGui(path: String, config: AppConfig) async throws {
        guard let gui = config.gitGuiOption else { throw ActionError.message("Kein Git-Client konfiguriert.") }
        try await Shell.runChecked("/usr/bin/open", ["-a", gui.appName, path], timeout: 10)
    }

    public static func openInFinder(path: String) async throws {
        try await Shell.runChecked("/usr/bin/open", [path], timeout: 10)
    }

    public static func openURL(_ url: String, config: AppConfig) async throws {
        if let b = config.browserOption {
            try await Shell.runChecked("/usr/bin/open", ["-a", b.appName, url], timeout: 10)
        } else {
            try await Shell.runChecked("/usr/bin/open", [url], timeout: 10)
        }
    }

    // MARK: Terminal interaction

    public static func terminal(for session: ClaudeSession) async throws -> TerminalInfo {
        guard session.desktopSessionId == nil else { throw ActionError.message("Diese Session läuft in Claude Desktop – bitte dort beantworten.") }
        guard let pid = session.pid else { throw TerminalError.noProcess }
        return await TerminalDetector.detect(pid: pid)
    }

    public static func focus(_ session: ClaudeSession) async throws {
        if let desktop = session.desktopSessionId {
            try await openInClaudeDesktop(hostSessionId: desktop)
            return
        }
        try await TerminalController.focus(try await terminal(for: session))
    }

    /// Claude Desktop's own link to one Code-tab session (`local_<uuid>`).
    public static func claudeDesktopURL(hostSessionId: String) -> String? {
        guard hostSessionId.hasPrefix("local_"),
              hostSessionId.range(of: "^local_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
        return "claude://code/continue?session=\(hostSessionId)"
    }

    public static func openInClaudeDesktop(hostSessionId: String?) async throws {
        if let id = hostSessionId, let url = claudeDesktopURL(hostSessionId: id) {
            try await Shell.runChecked("/usr/bin/open", [url], timeout: 10)
        } else {
            try await Shell.runChecked("/usr/bin/open", ["-a", "Claude"], timeout: 10)
        }
    }

    /// Web sessions live on claude.ai; there is no public API to list them.
    public static let claudeWebCodeURL = "https://claude.ai/code"

    public static func approve(_ session: ClaudeSession) async throws {
        try await TerminalController.sendKeystroke(try await terminal(for: session), .enter)
    }

    public static func reject(_ session: ClaudeSession) async throws {
        try await TerminalController.sendKeystroke(try await terminal(for: session), .escape)
    }

    /// Pick option N in a Claude Code selection prompt (1 = yes, 2 = always, 3 = no).
    public static func choose(_ session: ClaudeSession, option: Int) async throws {
        try await TerminalController.sendKeystroke(try await terminal(for: session), .text(String(option)))
    }

    public static func sendMessage(_ session: ClaudeSession, _ text: String) async throws {
        try await TerminalController.sendText(try await terminal(for: session), text)
    }

    public static func kill(_ session: ClaudeSession) async {
        if let runtime = session.containerRuntime, let name = session.containerName {
            // Stopping the container ends Claude inside it; the attached client then exits.
            _ = await Shell.run(runtime, ["stop", "-t", "5", name], timeout: 20)
            return
        }
        guard let pid = session.pid else { return }
        await ProcessScanner.terminateClaude(pid)
    }

    // MARK: Repositories

    /// Git repos inside the configured code directories (up to two levels deep).
    public static func scanRepos(in directories: [String]) -> [RepoInfo] {
        var repos: [RepoInfo] = []
        var seen = Set<String>()
        let fm = FileManager.default
        func visit(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for e in entries.sorted() where !e.hasPrefix(".") {
                let path = dir + "/" + e
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if GitInfo.isRepo(path) {
                    // Skip linked worktrees (.git is a file) to keep the list to main repos.
                    var gitIsDir: ObjCBool = false
                    _ = fm.fileExists(atPath: path + "/.git", isDirectory: &gitIsDir)
                    if gitIsDir.boolValue, seen.insert(path).inserted { repos.append(RepoInfo(name: e, path: path)) }
                } else if depth < 2 {
                    visit(path, depth: depth + 1)
                }
            }
        }
        for d in directories {
            let dir = Paths.expandTilde(d)
            if GitInfo.isRepo(dir), seen.insert(dir).inserted { repos.append(RepoInfo(name: Paths.repoName(from: dir), path: dir)) }
            visit(dir, depth: 1)
        }
        return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Worktrees

    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else { return false }
        return !name.contains("..") && !name.hasPrefix("/") && !name.hasSuffix("/") && !name.hasPrefix("-") && !name.hasSuffix(".lock")
    }

    /// Worktrees live next to the repo: `<parent>/<repo>-<branch>`.
    public static func worktreePath(repo: String, branch: String) -> String {
        let url = URL(fileURLWithPath: repo)
        let parent = url.deletingLastPathComponent().path
        return parent + "/" + url.lastPathComponent + "-" + branch.replacingOccurrences(of: "/", with: "-")
    }

    public static func createWorktree(repo: String, branch: String, base: String?) async throws -> String {
        guard isValidBranchName(branch) else { throw ActionError.message("Ungültiger Branch-Name.") }
        let path = worktreePath(repo: repo, branch: branch)
        if FileManager.default.fileExists(atPath: path) { return path }
        var args = ["-C", repo, "worktree", "add", path, "-b", branch]
        if let base, !base.isEmpty { args.append(base) }
        let r = await Shell.run("git", args, timeout: 30)
        if r.ok { return path }
        // Branch exists already → check it out in the worktree.
        let r2 = await Shell.run("git", ["-C", repo, "worktree", "add", path, branch], timeout: 30)
        guard r2.ok else {
            throw ActionError.message("Worktree konnte nicht erstellt werden: " + (r2.stderr.isEmpty ? r.stderr : r2.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return path
    }

    public struct NewSessionRequest: Sendable {
        public var repoPath: String
        public var branchName: String?
        public var baseBranch: String?
        public var prompt: String?
        public var tmuxSession: String?

        public init(repoPath: String, branchName: String? = nil, baseBranch: String? = nil, prompt: String? = nil, tmuxSession: String? = nil) {
            self.repoPath = repoPath
            self.branchName = branchName
            self.baseBranch = baseBranch
            self.prompt = prompt
            self.tmuxSession = tmuxSession
        }
    }

    /// Create (optionally) a worktree and open a terminal running claude in it.
    @discardableResult
    public static func createSession(_ req: NewSessionRequest, config: AppConfig) async throws -> String {
        let repo = Paths.expandTilde(req.repoPath)
        guard FileManager.default.fileExists(atPath: repo) else { throw ActionError.message("Repository existiert nicht: \(repo)") }
        var target = repo
        if let b = req.branchName?.trimmingCharacters(in: .whitespaces), !b.isEmpty {
            target = try await createWorktree(repo: repo, branch: b, base: req.baseBranch)
        }
        var tmuxName: String?
        if config.terminalUseTmux {
            if let t = req.tmuxSession, !t.isEmpty { tmuxName = t }
            else if config.terminalTmuxMode == .perProject { tmuxName = Paths.repoName(from: repo) }
        }
        try await TerminalController.createSession(.init(
            terminal: config.terminalApp, openIn: config.terminalOpenIn, useTmux: config.terminalUseTmux,
            tmuxSession: tmuxName, cwd: target, prompt: req.prompt, initialCommand: config.initialCommand))
        return target
    }

    /// Find the main repo for a worktree, even if the worktree folder is gone.
    static func mainRepo(forWorktree dir: String) async -> String? {
        if FileManager.default.fileExists(atPath: dir), let main = await GitInfo.mainWorktree(cwd: dir) { return main }
        let url = URL(fileURLWithPath: dir)
        let name = url.lastPathComponent
        // `<repo>-<branch>`: both parts may contain dashes, so try every split point.
        for dash in name.indices.reversed() where name[dash] == "-" {
            let candidate = url.deletingLastPathComponent().path + "/" + name[..<dash]
            if GitInfo.isRepo(candidate) { return candidate }
        }
        return nil
    }

    /// Kill the session, remove its worktree and delete its local branch.
    public static func cleanupWorktree(_ session: ClaudeSession, config: AppConfig) async throws {
        let dir = session.workingDirectory
        let terminalInfo: TerminalInfo? = (config.cleanupCloseTabs && session.pid != nil) ? try? await terminal(for: session) : nil
        let branch = await GitInfo.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: dir)

        await kill(session)

        guard let main = await mainRepo(forWorktree: dir) else { throw ActionError.message("Haupt-Repository nicht gefunden.") }
        guard URL(fileURLWithPath: main).standardized.path != URL(fileURLWithPath: dir).standardized.path else {
            throw ActionError.message("Das Haupt-Repository kann nicht aufgeräumt werden – nur Worktrees.")
        }
        let r = await Shell.run("git", ["-C", main, "worktree", "remove", dir, "--force"], timeout: 20)
        if !r.ok && FileManager.default.fileExists(atPath: dir) {
            throw ActionError.message("Worktree konnte nicht entfernt werden: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = await Shell.run("git", ["-C", main, "worktree", "prune"], timeout: 10)
        if !branch.isEmpty, branch != "HEAD" {
            _ = await Shell.run("git", ["-C", main, "branch", "-D", branch], timeout: 10)
        }

        if config.cleanupCloseTabs {
            if let t = terminalInfo { try? await TerminalController.close(t) }
            if let gui = config.gitGuiOption { await closeGitGuiTab(appName: gui.appName, folder: Paths.repoName(from: dir)) }
            if let url = session.prUrl, let browser = config.browserOption { await closeBrowserTab(appName: browser.appName, url: url) }
        }
    }

    static let chromiumBrowsers: Set<String> = ["Google Chrome", "Arc", "Dia", "Brave Browser", "Microsoft Edge"]

    static func closeBrowserTab(appName: String, url: String) async {
        guard chromiumBrowsers.contains(appName) else { return }
        _ = try? await AppleScript.run("""
        tell application "\(AppleScript.escape(appName))"
          set found to false
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              if URL of aTab starts with "\(AppleScript.escape(url))" then
                close aTab
                set found to true
                exit repeat
              end if
            end repeat
            if found then exit repeat
          end repeat
        end tell
        """)
    }

    static func closeGitGuiTab(appName: String, folder: String) async {
        _ = try? await AppleScript.run("""
        tell application "System Events"
          tell process "\(AppleScript.escape(appName))"
            repeat with aWindow in windows
              if name of aWindow is "\(AppleScript.escape(folder))" then
                click (first button of aWindow whose description is "close button")
                exit repeat
              end if
            end repeat
          end tell
        end tell
        """)
    }
}
