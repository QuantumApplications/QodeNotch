import Foundation

public enum StatusClassifier {
    /// Transcript writes newer than this count as "recent activity".
    public static let workingThreshold: TimeInterval = 10
    /// A pending tool_use older than this means a permission prompt is open.
    public static let approvalSettle: TimeInterval = 3

    public struct Input: Sendable {
        public var pidAlive: Bool
        public var transcriptMtime: Date?
        public var cpuPercent: Double
        public var hasError: Bool
        public var isAskingForInput: Bool
        public var hasPendingToolUse: Bool
        public var hookStatus: SessionStatus?
        public var hookTimestamp: Date?

        public init(pidAlive: Bool = true, transcriptMtime: Date? = nil, cpuPercent: Double = 0, hasError: Bool = false,
                    isAskingForInput: Bool = false, hasPendingToolUse: Bool = false, hookStatus: SessionStatus? = nil,
                    hookTimestamp: Date? = nil) {
            self.pidAlive = pidAlive
            self.transcriptMtime = transcriptMtime
            self.cpuPercent = cpuPercent
            self.hasError = hasError
            self.isAskingForInput = isAskingForInput
            self.hasPendingToolUse = hasPendingToolUse
            self.hookStatus = hookStatus
            self.hookTimestamp = hookTimestamp
        }
    }

    /// Heuristic classifier used when no hook data is available.
    public static func heuristic(_ i: Input, now: Date = Date()) -> SessionStatus {
        if !i.pidAlive { return .finished }
        if i.hasError { return .errored }
        let age = i.transcriptMtime.map { now.timeIntervalSince($0) } ?? .infinity
        let recentWrite = age < workingThreshold
        if (recentWrite && i.cpuPercent > 5) || i.cpuPercent > 15 { return .working }
        if i.hasPendingToolUse { return age > approvalSettle ? .waiting : .working }
        if i.isAskingForInput { return .waiting }
        return .idle
    }

    /// Combine hook status (authoritative) with transcript/CPU signals.
    ///
    /// With hooks, "waiting" only ever comes from Claude Code's own permission
    /// notification. Earlier heuristics ("tool pending + quiet transcript",
    /// "last answer sounds like a question") misfired on long-running tools –
    /// above all in containers, where Claude's CPU is invisible – and on normal
    /// answers ending in "Soll ich …?".
    public static func classify(_ i: Input, now: Date = Date()) -> SessionStatus {
        guard i.pidAlive else { return .finished }
        guard let hook = i.hookStatus else { return heuristic(i, now: now) }

        switch hook {
        case .waiting:
            // Approved in the terminal and Claude is busy again before the next hook arrived.
            if i.cpuPercent > 15 { return .working }
            // Transcript moved on after the permission prompt → the tool ran.
            if let m = i.transcriptMtime, let h = i.hookTimestamp, m.timeIntervalSince(h) > 1, !i.hasPendingToolUse { return .working }
            return .waiting
        case .working:
            return .working
        case .idle:
            return i.hasError ? .errored : .idle
        case .finished:
            return .finished
        case .errored:
            return .errored
        }
    }

    /// Whether approve/deny applies: a real permission prompt is open.
    public static func awaitsPermission(status: SessionStatus, hookStatus: SessionStatus?, hasPendingToolUse: Bool) -> Bool {
        guard status == .waiting else { return false }
        if hookStatus != nil { return hookStatus == .waiting }
        return hasPendingToolUse
    }
}
