import XCTest
@testable import QodeNotchCore

final class StatusClassifierTests: XCTestCase {
    let now = Date()

    func testDeadProcessIsFinished() {
        XCTAssertEqual(StatusClassifier.classify(.init(pidAlive: false, hookStatus: .working), now: now), .finished)
    }

    func testHeuristicWorkingOnCpu() {
        XCTAssertEqual(StatusClassifier.heuristic(.init(cpuPercent: 30), now: now), .working)
        XCTAssertEqual(StatusClassifier.heuristic(.init(transcriptMtime: now.addingTimeInterval(-2), cpuPercent: 8), now: now), .working)
    }

    func testHeuristicPendingToolSettles() {
        XCTAssertEqual(StatusClassifier.heuristic(.init(transcriptMtime: now.addingTimeInterval(-1), hasPendingToolUse: true), now: now), .working)
        XCTAssertEqual(StatusClassifier.heuristic(.init(transcriptMtime: now.addingTimeInterval(-10), hasPendingToolUse: true), now: now), .waiting)
    }

    func testHeuristicIdleAndAsking() {
        XCTAssertEqual(StatusClassifier.heuristic(.init(transcriptMtime: now.addingTimeInterval(-100)), now: now), .idle)
        XCTAssertEqual(StatusClassifier.heuristic(.init(isAskingForInput: true), now: now), .waiting)
        XCTAssertEqual(StatusClassifier.heuristic(.init(hasError: true), now: now), .errored)
    }

    func testHookWaitingTurnsWorkingOnCpu() {
        XCTAssertEqual(StatusClassifier.classify(.init(cpuPercent: 40, hookStatus: .waiting), now: now), .working)
        XCTAssertEqual(StatusClassifier.classify(.init(cpuPercent: 1, hasPendingToolUse: true, hookStatus: .waiting, hookTimestamp: now), now: now), .waiting)
    }

    func testHookWorkingStaysWorkingDuringLongTools() {
        // A long Bash run: pending tool_use, quiet transcript, no CPU (e.g. airlock).
        let old = now.addingTimeInterval(-120)
        XCTAssertEqual(StatusClassifier.classify(.init(transcriptMtime: old, cpuPercent: 0, hasPendingToolUse: true, hookStatus: .working, hookTimestamp: old), now: now), .working)
    }

    func testAwaitsPermission() {
        XCTAssertTrue(StatusClassifier.awaitsPermission(status: .waiting, hookStatus: .waiting, hasPendingToolUse: true))
        XCTAssertFalse(StatusClassifier.awaitsPermission(status: .idle, hookStatus: .idle, hasPendingToolUse: false))
        XCTAssertFalse(StatusClassifier.awaitsPermission(status: .waiting, hookStatus: nil, hasPendingToolUse: false))
        XCTAssertTrue(StatusClassifier.awaitsPermission(status: .waiting, hookStatus: nil, hasPendingToolUse: true))
    }

    func testHookIdle() {
        XCTAssertEqual(StatusClassifier.classify(.init(hookStatus: .idle), now: now), .idle)
        // A closing "Soll ich …?" is not a permission prompt.
        XCTAssertEqual(StatusClassifier.classify(.init(isAskingForInput: true, hookStatus: .idle), now: now), .idle)
    }
}

