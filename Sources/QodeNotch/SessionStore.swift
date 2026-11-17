import AppKit
import Combine
import QodeNotchCore
import SwiftUI

/// Where the expanded notch is currently navigated to.
enum NotchRoute: Equatable {
    case list
    case detail(String)
    case newSession
    case history
    case usage
}

/// Central app state: polls sessions, tracks UI state, performs actions.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    // Data
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var prStatuses: [String: PrStatus] = [:]
    @Published private(set) var hookState: HookManager.InstallState = .notInstalled
    @Published private(set) var codexHookState: HookManager.InstallState = .notInstalled
    @Published private(set) var copilotHookState: HookManager.InstallState = .notInstalled
    @Published private(set) var history: [PastSession] = []
    @Published private(set) var isLoadingHistory = false
    @Published var config: AppConfig = .load() {
        didSet {
            guard config != oldValue else { return }
            try? config.save()
            configDidChange.send(config)
            if config.showLimits && !oldValue.showLimits { refreshLimits(force: true) }
            if config.enableCodex != oldValue.enableCodex || config.enableCopilot != oldValue.enableCopilot {
                applyAgentIntegrations()
            }
            if config.forge != oldValue.forge {
                let forge = config.forge
                Task { await PullRequestService.shared.setPreference(forge) }
            }
        }
    }
    let configDidChange = PassthroughSubject<AppConfig, Never>()

    // UI state
    @Published var isExpanded = false
    @Published var route: NotchRoute = .list
    @Published var selectedId: String?
    @Published var isPinned = false
    @Published var toast: Toast?
    @Published var isPanelKey = false
    /// Sessions acted on recently: shown optimistically until hooks catch up.
    @Published private var actedOn: [String: (status: SessionStatus, at: Date)] = [:]

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var isError: Bool
    }

    private let discovery = SessionDiscovery()
    private var pollTask: Task<Void, Never>?
    private var prTask: Task<Void, Never>?
    private var usageTask: Task<Void, Never>?
    private var previousStatus: [String: SessionStatus] = [:]
    private var isFirstPoll = true

    /// Raised when a session newly needs attention (used to auto-expand the notch).
    let attentionRequested = PassthroughSubject<String, Never>()

    // MARK: Lifecycle

    func start() {
        hookState = HookManager.install()
        applyAgentIntegrations()
        let forge = config.forge
        Task { await PullRequestService.shared.setPreference(forge) }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        usageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                self?.refreshLimits()
                self?.refreshUsage()
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        }
        prTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                await self?.refreshPrStatuses()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func reinstallHooks() {
        hookState = HookManager.install()
        applyAgentIntegrations()
    }

    /// Install or remove Codex / Copilot hooks according to the settings.
    func applyAgentIntegrations() {
        if config.enableCodex { codexHookState = AgentHooks.installCodex() } else { AgentHooks.uninstallCodex(); codexHookState = .notInstalled }
        if config.enableCopilot { copilotHookState = AgentHooks.installCopilot() } else { AgentHooks.uninstallCopilot(); copilotHookState = .notInstalled }
    }

    func uninstallHooks() {
        do {
            try HookManager.uninstall()
            AgentHooks.uninstallCodex()
            AgentHooks.uninstallCopilot()
            hookState = HookManager.state()
            codexHookState = .notInstalled
            copilotHookState = .notInstalled
            showToast("Hooks entfernt")
        } catch {
            showToast(error.localizedDescription, error: true)
        }
    }

    private func poll() async {
        var found = await discovery.discover(includeFinished: config.showFinishedSessions)
        let now = Date()
        // After approve/deny the permission hook stays the newest event until the
        // tool finishes (can take minutes). Keep the optimistic state until a newer
        // hook event arrives; without hooks fall back to a short grace period.
        actedOn = actedOn.filter { now.timeIntervalSince($0.value.at) < 15 * 60 }
        for i in found.indices {
            guard let acted = actedOn[found[i].id] else { continue }
            let newerHook = found[i].lastHookAt.map { $0 > acted.at } ?? false
            let expired = found[i].lastHookAt == nil && now.timeIntervalSince(acted.at) > 4
            if newerHook || expired || found[i].status != .waiting {
                actedOn.removeValue(forKey: found[i].id)
            } else {
                found[i].status = acted.status
                found[i].awaitingPermission = false
            }
        }
        found.sort { lhs, rhs in
            if lhs.status.priority != rhs.status.priority { return lhs.status.priority < rhs.status.priority }
            return lhs.lastActivity > rhs.lastActivity
        }
        if config.groupByRepo { found = SessionGrouping.flatten(found) }

        detectTransitions(found)
        if found != sessions { sessions = found }
        if let sel = selectedId, !sessions.contains(where: { $0.id == sel }) { selectedId = sessions.first?.id }
        if case let .detail(id) = route, !sessions.contains(where: { $0.id == id }) { route = .list }
        isFirstPoll = false
    }

    private func detectTransitions(_ found: [ClaudeSession]) {
        defer { previousStatus = Dictionary(found.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a }) }
        guard !isFirstPoll else { return }
        for s in found {
            let old = previousStatus[s.id]
            guard old != s.status, let old else { continue }
            switch s.status {
            case .waiting:
                Notifier.shared.notify(session: s, kind: .waiting, config: config, suppress: isExpanded && !config.alwaysNotify)
                attentionRequested.send(s.id)
            case .idle where old == .working:
                refreshLimits()
                Notifier.shared.notify(session: s, kind: .finished, config: config, suppress: isExpanded && !config.alwaysNotify)
            case .errored:
                Notifier.shared.notify(session: s, kind: .errored, config: config, suppress: isExpanded && !config.alwaysNotify)
            default:
                break
            }
        }
    }

    private func refreshPrStatuses() async {
        let targets = sessions.compactMap { s in s.prUrl.map { ($0, s.workingDirectory) } }
        var result: [String: PrStatus] = [:]
        await withTaskGroup(of: (String, PrStatus?).self) { group in
            for (url, cwd) in targets {
                group.addTask { (url, await PullRequestService.shared.status(url: url, cwd: cwd)) }
            }
            for await (url, status) in group { if let status { result[url] = status } }
        }
        if result != prStatuses { prStatuses = result }
    }

    func refreshNow() {
        Task {
            await discovery.invalidateSlowCache()
            await poll()
            await refreshPrStatuses()
        }
    }

    // MARK: Derived

    var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    var liveSessions: [ClaudeSession] { sessions.filter { $0.status != .finished } }

    /// Most urgent status across all sessions (drives the collapsed indicator).
    var aggregateStatus: SessionStatus? {
        sessions.filter { $0.status != .finished }.min { $0.status.priority < $1.status.priority }?.status
    }

    func session(_ id: String?) -> ClaudeSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    var selectedSession: ClaudeSession? { session(selectedId) ?? sessions.first }

    var firstWaiting: ClaudeSession? { sessions.first { $0.status == .waiting } }

    // MARK: Selection & navigation

    func select(index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedId = sessions[index].id
    }

    func cycleSelection(forward: Bool) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedId } ?? (forward ? -1 : 0)
        let next = (current + (forward ? 1 : -1) + sessions.count) % sessions.count
        selectedId = sessions[next].id
    }

    func openDetail(_ id: String) {
        selectedId = id
        route = .detail(id)
    }

    // MARK: Actions

    private func perform(_ label: String?, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                if let label { showToast(label) }
            } catch {
                showToast(error.localizedDescription, error: true)
            }
        }
    }

    func showToast(_ text: String, error: Bool = false) {
        let t = Toast(text: text, isError: error)
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == t { toast = nil }
        }
    }

    func approve(_ s: ClaudeSession) {
        actedOn[s.id] = (.working, Date())
        applyOptimistic(s.id, .working)
        perform("Freigegeben") { try await SessionActions.approve(s) }
    }

    func reject(_ s: ClaudeSession) {
        actedOn[s.id] = (.idle, Date())
        applyOptimistic(s.id, .idle)
        perform("Abgelehnt") { try await SessionActions.reject(s) }
    }

    func alwaysAllow(_ s: ClaudeSession) {
        actedOn[s.id] = (.working, Date())
        applyOptimistic(s.id, .working)
        perform("Immer erlaubt") { try await SessionActions.alwaysAllow(s) }
    }

    private func applyOptimistic(_ id: String, _ status: SessionStatus) {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].status = status
            sessions[i].awaitingPermission = false
        }
    }

    func focus(_ s: ClaudeSession) {
        perform(nil) { try await SessionActions.focus(s) }
    }

    func send(_ s: ClaudeSession, message: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actedOn[s.id] = (.working, Date())
        perform("Gesendet") { try await SessionActions.sendMessage(s, text) }
    }

    func createPR(_ s: ClaudeSession) {
        if let url = s.prUrl {
            openURL(url)
            return
        }
        let prompt = s.isGitLab ? config.createMrPrompt : s.isForgejo ? config.createForgejoPrompt : config.createPrPrompt
        send(s, message: prompt.isEmpty ? "/create-pr" : prompt)
    }

    func openEditor(_ s: ClaudeSession) {
        let cfg = config
        perform(nil) { try await SessionActions.openInEditor(path: s.workingDirectory, config: cfg) }
    }

    func openGitGui(_ s: ClaudeSession) {
        let cfg = config
        perform(nil) { try await SessionActions.openInGitGui(path: s.workingDirectory, config: cfg) }
    }

    func openFinder(_ s: ClaudeSession) {
        perform(nil) { try await SessionActions.openInFinder(path: s.workingDirectory) }
    }

    func openURL(_ url: String) {
        let cfg = config
        perform(nil) { try await SessionActions.openURL(url, config: cfg) }
    }

    func openPR(_ s: ClaudeSession) {
        guard let url = s.prUrl else { return }
        openURL(url)
    }

    func kill(_ s: ClaudeSession) {
        perform("Session beendet") { await SessionActions.kill(s) }
    }

    func cleanup(_ s: ClaudeSession) {
        let cfg = config
        perform("Worktree aufgeräumt") { [weak self] in
            try await SessionActions.cleanupWorktree(s, config: cfg)
            await self?.discovery.dismissFinished(id: s.id)
        }
    }

    func dismissFinished(_ s: ClaudeSession) {
        Task {
            await discovery.dismissFinished(id: s.id)
            await poll()
        }
    }

    func reattach(_ s: ClaudeSession) {
        guard let tmux = s.tmuxSession else { return }
        let cfg = config
        perform("tmux-Session geöffnet") {
            try await TerminalController.reattach(tmuxSession: tmux, terminal: cfg.terminalApp, openIn: cfg.terminalOpenIn, cwd: s.workingDirectory)
        }
    }

    func rename(_ s: ClaudeSession, title: String, description: String) {
        do {
            try SessionMetaStore.save(sessionId: s.id, title: title, description: description)
            Task { await poll() }
        } catch {
            showToast(error.localizedDescription, error: true)
        }
    }

    func createSession(_ req: SessionActions.NewSessionRequest) async -> Bool {
        do {
            let path = try await SessionActions.createSession(req, config: config)
            showToast("Session gestartet in \(Paths.abbreviateHome(path))")
            route = .list
            return true
        } catch {
            showToast(error.localizedDescription, error: true)
            return false
        }
    }

    // MARK: Session history

    func loadHistory() {
        isLoadingHistory = history.isEmpty
        Task {
            let list = await SessionHistory.shared.list()
            history = list
            isLoadingHistory = false
        }
    }

    /// The running session that corresponds to a past one, if any.
    func liveSession(for past: PastSession) -> ClaudeSession? {
        if let s = liveSessions.first(where: { $0.id == past.id }) { return s }
        // airlock allows one container per folder: a running one there *is* that session.
        if let dir = past.workingDirectory, SessionResumer.effectiveStrategy(config.resumeStrategy) == .airlock {
            return liveSessions.first { $0.workingDirectory == dir && $0.isContainerized }
        }
        return nil
    }

    /// Reopen a past session (or jump to it if it is still running).
    func resume(_ past: PastSession) {
        if let live = liveSession(for: past) {
            focus(live)
            return
        }
        let cfg = config
        let how = SessionResumer.effectiveStrategy(cfg.resumeStrategy) == .airlock ? "mit airlock geöffnet" : "wird fortgesetzt"
        perform("\(past.repoName) \(how)") { try await SessionResumer.resume(past, config: cfg) }
    }

    // MARK: Detail data

    struct SessionTranscript {
        var conversation: [ConversationMessage] = []
        var usage = TokenUsage()
        var usageByModel: [String: TokenUsage] = [:]
    }

    func loadTranscript(_ s: ClaudeSession) async -> SessionTranscript {
        guard let path = s.jsonlPath else { return SessionTranscript() }
        return await Task.detached(priority: .userInitiated) {
            let lines = TranscriptReader.readAll(path)
            let totals = TranscriptReader.usageTotals(lines)
            return SessionTranscript(conversation: TranscriptReader.conversation(lines), usage: totals.total, usageByModel: totals.byModel)
        }.value
    }

    // MARK: Limits & usage

    @Published private(set) var limits: UsageLimits?
    @Published private(set) var limitsError: String?
    @Published private(set) var usageReport: UsageReport?
    private var lastLimitsFetch = Date.distantPast
    private var limitsInFlight = false

    /// Plan limits: fetched at most every 2 minutes (when asked), else every 10.
    func refreshLimits(force: Bool = false) {
        guard config.showLimits, !limitsInFlight else { return }
        let minInterval: TimeInterval = force ? 30 : 120
        guard Date().timeIntervalSince(lastLimitsFetch) > minInterval else { return }
        limitsInFlight = true
        lastLimitsFetch = Date()
        Task {
            do {
                limits = try await UsageLimitsClient.fetch()
                limitsError = nil
            } catch {
                limitsError = error.localizedDescription
            }
            limitsInFlight = false
        }
    }

    @Published private(set) var codexLimits: UsageLimits?

    func refreshUsage() {
        Task {
            usageReport = await LocalUsageScanner.shared.report()
            codexLimits = await Task.detached { AgentStores.codexLimits() }.value
        }
    }

    func loadDiffStat(_ s: ClaudeSession) async -> String? {
        await GitInfo.diffStat(cwd: s.workingDirectory)
    }
}
