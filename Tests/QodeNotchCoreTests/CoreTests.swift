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

    func testHookWorkingStuckOnToolBecomesWaiting() {
        let old = now.addingTimeInterval(-20)
        XCTAssertEqual(StatusClassifier.classify(.init(transcriptMtime: old, cpuPercent: 0, hasPendingToolUse: true, hookStatus: .working, hookTimestamp: old), now: now), .waiting)
        XCTAssertEqual(StatusClassifier.classify(.init(transcriptMtime: now, cpuPercent: 0, hasPendingToolUse: true, hookStatus: .working, hookTimestamp: now), now: now), .working)
    }

    func testHookIdle() {
        XCTAssertEqual(StatusClassifier.classify(.init(hookStatus: .idle), now: now), .idle)
        XCTAssertEqual(StatusClassifier.classify(.init(isAskingForInput: true, hookStatus: .idle), now: now), .waiting)
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
        XCTAssertEqual(settings["model"] as? String, "opus")

        try HookManager.uninstall()
        let after = HookManager.readSettings()!
        let hooks = after["hooks"] as! [String: Any]
        XCTAssertEqual(hooks.keys.sorted(), ["Stop"])
        XCTAssertEqual((hooks["Stop"] as! [[String: Any]]).count, 1)
        XCTAssertEqual(HookManager.state(), .notInstalled)
    }

    func testHookScriptWritesEventFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("HOME", home, 1)
        defer { unsetenv("HOME") }
        XCTAssertEqual(HookManager.install(), .installed)

        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/tmp","transcript_path":"/tmp/a.jsonl","prompt":"say \"hi\""}"#
        let r = Shell.runSync("/bin/sh", [Paths.hookScript], input: payload)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let events = HookManager.readAll()
        XCTAssertEqual(events.count, 1)
        let ev = try XCTUnwrap(events.values.first)
        XCTAssertEqual(ev.sessionId, "abc")
        XCTAssertEqual(ev.event, "UserPromptSubmit")
        XCTAssertEqual(ev.transcriptPath, "/tmp/a.jsonl")
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
