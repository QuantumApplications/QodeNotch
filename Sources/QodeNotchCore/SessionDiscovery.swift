import Foundation

/// Finds running Claude Code sessions and builds their full state.
/// All state is recomputed from the process table, hook events and transcripts.
public actor SessionDiscovery {
    public init() {}

    private var lastOrphanCheck = Date.distantPast
    private var orphaned: Set<Int32> = []
    private var tmuxSessionByPid: [Int32: String] = [:]
    private var terminalNameByPid: [Int32: String] = [:]

    /// Slow per-session data (git, PR) cached between polls.
    private struct SlowCache {
        var git: GitSummary?
        var mainWorktree: String?
        var prUrl: String?
        var forge: PullRequestService.Forge?
        var at: Date
    }
    private var slowCache: [String: SlowCache] = [:]
    private let slowTTL: TimeInterval = 5

    /// Recently finished sessions (kept for display until the user dismisses them).
    private var finished: [String: ClaudeSession] = [:]

    public func discover(includeFinished: Bool = false) async -> [ClaudeSession] {
        async let treeT = ProcessScanner.buildTree()
        let hooks = HookManager.readAll()
        let meta = SessionMetaStore.load()
        let tree = await treeT
        let containers = await ProcessScanner.containerClients(in: tree)
        var pidSet = Set(ProcessScanner.claudePids(in: tree)).union(containers.keys)
        // CLIs whose process isn't called "claude" (e.g. started by Claude Desktop's
        // Code tab) still report through the hook: trust live PIDs from recent events.
        for (pid, ev) in hooks.byPid where tree[pid] != nil && ev.event != "SessionEnd"
            && Date().timeIntervalSince(ev.timestamp) < 12 * 3600 {
            pidSet.insert(pid)
        }
        let pids = pidSet.sorted()
        let cwds = await ProcessScanner.workingDirectories(for: pids)
        let alive = Set(pids)

        if Date().timeIntervalSince(lastOrphanCheck) > 30 || pids.contains(where: { terminalNameByPid[$0] == nil }) {
            await refreshTerminalInfo(pids: pids, tree: tree)
        }

        // Resolve the hook event for every process: by PID for native Claude,
        // by working directory for Claude inside a container.
        var hookFor: [Int32: HookEvent] = [:]
        for pid in pids {
            if containers[pid] != nil {
                if let cwd = cwds[pid], let ev = hooks.containerEvent(cwd: cwd) { hookFor[pid] = ev }
            } else if let ev = hooks.byPid[pid] {
                hookFor[pid] = ev
            }
        }

        // Transcripts already claimed by hook events must not be reused by the mtime fallback.
        var claimed = Set<String>()
        for ev in hookFor.values {
            if let t = ev.transcriptPath { claimed.insert(HookManager.hostTranscriptPath(t)) }
        }

        var sessions: [ClaudeSession] = []
        await withTaskGroup(of: ClaudeSession?.self) { group in
            for pid in pids {
                guard let cwd = cwds[pid] ?? hookFor[pid]?.cwd else { continue }
                let entry = tree[pid]
                let hook = hookFor[pid]
                let container = containers[pid]
                let claimedCopy = claimed
                group.addTask {
                    await self.build(pid: pid, cwd: cwd, cpu: entry?.cpuPercent ?? 0, hook: hook, container: container, claimed: claimedCopy)
                }
            }
            for await s in group { if let s { sessions.append(s) } }
        }

        // Two processes may resolve to the same transcript via the fallback; keep ids unique.
        var seen = Set<String>()
        sessions = sessions.sorted { ($0.pid ?? 0) < ($1.pid ?? 0) }.map { s in
            var s = s
            if !seen.insert(s.id).inserted { s.id = "pid-\(s.pid ?? 0)" }
            return s
        }

        SessionMetaStore.apply(meta, to: &sessions)

        // Track sessions that disappeared so they can be shown as finished.
        let currentIds = Set(sessions.map(\.id))
        for (id, var s) in previous where !currentIds.contains(id) && s.status != .finished {
            s.status = .finished
            s.pid = nil
            finished[id] = s
        }
        for id in currentIds { finished.removeValue(forKey: id) }
        finished = finished.filter { Date().timeIntervalSince($0.value.lastActivity) < 24 * 3600 }
        previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        HookManager.pruneDead(alive: alive)
        return includeFinished ? sessions + finished.values.sorted { $0.lastActivity > $1.lastActivity } : sessions
    }

    private var previous: [String: ClaudeSession] = [:]

    public func dismissFinished(id: String) {
        finished.removeValue(forKey: id)
    }

    public func clearFinished() {
        finished.removeAll()
    }

    private func refreshTerminalInfo(pids: [Int32], tree: ProcessTree) async {
        lastOrphanCheck = Date()
        async let ttysT = ProcessScanner.ttys(for: pids)
        async let panesT = TerminalDetector.tmuxPanes()
        async let clientsT = TerminalDetector.tmuxClients()
        let (ttys, panes, clients) = await (ttysT, panesT, clientsT)
        let attached = Set(clients.map(\.sessionName))
        var newOrphaned = Set<Int32>()
        var newTmux: [Int32: String] = [:]
        var names: [Int32: String] = [:]
        for pid in pids {
            let pane = ttys[pid].flatMap { panes[$0] }
            if TerminalDetector.isOrphaned(pid: pid, tree: tree, inTmux: pane != nil, tmuxHasClient: pane.map { attached.contains($0.sessionName) } ?? false) {
                newOrphaned.insert(pid)
            }
            if let pane {
                newTmux[pid] = pane.sessionName
                let client = clients.first { $0.sessionName == pane.sessionName }
                let r = client.map { TerminalDetector.resolve(from: $0.pid, in: tree) } ?? (.unknown, nil)
                let name = r.app == .ide ? (r.host?.name ?? "IDE") : r.app.displayName
                names[pid] = r.app == .unknown ? "tmux" : "\(name) · tmux"
            } else {
                let r = TerminalDetector.resolve(from: pid, in: tree)
                names[pid] = r.app == .unknown ? "" : (r.app == .ide ? (r.host?.name ?? "IDE") : r.app.displayName)
            }
        }
        orphaned = newOrphaned
        tmuxSessionByPid = newTmux
        terminalNameByPid = names
    }

    private func slowData(cwd: String, branchHint: String?) async -> SlowCache {
        if let c = slowCache[cwd], Date().timeIntervalSince(c.at) < slowTTL { return c }
        async let gitT = GitInfo.summary(cwd: cwd)
        async let mainT = GitInfo.mainWorktree(cwd: cwd)
        let (git, main) = await (gitT, mainT)
        var pr: String?
        let forge: PullRequestService.Forge? = git == nil ? nil : await PullRequestService.shared.forge(cwd: cwd)
        if let branch = git?.branch ?? branchHint, !["main", "master", "HEAD", "develop", "trunk"].contains(branch) {
            pr = await PullRequestService.shared.prUrl(cwd: cwd, branch: branch)
        }
        let c = SlowCache(git: git, mainWorktree: main, prUrl: pr, forge: forge, at: Date())
        slowCache[cwd] = c
        return c
    }

    private func build(pid: Int32, cwd: String, cpu: Double, hook: HookEvent?, container: ProcessScanner.ContainerClient?,
                       claimed: Set<String>) async -> ClaudeSession? {
        let transcript = hook?.transcriptPath.map(HookManager.hostTranscriptPath)
            ?? TranscriptReader.latestTranscript(in: Paths.projectDir(for: cwd), excluding: claimed)

        var tail: [TranscriptLine] = []
        var head: [TranscriptLine] = []
        var mtime: Date?
        if let t = transcript {
            tail = TranscriptReader.readTail(t)
            head = TranscriptReader.readHead(t)
            mtime = TranscriptReader.mtime(t)
        }

        let slow = await slowData(cwd: cwd, branchHint: TranscriptReader.branch(tail))
        let pending = TranscriptReader.hasPendingToolUse(tail)
        let asking = TranscriptReader.isAskingForInput(tail)
        let hasError = TranscriptReader.lastMessageHasError(tail)

        // For containers the host process is only the podman/docker client; Claude's
        // CPU usage is invisible, so approximate activity from transcript writes.
        var effectiveCpu = cpu
        if container != nil {
            let age = mtime.map { Date().timeIntervalSince($0) } ?? .infinity
            effectiveCpu = age < 5 ? 10 : 0
        }

        let status = StatusClassifier.classify(.init(
            pidAlive: true, transcriptMtime: mtime, cpuPercent: effectiveCpu, hasError: hasError, isAskingForInput: asking,
            hasPendingToolUse: pending, hookStatus: hook?.impliedStatus, hookTimestamp: hook?.timestamp))

        let lastActivity = [mtime, hook?.timestamp].compactMap { $0 }.max() ?? Date()
        let recentActivity = Date().timeIntervalSince(lastActivity) < 60
        let isWorktree = slow.mainWorktree != nil && slow.mainWorktree != cwd
        let allLines = head + tail
        let terminal: String? = hook?.desktopSessionId != nil ? "Claude Desktop" : terminalNameByPid[pid].flatMap { $0.isEmpty ? nil : $0 }

        var session = ClaudeSession(
            id: hook?.sessionId ?? TranscriptReader.sessionId(tail) ?? "pid-\(pid)",
            pid: pid,
            workingDirectory: cwd,
            repoName: Paths.repoName(from: cwd),
            parentRepo: isWorktree ? slow.mainWorktree : nil,
            isWorktree: isWorktree,
            branch: slow.git?.branch ?? TranscriptReader.branch(tail),
            status: status,
            lastActivity: lastActivity,
            startedAt: TranscriptReader.startedAt(head),
            git: slow.git,
            preview: TranscriptReader.preview(tail),
            taskSummary: TranscriptReader.taskSummary(head),
            hasPendingToolUse: pending,
            jsonlPath: transcript,
            prUrl: slow.prUrl,
            orphaned: recentActivity ? false : orphaned.contains(pid),
            tmuxSession: tmuxSessionByPid[pid],
            cpuPercent: cpu,
            terminalName: terminal,
            containerName: container?.containerName,
            containerRuntime: container?.runtime
        )
        session.sessionName = TranscriptReader.sessionName(allLines)
        session.model = TranscriptReader.model(tail) ?? TranscriptReader.model(head)
        session.desktopSessionId = hook?.desktopSessionId
        session.lastHookAt = hook?.timestamp
        session.forge = slow.forge?.rawValue
        session.awaitingPermission = StatusClassifier.awaitsPermission(status: status, hookStatus: hook?.impliedStatus, hasPendingToolUse: pending)
        // Claude Desktop sessions have no terminal: "orphaned" doesn't apply.
        if session.isDesktop { session.orphaned = false }
        return session
    }

    /// Force git/PR data to refresh on the next poll.
    public func invalidateSlowCache(cwd: String? = nil) async {
        if let cwd { slowCache.removeValue(forKey: cwd) } else { slowCache.removeAll() }
        await PullRequestService.shared.invalidate()
    }
}
