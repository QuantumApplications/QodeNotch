import Foundation

/// High-level state of a Claude Code session.
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case working
    case waiting
    case idle
    case errored
    case finished

    public var label: String {
        switch self {
        case .working: return "Arbeitet"
        case .waiting: return "Wartet"
        case .idle: return "Bereit"
        case .errored: return "Fehler"
        case .finished: return "Beendet"
        }
    }

    /// Sort priority: sessions needing attention first.
    public var priority: Int {
        switch self {
        case .waiting: return 0
        case .errored: return 1
        case .working: return 2
        case .idle: return 3
        case .finished: return 4
        }
    }
}

public struct GitSummary: Codable, Equatable, Sendable {
    public var branch: String
    public var changedFiles: Int
    public var additions: Int
    public var deletions: Int
    public var untrackedFiles: Int
    public var shortStat: String

    public init(branch: String, changedFiles: Int, additions: Int, deletions: Int, untrackedFiles: Int, shortStat: String) {
        self.branch = branch
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
        self.untrackedFiles = untrackedFiles
        self.shortStat = shortStat
    }

    public var isClean: Bool { changedFiles == 0 && untrackedFiles == 0 }
}

public struct ToolInfo: Codable, Equatable, Sendable, Hashable {
    public var name: String
    public var input: String?
    public var description: String?
    public var warnings: [String]

    public init(name: String, input: String?, description: String?, warnings: [String]) {
        self.name = name
        self.input = input
        self.description = description
        self.warnings = warnings
    }
}

public struct ConversationPreview: Codable, Equatable, Sendable {
    public var lastUserMessage: String?
    public var lastAssistantText: String?
    /// Whether the assistant text came after the last user message.
    public var assistantIsNewer: Bool
    public var lastTools: [ToolInfo]
    public var messageCount: Int

    public init(lastUserMessage: String? = nil, lastAssistantText: String? = nil, assistantIsNewer: Bool = false, lastTools: [ToolInfo] = [], messageCount: Int = 0) {
        self.lastUserMessage = lastUserMessage
        self.lastAssistantText = lastAssistantText
        self.assistantIsNewer = assistantIsNewer
        self.lastTools = lastTools
        self.messageCount = messageCount
    }

    public static let empty = ConversationPreview()
}

public struct TaskSummary: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case linear, prompt, user }

    public var title: String
    public var description: String?
    public var source: Source
    public var ticketId: String?
    public var ticketUrl: String?

    public init(title: String, description: String?, source: Source, ticketId: String? = nil, ticketUrl: String? = nil) {
        self.title = title
        self.description = description
        self.source = source
        self.ticketId = ticketId
        self.ticketUrl = ticketUrl
    }
}

public struct TmuxPaneInfo: Codable, Equatable, Sendable {
    public var tty: String
    public var paneId: String
    public var sessionName: String
    public var windowIndex: Int
    public var paneIndex: Int
    public var target: String { "\(sessionName):\(windowIndex).\(paneIndex)" }

    public init(tty: String, paneId: String, sessionName: String, windowIndex: Int, paneIndex: Int) {
        self.tty = tty
        self.paneId = paneId
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
    }
}