final class HookTests: XCTestCase {
    func testParseEventFile() {
        let json = #"{"pid":4242,"ts":1700000000,"payload":{"hook_event_name":"Notification","session_id":"s1","cwd":"/x","transcript_path":"/t.jsonl","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}}"#
        let ev = HookManager.parseEventFile(Data(json.utf8), fallbackPid: nil)
        XCTAssertEqual(ev?.pid, 4242)
        XCTAssertEqual(ev?.sessionId, "s1")
        XCTAssertEqual(ev?.transcriptPath, "/t.jsonl")
        XCTAssertEqual(ev?.impliedStatus, .waiting)
        XCTAssertEqual(ev?.timestamp, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLegacyFlatFormatAndFallbackPid() {
        let json = #"{"event":"Stop","session_id":"s2","ts":1}"#
        let ev = HookManager.parseEventFile(Data(json.utf8), fallbackPid: 7)
        XCTAssertEqual(ev?.pid, 7)
        XCTAssertEqual(ev?.impliedStatus, .idle)
    }

    func testImpliedStatuses() {
        func status(_ e: String, type: String? = nil, msg: String? = nil) -> SessionStatus? {
            HookEvent(pid: 1, event: e, notificationType: type, message: msg, timestamp: Date()).impliedStatus
        }
        XCTAssertEqual(status("UserPromptSubmit"), .working)
        XCTAssertEqual(status("PostToolUse"), .working)
        XCTAssertEqual(status("SessionEnd"), .finished)
        XCTAssertEqual(status("Notification", type: "idle_prompt"), .idle)
        XCTAssertNil(status("Notification", msg: "something else"))
        XCTAssertNil(status("Unknown"))
    }

    func testInstallAndUninstallPreserveForeignHooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }

        let existing = #"{"model":"opus","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#
        try existing.write(toFile: Paths.claudeSettingsFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(HookManager.install(), .installed)
        XCTAssertEqual(HookManager.state(), .installed)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Paths.hookScript))
        // Idempotent
        XCTAssertEqual(HookManager.install(), .installed)
        let settings = HookManager.readSettings()!
        let stop = (settings["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(HookManager.state(), .installed)
        XCTAssertEqual(settings["model"] as? String, "opus")

        try HookManager.uninstall()
        let after = HookManager.readSettings()!
        let hooks = after["hooks"] as! [String: Any]
        XCTAssertEqual(hooks.keys.sorted(), ["Stop"])
        XCTAssertEqual((hooks["Stop"] as! [[String: Any]]).count, 1)
        XCTAssertEqual(HookManager.state(), .notInstalled)
    }

    private func withTempHome(_ body: (String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        try body(home)
    }

    private func runHook(_ payload: String, inContainer: Bool, home: String) -> ShellResult {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["QODENOTCH_IN_CONTAINER"] = inContainer ? "1" : "0"
        // Exactly the command Claude Code runs from settings.json.
        return Shell.runSync("/bin/sh", ["-c", HookManager.command], environment: env, input: payload)
    }

    func testHookScriptWritesHostEventFile() throws {
        try withTempHome { home in
            XCTAssertEqual(HookManager.install(), .installed)
            let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/tmp","transcript_path":"/tmp/a.jsonl","prompt":"say \"hi\""}"#
            let r = runHook(payload, inContainer: false, home: home)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
            let snap = HookManager.readAll()
            XCTAssertEqual(snap.byPid.count, 1)
            XCTAssertTrue(snap.containerEvents.isEmpty)
            let ev = try XCTUnwrap(snap.byPid.values.first)
            XCTAssertEqual(ev.sessionId, "abc")
            XCTAssertEqual(ev.event, "UserPromptSubmit")
            XCTAssertEqual(ev.transcriptPath, "/tmp/a.jsonl")
        }
    }

    func testHookScriptWritesContainerEventFile() throws {
        try withTempHome { home in
            XCTAssertEqual(HookManager.install(), .installed)
            let payload = #"{"hook_event_name":"Notification","session_id":"s-123","cwd":"/Users/me/code/app","transcript_path":"/home/claude/.claude/projects/-Users-me-code-app/s-123.jsonl","notification_type":"permission_prompt"}"#
            let r = runHook(payload, inContainer: true, home: home)
            XCTAssertEqual(r.exitCode, 0, r.stderr)
            XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.eventsDir + "/c-s-123.json"))
            let snap = HookManager.readAll()
            XCTAssertTrue(snap.byPid.isEmpty)
            let ev = try XCTUnwrap(snap.containerEvent(cwd: "/Users/me/code/app"))
            XCTAssertNil(ev.pid)
            XCTAssertNotNil(ev.container)
            XCTAssertEqual(ev.impliedStatus, .waiting)
            XCTAssertNil(snap.containerEvent(cwd: "/elsewhere"))

            // Container transcript paths map onto the host's ~/.claude.
            let hostFile = Paths.claudeProjectsDir + "/-Users-me-code-app/s-123.jsonl"
            try FileManager.default.createDirectory(atPath: Paths.claudeProjectsDir + "/-Users-me-code-app", withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: hostFile, contents: Data())
            XCTAssertEqual(HookManager.hostTranscriptPath(ev.transcriptPath!), hostFile)
        }
    }

    func testHookCommandIsHarmlessWithoutScript() throws {
        try withTempHome { home in
            let r = runHook(#"{"hook_event_name":"Stop","session_id":"x"}"#, inContainer: true, home: home)
            XCTAssertEqual(r.exitCode, 0)
        }
    }

    func testInstallMigratesLegacyAbsolutePath() throws {
        try withTempHome { home in
            try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
            let legacy = home + "/.qodenotch/hooks/status-hook.sh"
            let settings = #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"\#(legacy)","timeout":5}]},{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#
            try settings.write(toFile: Paths.claudeSettingsFile, atomically: true, encoding: .utf8)
            XCTAssertEqual(HookManager.install(), .installed)
            let stop = (HookManager.readSettings()!["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
            let commands = stop.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
            XCTAssertEqual(commands.sorted(), [HookManager.command, "/usr/bin/true"].sorted())
        }
    }
}

final class ContainerTests: XCTestCase {
    func testAirlockRunInvocation() {
        let args = "/opt/homebrew/bin/podman run -it --name airlock-app-0123456789ab --userns keep-id:uid=1000,gid=1000 --cap-add NET_ADMIN,SETPCAP -v /Users/me/code/app:/Users/me/code/app -w /Users/me/code/app localhost/airlock:latest claude --model opus"
        let c = ProcessScanner.parseContainerInvocation(args)
        XCTAssertEqual(c?.containerName, "airlock-app-0123456789ab")
        XCTAssertEqual(c?.isAirlock, true)
        XCTAssertEqual(c?.runtime, "/opt/homebrew/bin/podman")
    }

    func testAirlockStartInvocation() {
        let c = ProcessScanner.parseContainerInvocation("podman start --attach --interactive airlock-app-0123456789ab")
        XCTAssertEqual(c?.containerName, "airlock-app-0123456789ab")
    }

    func testGenericDockerClaude() {
        XCTAssertNotNil(ProcessScanner.parseContainerInvocation("docker run --rm -it -v /x:/x my/image claude"))
        XCTAssertNotNil(ProcessScanner.parseContainerInvocation("docker exec -it -w /work devbox claude"))
    }

    func testIgnoresUnrelatedRuntimeCalls() {
        XCTAssertNil(ProcessScanner.parseContainerInvocation("podman machine start"))
        XCTAssertNil(ProcessScanner.parseContainerInvocation("podman build -t localhost/airlock:latest ."))
        XCTAssertNil(ProcessScanner.parseContainerInvocation("podman ps -q --filter name=^airlock-x$"))
        XCTAssertNil(ProcessScanner.parseContainerInvocation("docker run -d --name web nginx"))
        XCTAssertNil(ProcessScanner.parseContainerInvocation("podman run -it --name airlock-x -d img claude"))
        XCTAssertNil(ProcessScanner.parseContainerInvocation("/usr/bin/claude"))
    }

    func testStatusFromContainerEventWithoutCpu() {
        // Container sessions report no CPU; hooks alone must drive the status.
        let now = Date()
        XCTAssertEqual(StatusClassifier.classify(.init(cpuPercent: 0, hookStatus: .waiting, hookTimestamp: now), now: now), .waiting)
        XCTAssertEqual(StatusClassifier.classify(.init(transcriptMtime: now, cpuPercent: 10, hookStatus: .working, hookTimestamp: now), now: now), .working)
    }
}

final class ProcessAndTerminalTests: XCTestCase {
    func testParseProcessTree() {
        let out = """
          1     0   0.0 /sbin/launchd
        500     1   1,5 /Applications/iTerm.app/Contents/MacOS/iTerm2
        501   500   0.0 -zsh
        502   501  23.4 claude
        503     1   0.0 /Applications/Claude.app/Contents/MacOS/Claude
        """
        let tree = ProcessScanner.parseTree(out)
        XCTAssertEqual(tree.count, 5)
        XCTAssertEqual(tree[500]?.cpuPercent, 1.5)
        XCTAssertEqual(ProcessScanner.claudePids(in: tree), [502])
        XCTAssertEqual(TerminalDetector.findTerminal(from: 502, in: tree), .iterm)
        XCTAssertFalse(TerminalDetector.isOrphaned(pid: 502, tree: tree, inTmux: false, tmuxHasClient: false))
        XCTAssertTrue(TerminalDetector.isOrphaned(pid: 503, tree: tree, inTmux: false, tmuxHasClient: false))
        XCTAssertTrue(TerminalDetector.isOrphaned(pid: 502, tree: tree, inTmux: true, tmuxHasClient: false))
    }

    func testTerminalMatching() {
        XCTAssertEqual(TerminalDetector.match("/Applications/Ghostty.app/Contents/MacOS/ghostty"), .ghostty)
        XCTAssertEqual(TerminalDetector.match("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), .terminalApp)
        XCTAssertEqual(TerminalDetector.match("wezterm-gui"), .wezterm)
        XCTAssertEqual(TerminalDetector.match("iTermServer-3.5.14"), .iterm)
        XCTAssertEqual(TerminalDetector.match("/Applications/Warp.app/Contents/MacOS/stable"), .warp)
        XCTAssertNil(TerminalDetector.match("stable"))
        XCTAssertNil(TerminalDetector.match("-zsh"))
        XCTAssertNil(TerminalDetector.match("terminal-notifier"))
    }

    func testParseLsofAndTmux() {
        let lsof = "p123\nfcwd\nn/Users/me/code/app\np456\nfcwd\nn/tmp\n"
        XCTAssertEqual(ProcessScanner.parseLsofCwd(lsof), [123: "/Users/me/code/app", 456: "/tmp"])
        let panes = TerminalDetector.parseTmuxPanes("/dev/ttys004\t%5\tmain\t1\t0\n")
        XCTAssertEqual(panes["/dev/ttys004"]?.target, "main:1.0")
    }

    func testClaudeCommandQuoting() {
        let cmd = TerminalController.claudeCommand(cwd: "/Users/me/it's here", prompt: "Fix 'it'", initialCommand: "claude")
        XCTAssertEqual(cmd, #"cd '/Users/me/it'\''s here' && claude 'Fix '\''it'\'''"#)
        let r = Shell.runSync("/bin/sh", ["-c", "echo " + Shell.quote("a'b $HOME")])
        XCTAssertEqual(r.stdout, "a'b $HOME\n")
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(AppleScript.escape("say \"hi\"\\\n"), #"say \"hi\"\\\n"#)
    }
}

final class MiscTests: XCTestCase {
    func testProjectDirNames() {
        let names = Paths.escapedProjectNames(for: "/Users/me/my.app_x")
        XCTAssertEqual(names.first, "-Users-me-my-app-x")
        XCTAssertTrue(names.contains("-Users-me-my.app_x"))
    }

    func testBranchValidation() {
        XCTAssertTrue(SessionActions.isValidBranchName("feat/new-thing_1.2"))
        XCTAssertFalse(SessionActions.isValidBranchName("bad..name"))
        XCTAssertFalse(SessionActions.isValidBranchName("/abs"))
        XCTAssertFalse(SessionActions.isValidBranchName("has space"))
        XCTAssertFalse(SessionActions.isValidBranchName("-x"))
        XCTAssertEqual(SessionActions.worktreePath(repo: "/code/app", branch: "feat/x"), "/code/app-feat-x")
    }

    func testGitSummaryParsing() {
        let s = GitInfo.parseSummary(branch: "main", porcelain: " M a.swift\n?? new.txt\nA  b.swift", shortStat: " 2 files changed, 10 insertions(+), 3 deletions(-)")
        XCTAssertEqual(s.changedFiles, 2)
        XCTAssertEqual(s.untrackedFiles, 1)
        XCTAssertEqual(s.additions, 10)
        XCTAssertEqual(s.deletions, 3)
    }

    func testPrStatusParsing() {
        let json = #"{"url":"https://github.com/o/r/pull/7","state":"OPEN","reviewDecision":"","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"},{"status":"IN_PROGRESS","conclusion":""}]}"#
        let s = PullRequestService.parseStatus(json, fallbackUrl: "")
        XCTAssertEqual(s?.checks, .pending)
        XCTAssertEqual(s?.checksPassing, 2)
        XCTAssertNil(s?.reviewDecision)
        XCTAssertEqual(s?.number, "7")
        XCTAssertEqual(PullRequestService.parsePrUrl("https://github.com/o/r/pull/7")?.number, 7)
    }

    func testConfigDecodesPartialJson() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"editor":"zed","terminalApp":"iterm","bogus":1}"#.utf8))
        XCTAssertEqual(c.editor, "zed")
        XCTAssertEqual(c.terminalApp, .iterm)
        XCTAssertEqual(c.initialCommand, "claude")
        XCTAssertEqual(c.editorOption?.command, "zed")
    }

    func testGroupingAndStale() {
        let a = ClaudeSession(id: "a", pid: 1, workingDirectory: "/code/app", repoName: "app", status: .idle)
        let b = ClaudeSession(id: "b", pid: 2, workingDirectory: "/code/app-x", repoName: "app-x", parentRepo: "/code/app", isWorktree: true, status: .working)
        let c = ClaudeSession(id: "c", pid: 3, workingDirectory: "/code/zeta", repoName: "zeta", status: .idle, lastActivity: Date().addingTimeInterval(-7200))
        let groups = SessionGrouping.group([c, a, b])
        XCTAssertEqual(groups.map(\.repoName), ["app", "zeta"])
        XCTAssertEqual(groups[0].sessions.map(\.id), ["a", "b"])
        XCTAssertTrue(SessionGrouping.isStale(c, thresholdMinutes: 90))
        XCTAssertFalse(SessionGrouping.isStale(a, thresholdMinutes: 90))
    }

    func testRepoScanAndMetaOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/one/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/group/two/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/plain", withIntermediateDirectories: true)
        let repos = SessionActions.scanRepos(in: [root])
        XCTAssertEqual(repos.map(\.name), ["one", "two"])

        setenv("HOME", root, 1)
        defer { unsetenv("HOME") }
        try SessionMetaStore.save(sessionId: "s", title: "My title", description: nil)
        var sessions = [ClaudeSession(id: "s", pid: 1, workingDirectory: "/x", repoName: "x", status: .idle)]
        SessionMetaStore.apply(SessionMetaStore.load(), to: &sessions)
        XCTAssertEqual(sessions[0].displayTitle, "My title")
        XCTAssertEqual(sessions[0].taskSummary?.source, .user)
    }

    func testShellTimeout() {
        let r = Shell.runSync("/bin/sleep", ["5"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok)
    }
}

final class HistoryTests: XCTestCase {
    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    func testListsStoredSessionsNewestFirst() async throws {
        let home = try makeHome()
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        let project = home + "/code/app"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let dir = Paths.claudeProjectsDir + "/" + Paths.escapedProjectNames(for: project)[0]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let old = #"{"type":"user","sessionId":"aaaa-1","cwd":"\#(project)","gitBranch":"main","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"Add login page\nwith OAuth"}}"#
        let new = #"""
        {"type":"summary","summary":"Some other session","leafUuid":"x"}
        {"type":"ai-title","sessionId":"bbbb-2","aiTitle":"Refactor database layer"}
        {"type":"user","sessionId":"bbbb-2","cwd":"\#(project)","gitBranch":"feat/db","message":{"role":"user","content":"Refactor the db"}}
        """#
        let empty = #"{"type":"system","sessionId":"cccc-3","cwd":"\#(project)"}"#
        try old.write(toFile: dir + "/aaaa-1.jsonl", atomically: true, encoding: .utf8)
        try new.write(toFile: dir + "/bbbb-2.jsonl", atomically: true, encoding: .utf8)
        try empty.write(toFile: dir + "/cccc-3.jsonl", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: dir + "/aaaa-1.jsonl")

        let list = await SessionHistory().list()
        XCTAssertEqual(list.map(\.id), ["bbbb-2", "aaaa-1"])
        XCTAssertEqual(list[0].title, "Refactor database layer")
        XCTAssertEqual(list[0].branch, "feat/db")
        XCTAssertEqual(list[1].title, "Add login page")
        XCTAssertEqual(list[1].summary, "with OAuth")
        XCTAssertEqual(list[1].workingDirectory, project)
        XCTAssertTrue(list[1].directoryExists)

        XCTAssertEqual(SessionHistory.filter(list, query: "oauth").map(\.id), ["aaaa-1"])
        XCTAssertEqual(SessionHistory.filter(list, query: "feat/db refactor").map(\.id), ["bbbb-2"])
        XCTAssertEqual(SessionHistory.filter(list, query: "").count, 2)
    }

    func testResumeCommands() {
        let past = PastSession(id: "1b2c-3d", transcriptPath: "/t", workingDirectory: "/x", title: "t", summary: nil,
                               branch: nil, lastActivity: Date(), startedAt: nil)
        var config = AppConfig()
        config.resumeStrategy = .resume
        XCTAssertEqual(SessionResumer.command(for: past, config: config), "claude --resume 1b2c-3d")
        config.resumeStrategy = .airlock
        XCTAssertEqual(SessionResumer.command(for: past, config: config), "claude")

        var evil = past
        evil.id = "x; rm -rf ~"
        config.resumeStrategy = .resume
        XCTAssertNil(SessionResumer.command(for: evil, config: config))
    }

    func testPyCharmEditorOption() throws {
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"editor":"pycharm","theme":"light"}"#.utf8))
        XCTAssertEqual(c.editorOption?.command, "pycharm")
        XCTAssertTrue(c.editorOption?.alternateAppNames.contains("PyCharm CE") ?? false)
        XCTAssertEqual(c.theme, .light)
        XCTAssertEqual(c.resumeStrategy, .auto)
    }
}

final class UsageTests: XCTestCase {
    func testParseLimitsArray() {
        let json = #"{"limits":[{"kind":"weekly_all","percent":18.5,"resets_at":"2026-11-20T10:00:00Z"},{"kind":"session","percent":42,"resets_at":"2026-11-17T15:00:00.000Z"},{"kind":"weekly_scoped","percent":7,"scope":{"model":{"id":"opus","display_name":"Opus"}}}]}"#
        let l = UsageLimits.parse(Data(json.utf8), plan: "max")
        XCTAssertEqual(l?.limits.map(\.kind), [.session, .weekly, .weeklyModel])
        XCTAssertEqual(l?.limits[0].percent, 42)
        XCTAssertNotNil(l?.limits[0].resetsAt)
        XCTAssertEqual(l?.limits[2].title, "Woche (Opus)")
        XCTAssertEqual(l?.plan, "max")
    }

    func testParseLegacyLimits() {
        let json = #"{"five_hour":{"utilization":12.0,"resets_at":"2026-11-17T15:00:00Z"},"seven_day":{"utilization":30},"seven_day_opus":null}"#
        let l = UsageLimits.parse(Data(json.utf8))
        XCTAssertEqual(l?.limits.map(\.kind), [.session, .weekly])
        XCTAssertNil(UsageLimits.parse(Data("{}".utf8)))
    }

    func testCredentialParsing() {
        let c = UsageLimitsClient.parseCredential(Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":4102444800000,"subscriptionType":"max"}}"#.utf8))
        XCTAssertEqual(c?.accessToken, "tok")
        XCTAssertEqual(c?.plan, "max")
        XCTAssertEqual(c?.isExpired, false)
        XCTAssertNil(UsageLimitsClient.parseCredential(Data("{}".utf8)))
    }

    func testModelNames() {
        XCTAssertEqual(ModelName.pretty("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(ModelName.pretty("claude-sonnet-4-20250514"), "Sonnet 4")
        XCTAssertEqual(ModelName.pretty("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelName.pretty("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(ModelName.pretty("claude-opus-5-5[1m]"), "Opus 5.5 (1M)")
        XCTAssertEqual(ModelName.pretty("llama-x"), "llama-x")
    }

    func testSessionNameModelAndTokenTotals() {
        let lines = TranscriptReader.parse(#"""
        {"type":"summary","summary":"Old summary"}
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","timestamp":"2026-11-17T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5","role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100},"content":[{"type":"text","text":"a"}]}}
        {"type":"assistant","timestamp":"2026-11-17T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5","role":"assistant","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100},"content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        {"type":"custom-title","customTitle":"Login-Refactoring","sessionId":"s"}
        """#)
        XCTAssertEqual(TranscriptReader.sessionName(lines), "Login-Refactoring")
        XCTAssertEqual(TranscriptReader.model(lines), "claude-opus-4-5")
        let totals = TranscriptReader.usageTotals(lines)
        XCTAssertEqual(totals.total.total, 115)
        XCTAssertEqual(totals.byModel["claude-opus-4-5"]?.output, 5)
    }

    func testLocalUsageScannerIsIncremental() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        let dir = Paths.claudeProjectsDir + "/-x"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/s.jsonl"
        let now = Date()
        let ts = ISO8601DateFormatter().string(from: now)
        func line(_ id: String, _ out: Int) -> String {
            #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":1,"output_tokens":\#(out)}}}"# + "\n"
        }
        try (line("a", 10) + line("a", 10)).write(toFile: file, atomically: true, encoding: .utf8)
        let scanner = LocalUsageScanner()
        var r = await scanner.report(now: now)
        XCTAssertEqual(r.days.count, 7)
        XCTAssertEqual(r.today.total, 11)
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        fh.seekToEndOfFile()
        fh.write(Data(line("b", 20).utf8))
        try fh.close()
        r = await scanner.report(now: now)
        XCTAssertEqual(r.today.total, 32)
        XCTAssertEqual(r.byModel.first?.model, "claude-sonnet-4-5")
        XCTAssertEqual(TokenFormat.short(1_234_567), "1,2 Mio.")
    }

    func testDesktopDeepLink() {
        XCTAssertEqual(SessionActions.claudeDesktopURL(hostSessionId: "local_abc-123"), "claude://code/continue?session=local_abc-123")
        XCTAssertNil(SessionActions.claudeDesktopURL(hostSessionId: "local_../x"))
        XCTAssertNil(SessionActions.claudeDesktopURL(hostSessionId: "abc"))
    }
}

final class IDEAndForgeTests: XCTestCase {
    func testPyCharmTerminalIsDetected() {
        let tree = ProcessScanner.parseTree("""
          1     0   0.0 /sbin/launchd
        700     1   3.0 /Applications/PyCharm CE.app/Contents/MacOS/pycharm
        701   700   0.0 /bin/zsh
        702   701   0.0 /opt/homebrew/bin/podman
        """)
        let r = TerminalDetector.resolve(from: 702, in: tree)
        XCTAssertEqual(r.app, .ide)
        XCTAssertEqual(r.host, HostApp(name: "PyCharm CE", pid: 700))
        XCTAssertFalse(TerminalDetector.isOrphaned(pid: 702, tree: tree, inTmux: false, tmuxHasClient: false))
    }

    func testVSCodeHelperResolvesToMainApp() {
        let tree = ProcessScanner.parseTree("""
          1     0   0.0 /sbin/launchd
        800     1   1.0 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
        801   800   0.0 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)
        802   801   0.0 /bin/zsh
        803   802   9.0 claude
        """)
        XCTAssertEqual(TerminalDetector.resolve(from: 803, in: tree).host, HostApp(name: "Visual Studio Code", pid: 800))
    }

    func testRealTerminalWinsOverHostApp() {
        let tree = ProcessScanner.parseTree("""
          1     0   0.0 /sbin/launchd
        500     1   1.0 /Applications/iTerm.app/Contents/MacOS/iTerm2
        501   500   0.0 -zsh
        502   501   1.0 claude
        """)
        let r = TerminalDetector.resolve(from: 502, in: tree)
        XCTAssertEqual(r.app, .iterm)
        XCTAssertNil(r.host)
    }

    func testEditorFocusGuard() {
        XCTAssertTrue(IDETerminal.isEditor("AXTextArea | Editor for main.py | "))
        XCTAssertFalse(IDETerminal.isEditor("AXTextArea | Terminal | Local"))
        XCTAssertFalse(IDETerminal.isEditor("AXScrollArea | "))
    }

    func testHotKeyDisplayAndDecoding() throws {
        XCTAssertEqual(HotKeySpec.defaultToggle.display, "⇧⌘I")
        XCTAssertEqual(HotKeySpec(keyCode: 49, modifiers: HotKeySpec.control | HotKeySpec.option, key: "Space").display, "⌃⌥Space")
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"hotkeyToggleKey":{"keyCode":45,"modifiers":4352,"key":"N"},"forge":"gitlab"}"#.utf8))
        XCTAssertEqual(c.hotkeyToggleKey.display, "⌃⌘N")
        XCTAssertEqual(c.forge, .gitlab)
        XCTAssertEqual(AppConfig().hotkeyToggleKey, .defaultToggle)
    }

    func testRemoteHostParsing() {
        XCTAssertEqual(PullRequestService.remoteHost("git@gitlab.example.com:group/repo.git"), "gitlab.example.com")
        XCTAssertEqual(PullRequestService.remoteHost("https://github.com/o/r.git"), "github.com")
        XCTAssertEqual(PullRequestService.remoteHost("ssh://git@code.firma.de:2222/team/app.git"), "code.firma.de")
        XCTAssertEqual(PullRequestService.remoteHost("remote.origin.url https://gitlab.com/a/b"), "gitlab.com")
        XCTAssertTrue(PullRequestService.isMergeRequestURL("https://gitlab.com/a/b/-/merge_requests/12"))
    }

    func testGitLabParsing() {
        let list = #"[{"iid":3,"web_url":"https://gitlab.com/a/b/-/merge_requests/3"},{"iid":7,"web_url":"https://gitlab.com/a/b/-/merge_requests/7"}]"#
        XCTAssertEqual(PullRequestService.parseGitLabMRList(list), "https://gitlab.com/a/b/-/merge_requests/7")
        XCTAssertNil(PullRequestService.parseGitLabMRList("[]"))

        let view = #"{"iid":7,"state":"opened","web_url":"https://gitlab.com/a/b/-/merge_requests/7","has_conflicts":true,"head_pipeline":{"status":"running"},"user_notes_count":4,"detailed_merge_status":"conflict"}"#
        let approvals = #"{"approved":false,"approvals_left":1}"#
        let discussions = #"[{"notes":[{"resolvable":true,"resolved":false}]},{"notes":[{"resolvable":true,"resolved":true}]},{"notes":[{"resolvable":false}]}]"#
        let s = PullRequestService.parseGitLabStatus(view: view, approvals: approvals, discussions: discussions, fallbackUrl: "")
        XCTAssertEqual(s?.state, "OPEN")
        XCTAssertEqual(s?.checks, .pending)
        XCTAssertEqual(s?.mergeable, "CONFLICTING")
        XCTAssertEqual(s?.reviewDecision, "REVIEW_REQUIRED")
        XCTAssertEqual(s?.unresolvedThreads, 1)
        XCTAssertEqual(s?.commentCount, 4)
        XCTAssertEqual(s?.number, "7")

        let merged = PullRequestService.parseGitLabStatus(view: #"{"state":"merged","head_pipeline":{"status":"success"}}"#, approvals: #"{"approved":true}"#, discussions: nil, fallbackUrl: "u")
        XCTAssertEqual(merged?.state, "MERGED")
        XCTAssertEqual(merged?.checks, .passing)
        XCTAssertEqual(merged?.reviewDecision, "APPROVED")
    }
}

final class AgentTests: XCTestCase {
    func testAgentProcessNames() {
        XCTAssertEqual(ProcessScanner.agent(forComm: "/opt/homebrew/bin/codex"), .codex)
        XCTAssertEqual(ProcessScanner.agent(forComm: "/usr/local/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex-aarch64-apple-darwin"), .codex)
        XCTAssertNil(ProcessScanner.agent(forComm: "/Applications/Codex.app/Contents/MacOS/Codex"))
        XCTAssertEqual(ProcessScanner.agent(forComm: "copilot"), .copilot)
        XCTAssertEqual(ProcessScanner.agent(forComm: "claude"), .claude)
        XCTAssertNil(ProcessScanner.agent(forComm: "codex-mcp-server"))
    }

    func testCodexRolloutIsTranslated() {
        let lines = TranscriptReader.parse(#"""
        {"timestamp":"2026-11-17T10:00:00.000Z","type":"session_meta","payload":{"id":"0199a-uuid","cwd":"/Users/me/app","git":{"branch":"feat/x"}}}
        {"timestamp":"2026-11-17T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/me/app"}}
        {"timestamp":"2026-11-17T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Fix the tests"}}
        {"timestamp":"2026-11-17T10:00:03.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"sudo rm -rf build\"]}","call_id":"c1"}}
        {"timestamp":"2026-11-17T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":40,"window_minutes":10080}}}}
        """#)
        XCTAssertEqual(TranscriptReader.sessionId(lines), "0199a-uuid")
        XCTAssertEqual(TranscriptReader.branch(lines), "feat/x")
        XCTAssertEqual(TranscriptReader.model(lines), "gpt-5-codex")
        XCTAssertTrue(TranscriptReader.hasPendingToolUse(lines))
        let p = TranscriptReader.preview(lines)
        XCTAssertEqual(p.lastUserMessage, "Fix the tests")
        XCTAssertEqual(p.lastTools.first?.name, "Bash")
        XCTAssertEqual(p.lastTools.first?.input, "sudo rm -rf build")
        XCTAssertFalse(p.lastTools.first?.warnings.isEmpty ?? true)
        let usage = TranscriptReader.usageTotals(lines)
        XCTAssertEqual(usage.total.input, 600)
        XCTAssertEqual(usage.total.cacheRead, 400)
        XCTAssertEqual(TranscriptReader.taskSummary(lines)?.title, "Fix the tests")
        XCTAssertEqual(ModelName.pretty("gpt-5-codex"), "GPT-5 Codex")

        let rl = AgentStores.parseCodexRateLimits(["primary": ["used_percent": 12.5, "window_minutes": 300, "resets_in_seconds": 600],
                                                   "secondary": ["used_percent": 40, "window_minutes": 10080]], observedAt: Date())
        XCTAssertEqual(rl?.limits.map(\.kind), [.session, .weekly])
        XCTAssertEqual(rl?.limits.first?.percent, 12.5)
    }

    func testCopilotEventsAreTranslated() {
        let lines = TranscriptReader.parse(#"""
        {"type":"session.start","data":{"sessionId":"cp-1","context":{"cwd":"/Users/me/app"}},"timestamp":"2026-11-17T10:00:00Z"}
        {"type":"session.model_change","data":{"newModel":"claude-sonnet-4.5"},"timestamp":"2026-11-17T10:00:00Z"}
        {"type":"user.message","data":{"content":"Add a README"},"timestamp":"2026-11-17T10:00:01Z"}
        {"type":"assistant.message","data":{"content":"Sure, writing it now."},"timestamp":"2026-11-17T10:00:02Z"}
        {"type":"tool.execution_start","data":{"toolName":"bash","arguments":{"command":"ls -la"}},"timestamp":"2026-11-17T10:00:03Z"}
        """#)
        XCTAssertEqual(lines.compactMap(\.cwd).first, "/Users/me/app")
        let p = TranscriptReader.preview(lines)
        XCTAssertEqual(p.lastUserMessage, "Add a README")
        XCTAssertEqual(p.lastTools.first?.input, "ls -la")
        XCTAssertTrue(TranscriptReader.hasPendingToolUse(lines))
        XCTAssertEqual(TranscriptReader.model(lines), "claude-sonnet-4.5")
    }

    func testCodexConfigFlag() {
        XCTAssertEqual(CodexConfig.enablingHooks(""), "features.hooks = true\n")
        XCTAssertEqual(CodexConfig.enablingHooks("model = \"o3\"\n\n[profiles.x]\nmodel = \"y\"\n"),
                       "model = \"o3\"\n\nfeatures.hooks = true\n[profiles.x]\nmodel = \"y\"\n")
        XCTAssertEqual(CodexConfig.enablingHooks("[features]\nweb_search = true\n"), "[features]\nhooks = true\nweb_search = true\n")
        XCTAssertEqual(CodexConfig.enablingHooks("[features]\nhooks = false\n"), "[features]\nhooks = true\n")
        let already = "[features]\nhooks = true # on\n"
        XCTAssertEqual(CodexConfig.enablingHooks(already), already)
        XCTAssertNil(CodexConfig.enablingHooks("features.x = 1\n[features]\ny = 2\n"))
        XCTAssertTrue(CodexConfig.hooksEnabled("features.codex_hooks = true"))
    }

    func testCodexAndCopilotHookInstall() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.copilot", withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        unsetenv("CODEX_HOME")
        defer { unsetenv("HOME") }
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#.write(toFile: home + "/.codex/hooks.json", atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentHooks.installCodex(), .installed)
        XCTAssertEqual(AgentHooks.installCodex(), .installed)   // idempotent
        let stop = (AgentHooks.readJSON(home + "/.codex/hooks.json")?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 2)
        XCTAssertTrue(CodexConfig.hooksEnabled(try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8)))
        AgentHooks.uninstallCodex()
        XCTAssertEqual(((AgentHooks.readJSON(home + "/.codex/hooks.json")?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.count, 1)

        XCTAssertEqual(AgentHooks.installCopilot(), .installed)
        XCTAssertEqual(AgentHooks.readJSON(AgentHooks.copilotHookFile)?["version"] as? Int, 1)

        // The copilot hook command records the event name passed as argument.
        XCTAssertEqual(HookManager.install(), .installed)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        env["QODENOTCH_IN_CONTAINER"] = "0"
        let r = Shell.runSync("/bin/sh", ["-c", AgentHooks.command(agent: .copilot, event: "preToolUse")], environment: env,
                              input: #"{"sessionId":"cp-1","cwd":"/tmp","toolName":"bash"}"#)
        XCTAssertEqual(r.exitCode, 0)
        let ev = try XCTUnwrap(HookManager.readAll().byPid.values.first)
        XCTAssertEqual(ev.agent, .copilot)
        XCTAssertEqual(ev.event, "preToolUse")
        XCTAssertEqual(ev.sessionId, "cp-1")
        XCTAssertEqual(ev.toolName, "bash")
        XCTAssertEqual(ev.impliedStatus, .working)
        XCTAssertEqual(HookEvent(pid: 1, event: "PermissionRequest", timestamp: Date()).impliedStatus, nil)
        var codexPerm = HookEvent(pid: 1, event: "PermissionRequest", timestamp: Date())
        codexPerm.agent = .codex
        XCTAssertEqual(codexPerm.impliedStatus, .waiting)
    }

    func testResumeCommandsPerAgent() {
        var past = PastSession(id: "abc-1", transcriptPath: "/t", workingDirectory: "/x", title: "t", summary: nil, branch: nil, lastActivity: Date(), startedAt: nil)
        let config = AppConfig()
        past.agent = .codex
        XCTAssertEqual(SessionResumer.command(for: past, config: config), "codex resume abc-1")
        past.agent = .copilot
        XCTAssertEqual(SessionResumer.command(for: past, config: config), "copilot --resume abc-1")
        XCTAssertEqual(SessionActions.startCommand(agent: .copilot, hasPrompt: true, config: config), "copilot -i")
        XCTAssertEqual(SessionActions.startCommand(agent: .codex, hasPrompt: true, config: config), "codex")
    }
}

final class ForgejoTests: XCTestCase {
    func testRepoFromRemote() {
        XCTAssertEqual(ForgejoAPI.repo(fromRemote: "git@codeberg.org:me/app.git"), ForgejoAPI.Repo(host: "codeberg.org", owner: "me", name: "app"))
        XCTAssertEqual(ForgejoAPI.repo(fromRemote: "https://git.firma.de/team/sub/app"), ForgejoAPI.Repo(host: "git.firma.de", owner: "sub", name: "app"))
        XCTAssertEqual(ForgejoAPI.repo(fromRemote: "ssh://git@git.firma.de:2222/team/app.git")?.owner, "team")
        let p = ForgejoAPI.pull(fromURL: "https://codeberg.org/me/app/pulls/12")
        XCTAssertEqual(p?.number, 12)
        XCTAssertEqual(p?.repo.name, "app")
        XCTAssertTrue(PullRequestService.isForgejoURL("https://codeberg.org/me/app/pulls/12"))
        XCTAssertFalse(PullRequestService.isForgejoURL("https://github.com/me/app/pull/12"))
    }

    func testCredentialsAndStatusParsing() {
        let keys = #"{"hosts":{"codeberg.org":{"type":"Application","token":"abc"},"git.x.de:3000":{"type":"OAuth","token":"t2","refresh_token":"r","expires_at":"x"}}}"#
        let logins = FjCredentials.parse(Data(keys.utf8))
        XCTAssertEqual(logins?["codeberg.org"], "abc")
        XCTAssertEqual(logins?["git.x.de:3000"], "t2")

        XCTAssertEqual(ForgejoAPI.matchPR([["number": 3, "head": ["ref": "feat"], "html_url": "u3"], ["number": 5, "head": ["ref": "feat"], "html_url": "u5"], ["number": 9, "head": ["ref": "main"], "html_url": "u9"]], branch: "feat"), "u5")

        let s = ForgejoAPI.parseStatus(
            pr: ["state": "open", "merged": false, "mergeable": false, "html_url": "https://codeberg.org/me/app/pulls/5", "comments": 2],
            combined: ["statuses": [["status": "success"], ["status": "pending"]]],
            reviews: [["state": "APPROVED", "user": ["login": "a"]], ["state": "REQUEST_CHANGES", "user": ["login": "b"]]],
            fallbackUrl: "")
        XCTAssertEqual(s.state, "OPEN")
        XCTAssertEqual(s.checks, .pending)
        XCTAssertEqual(s.mergeable, "CONFLICTING")
        XCTAssertEqual(s.reviewDecision, "CHANGES_REQUESTED")
        XCTAssertEqual(s.number, "5")
    }
}

final class SessionTitleTests: XCTestCase {
    func testAiAndCustomTitlesWithSessionIds() async throws {
        let jsonl = #"""
        {"type":"summary","summary":"Title of ANOTHER session","leafUuid":"x"}
        {"type":"user","sessionId":"s1","message":{"role":"user","content":"please refactor the parser"}}
        {"type":"ai-title","sessionId":"old","aiTitle":"Carried over from /clear"}
        {"type":"ai-title","sessionId":"s1","aiTitle":"Parser refactoring"}
        """#
        let lines = TranscriptReader.parse(jsonl)
        XCTAssertEqual(TranscriptReader.sessionName(lines, sessionId: "s1"), "Parser refactoring")
        XCTAssertEqual(TranscriptReader.sessionName(lines + TranscriptReader.parse(#"{"type":"custom-title","sessionId":"s1","customTitle":"Mein Name"}"#), sessionId: "s1"), "Mein Name")
        // summary lines are never used as the name
        XCTAssertNil(TranscriptReader.sessionName(TranscriptReader.parse(#"{"type":"summary","summary":"x"}"#), sessionId: "s1"))

        // Titles in the middle of a big file are found, incrementally.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl").path
        var big = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"hi"}}"# + "\n"
        big += #"{"type":"ai-title","sessionId":"s1","aiTitle":"Early title"}"# + "\n"
        for i in 0..<2000 { big += #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"line \#(i)"}]}}"# + "\n" }
        try big.write(toFile: file, atomically: true, encoding: .utf8)
        let titles = SessionTitles()
        var name = await titles.name(transcript: file, sessionId: "s1")
        XCTAssertEqual(name, "Early title")
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        fh.seekToEndOfFile()
        fh.write(Data((#"{"type":"custom-title","sessionId":"s1","customTitle":"Renamed"}"# + "\n").utf8))
        try fh.close()
        name = await titles.name(transcript: file, sessionId: "s1")
        XCTAssertEqual(name, "Renamed")
    }
}

final class PRLinkTests: XCTestCase {
    func testExtractsMentionedLinks() {
        let text = #"""
        Created MR: https://gitlab.firma.de/team/backend/api/-/merge_requests/42 – see also
        https://github.com/acme/app/pull/7. Old one: https://gitlab.com/x/y/-/merge_requests/3/diffs
        Forgejo: https://codeberg.org/me/tool/pulls/5) and again https://gitlab.firma.de/team/backend/api/-/merge_requests/42
        Not a MR: https://gitlab.com/x/y/-/merge_requests/new and https://github.com/acme/app/pulls
        """#
        XCTAssertEqual(PRLinkExtractor.urls(in: text), [
            "https://github.com/acme/app/pull/7",
            "https://gitlab.com/x/y/-/merge_requests/3",
            "https://codeberg.org/me/tool/pulls/5",
            "https://gitlab.firma.de/team/backend/api/-/merge_requests/42",
        ])
    }

    func testTranscriptLinksIncrementalNewestFirst() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl").path
        try (#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"https:\/\/gitlab.com\/a\/b\/-\/merge_requests\/1"}]}}"# + "\n")
            .write(toFile: file, atomically: true, encoding: .utf8)
        let links = SessionPRLinks()
        var found = await links.links(transcript: file)
        XCTAssertEqual(found, ["https://gitlab.com/a/b/-/merge_requests/1"])
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        fh.seekToEndOfFile()
        fh.write(Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"MR !2: https://gitlab.com/a/b/-/merge_requests/2"}]}}"# + "\n").utf8))
        try fh.close()
        found = await links.links(transcript: file)
        XCTAssertEqual(found, ["https://gitlab.com/a/b/-/merge_requests/2", "https://gitlab.com/a/b/-/merge_requests/1"])
    }

    func testGitLabMRLocationAndPipelineFields() {
        let mr = PullRequestService.gitLabMR("https://gitlab.firma.de:8443/team/backend/api/-/merge_requests/42")
        XCTAssertEqual(mr?.host, "gitlab.firma.de:8443")
        XCTAssertEqual(mr?.project, "team/backend/api")
        XCTAssertEqual(mr?.iid, "42")
        XCTAssertNil(PullRequestService.gitLabMR("https://gitlab.com/a/b/-/merge_requests/new"))

        let view = #"{"state":"opened","draft":true,"title":"Add login","source_branch":"feat/login","web_url":"https://gitlab.com/a/b/-/merge_requests/42","head_pipeline":{"status":"failed","web_url":"https://gitlab.com/a/b/-/pipelines/999"}}"#
        let s = PullRequestService.parseGitLabStatus(view: view, approvals: nil, discussions: nil, fallbackUrl: "")
        XCTAssertEqual(s?.title, "Add login")
        XCTAssertEqual(s?.sourceBranch, "feat/login")
        XCTAssertEqual(s?.isDraft, true)
        XCTAssertEqual(s?.pipelineStatus, "failed")
        XCTAssertEqual(s?.pipelineUrl, "https://gitlab.com/a/b/-/pipelines/999")
        XCTAssertEqual(s?.checks, .failing)
        XCTAssertEqual(s?.reference, "!42")
    }
}
