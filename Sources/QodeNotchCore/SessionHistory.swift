import Foundation

/// A past (or running) Claude Code session found in `~/.claude/projects`.
public struct PastSession: Identifiable, Equatable, Sendable {
    public var id: String              // session id used for resuming
    public var agent: Agent = .claude
    public var transcriptPath: String
    public var workingDirectory: String?
    public var title: String
    public var summary: String?
    public var branch: String?
    public var lastActivity: Date
    public var startedAt: Date?

    public var repoName: String { workingDirectory.map(Paths.repoName(from:)) ?? "?" }

    public var directoryExists: Bool {
        guard let dir = workingDirectory else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Lists all sessions stored by Claude Code. Parsed results are cached per
/// transcript (path + mtime), so repeated scans only touch changed files.
public actor SessionHistory {
    public static let shared = SessionHistory()

    private var cache: [String: (mtime: Date, session: PastSession?)] = [:]

    public init() {}

    public func list(limit: Int = 300) -> [PastSession] {
        let fm = FileManager.default
        var files: [(path: String, mtime: Date, agent: Agent)] = []
        for project in (try? fm.contentsOfDirectory(atPath: Paths.claudeProjectsDir)) ?? [] where !project.hasPrefix(".") {
            let dir = Paths.claudeProjectsDir + "/" + project
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".jsonl") {
                let p = dir + "/" + e
                if let m = TranscriptReader.mtime(p) { files.append((p, m, .claude)) }
            }
        }
        for p in AgentStores.codexRollouts(days: 60) {
            if let m = TranscriptReader.mtime(p) { files.append((p, m, .codex)) }
        }
        for p in AgentStores.copilotEventFiles() {
            if let m = TranscriptReader.mtime(p) { files.append((p, m, .copilot)) }
        }
        files.sort { $0.mtime > $1.mtime }

        var result: [PastSession] = []
        var seenIds = Set<String>()
        for f in files {
            if result.count >= limit { break }
            let session: PastSession?
            if let c = cache[f.path], c.mtime == f.mtime {
                session = c.session
            } else {
                session = Self.parse(path: f.path, mtime: f.mtime, agent: f.agent)
                cache[f.path] = (f.mtime, session)
            }
            if let s = session, seenIds.insert(s.agent.rawValue + s.id).inserted { result.append(s) }
        }
        return result
    }

    /// Build a summary from the head (+ a little tail) of a transcript. Returns nil
    /// for transcripts without any real user prompt (e.g. aborted starts).
    static func parse(path: String, mtime: Date, agent: Agent = .claude) -> PastSession? {
        let head = TranscriptReader.readHead(path, lines: 40)
        let tail = TranscriptReader.readTail(path, lines: 15)
        let all = head + tail
        guard let task = TranscriptReader.taskSummary(head) ?? TranscriptReader.taskSummary(tail) else { return nil }
        let url = URL(fileURLWithPath: path)
        let fileId: String
        switch agent {
        case .claude: fileId = url.deletingPathExtension().lastPathComponent
        case .codex: fileId = TranscriptReader.sessionId(head) ?? String(url.deletingPathExtension().lastPathComponent.suffix(36))
        case .copilot: fileId = url.deletingLastPathComponent().lastPathComponent
        }
        let cwd = all.lazy.compactMap(\.cwd).first { !$0.isEmpty }
        // A `summary` line (written on compaction/resume) is a better title than the first prompt.
        let fileSessionId = agent == .claude ? url.deletingPathExtension().lastPathComponent : nil
        let titleSource = agent == .claude ? (FileManager.default.contents(atPath: path).map(TranscriptReader.titleLines(in:)) ?? all) : all
        let summaryLine = TranscriptReader.sessionName(titleSource, sessionId: fileSessionId)
        return PastSession(
            id: fileId,
            agent: agent,
            transcriptPath: path,
            workingDirectory: cwd,
            title: summaryLine ?? task.title,
            summary: summaryLine != nil ? task.title : task.description,
            branch: TranscriptReader.branch(all),
            lastActivity: mtime,
            startedAt: TranscriptReader.startedAt(head)
        )
    }

    /// Case-insensitive search over title, summary, path and branch.
    public static func filter(_ sessions: [PastSession], query: String) -> [PastSession] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sessions }
        let terms = q.lowercased().split(separator: " ").map(String.init)
        return sessions.filter { s in
            let hay = [s.title, s.summary ?? "", s.workingDirectory ?? "", s.branch ?? "", s.id].joined(separator: " ").lowercased()
            return terms.allSatisfy(hay.contains)
        }
    }
}

public enum SessionResumer {
    /// True when airlock (github.com/sundance2000/airlock) is installed.
    public static var isAirlockInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.home + "/.local/share/airlock/image/Containerfile")
            || FileManager.default.isExecutableFile(atPath: Paths.home + "/.local/bin/airlock")
    }

    public static func effectiveStrategy(_ s: ResumeStrategy) -> ResumeStrategy {
        s == .auto ? (isAirlockInstalled ? .airlock : .resume) : s
    }

    /// Session ids are UUIDs; anything else is refused to keep the shell command safe.
    public static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// The command run inside the session's directory.
    public static func command(for session: PastSession, config: AppConfig) -> String? {
        let base = config.command(for: session.agent)
        switch session.agent {
        case .codex:
            guard isValidSessionId(session.id) else { return nil }
            return "\(base) resume \(session.id)"
        case .copilot:
            guard isValidSessionId(session.id) else { return nil }
            return "\(base) --resume \(session.id)"
        case .claude:
            break
        }
        switch effectiveStrategy(config.resumeStrategy) {
        case .airlock:
            // airlock resumes the folder's last session on its own; extra
            // arguments would make it recreate the container.
            return base
        case .resume, .auto:
            guard isValidSessionId(session.id) else { return nil }
            return "\(base) --resume \(session.id)"
        }
    }

    /// Open a terminal in the session's directory and resume it.
    public static func resume(_ session: PastSession, config: AppConfig) async throws {
        guard let dir = session.workingDirectory, session.directoryExists else {
            throw ActionError.message("Das Verzeichnis der Session existiert nicht mehr.")
        }
        guard let cmd = command(for: session, config: config) else {
            throw ActionError.message("Ungültige Session-ID.")
        }
        var tmuxName: String?
        if config.terminalUseTmux && config.terminalTmuxMode == .perProject {
            tmuxName = Paths.repoName(from: dir)
        }
        try await TerminalController.createSession(.init(
            terminal: config.terminalApp, openIn: config.terminalOpenIn, useTmux: config.terminalUseTmux,
            tmuxSession: tmuxName, cwd: dir, prompt: nil, initialCommand: cmd))
    }
}