public struct ClaudeSession: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var pid: Int32?
    public var workingDirectory: String
    public var repoName: String
    public var parentRepo: String?
    public var isWorktree: Bool
    public var branch: String?
    public var status: SessionStatus
    public var lastActivity: Date
    public var startedAt: Date?
    public var git: GitSummary?
    public var preview: ConversationPreview
    public var taskSummary: TaskSummary?
    public var hasPendingToolUse: Bool
    public var jsonlPath: String?
    public var prUrl: String?
    public var orphaned: Bool
    public var tmuxSession: String?
    public var cpuPercent: Double
    public var terminalName: String?
    /// Set when Claude runs in a container (e.g. airlock); `pid` is then the host-side runtime client.
    public var containerName: String?
    public var containerRuntime: String?

    public var isContainerized: Bool { containerRuntime != nil }
    public var isAirlock: Bool { containerName?.hasPrefix("airlock-") ?? false }

    public init(
        id: String, pid: Int32?, workingDirectory: String, repoName: String, parentRepo: String? = nil,
        isWorktree: Bool = false, branch: String? = nil, status: SessionStatus, lastActivity: Date = Date(),
        startedAt: Date? = nil, git: GitSummary? = nil, preview: ConversationPreview = .empty,
        taskSummary: TaskSummary? = nil, hasPendingToolUse: Bool = false, jsonlPath: String? = nil,
        prUrl: String? = nil, orphaned: Bool = false, tmuxSession: String? = nil, cpuPercent: Double = 0,
        terminalName: String? = nil, containerName: String? = nil, containerRuntime: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.repoName = repoName
        self.parentRepo = parentRepo
        self.isWorktree = isWorktree
        self.branch = branch
        self.status = status
        self.lastActivity = lastActivity
        self.startedAt = startedAt
        self.git = git
        self.preview = preview
        self.taskSummary = taskSummary
        self.hasPendingToolUse = hasPendingToolUse
        self.jsonlPath = jsonlPath
        self.prUrl = prUrl
        self.orphaned = orphaned
        self.tmuxSession = tmuxSession
        self.cpuPercent = cpuPercent
        self.terminalName = terminalName
        self.containerName = containerName
        self.containerRuntime = containerRuntime
    }

    /// Title shown in the UI: task title, else repo name.
    public var displayTitle: String {
        if let t = taskSummary?.title, !t.isEmpty { return t }
        return repoName
    }

    /// Repository path used for grouping (main repo for worktrees).
    public var groupPath: String { parentRepo ?? workingDirectory }
}

public enum PrChecks: String, Codable, Sendable { case passing, failing, pending, none }

public struct PrStatus: Codable, Equatable, Sendable {
    public var url: String
    public var state: String            // OPEN | MERGED | CLOSED
    public var checks: PrChecks
    public var reviewDecision: String?  // APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED
    public var mergeable: String        // MERGEABLE | CONFLICTING | UNKNOWN
    public var mergeStateStatus: String
    public var checksTotal: Int
    public var checksPassing: Int
    public var checksFailing: Int
    public var checksPending: Int
    public var unresolvedThreads: Int
    public var commentCount: Int

    public init(url: String, state: String, checks: PrChecks, reviewDecision: String?, mergeable: String,
                mergeStateStatus: String, checksTotal: Int = 0, checksPassing: Int = 0, checksFailing: Int = 0,
                checksPending: Int = 0, unresolvedThreads: Int = 0, commentCount: Int = 0) {
        self.url = url
        self.state = state
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.checksTotal = checksTotal
        self.checksPassing = checksPassing
        self.checksFailing = checksFailing
        self.checksPending = checksPending
        self.unresolvedThreads = unresolvedThreads
        self.commentCount = commentCount
    }

    public var number: String? {
        url.split(separator: "/").last.map(String.init)
    }
}

public struct ConversationMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public struct ToolUse: Equatable, Sendable, Hashable {
        public var name: String
        public var summary: String?
    }

    public var id: Int
    public var role: Role
    public var timestamp: Date?
    public var text: String?
    public var toolUses: [ToolUse]
}

public struct SessionGroup: Identifiable, Equatable, Sendable {
    public var repoName: String
    public var repoPath: String
    public var sessions: [ClaudeSession]
    public var id: String { repoPath }
}

public enum SessionGrouping {
    /// Group sessions by main repo; larger groups first, then alphabetical.
    public static func group(_ sessions: [ClaudeSession]) -> [SessionGroup] {
        var order: [String] = []
        var map: [String: SessionGroup] = [:]
        for s in sessions {
            let path = s.groupPath
            if map[path] == nil {
                order.append(path)
                map[path] = SessionGroup(repoName: Paths.repoName(from: path), repoPath: path, sessions: [])
            }
            map[path]!.sessions.append(s)
        }
        return order.compactMap { map[$0] }.sorted {
            if $0.sessions.count != $1.sessions.count { return $0.sessions.count > $1.sessions.count }
            return $0.repoName.localizedCaseInsensitiveCompare($1.repoName) == .orderedAscending
        }
    }

    public static func flatten(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        group(sessions).flatMap(\.sessions)
    }

    /// A session is stale when nothing happened for longer than the threshold.
    public static func isStale(_ session: ClaudeSession, thresholdMinutes: Int, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(session.lastActivity)
        if elapsed < 0 { return false }
        return elapsed > Double(thresholdMinutes) * 60
    }
}
