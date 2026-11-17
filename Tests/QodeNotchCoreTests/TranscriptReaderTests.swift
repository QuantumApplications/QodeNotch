import XCTest
@testable import QodeNotchCore

final class TranscriptReaderTests: XCTestCase {
    private func lines(_ jsonl: String) -> [TranscriptLine] { TranscriptReader.parse(jsonl) }

    private let toolUseTurn = #"""
    {"type":"user","sessionId":"abc","timestamp":"2026-01-01T10:00:00.000Z","gitBranch":"feat/x","message":{"role":"user","content":"Fix the login bug\nIt crashes on submit"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Let me look."},{"type":"tool_use","name":"Bash","input":{"command":"rm -rf build && sudo make","description":"Rebuild"}}]}}
    """#

    func testSessionIdBranchAndStart() {
        let l = lines(toolUseTurn)
        XCTAssertEqual(TranscriptReader.sessionId(l), "abc")
        XCTAssertEqual(TranscriptReader.branch(l), "feat/x")
        XCTAssertNotNil(TranscriptReader.startedAt(l))
    }

    func testPreviewWithToolsAndWarnings() {
        let p = TranscriptReader.preview(lines(toolUseTurn))
        XCTAssertEqual(p.lastUserMessage, "Fix the login bug\nIt crashes on submit")
        XCTAssertEqual(p.lastAssistantText, "Let me look.")
        XCTAssertTrue(p.assistantIsNewer)
        XCTAssertEqual(p.lastTools.count, 1)
        XCTAssertEqual(p.lastTools[0].name, "Bash")
        XCTAssertEqual(p.lastTools[0].description, "Rebuild")
        XCTAssertTrue(p.lastTools[0].warnings.contains("Läuft mit Root-Rechten"))
        XCTAssertTrue(p.lastTools[0].warnings.contains("Rekursives/erzwungenes Löschen"))
        XCTAssertEqual(p.messageCount, 2)
    }

    func testPendingToolUse() {
        XCTAssertTrue(TranscriptReader.hasPendingToolUse(lines(toolUseTurn)))
        let resolved = toolUseTurn + "\n" + #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"1","content":"ok"}]}}"#
        XCTAssertFalse(TranscriptReader.hasPendingToolUse(lines(resolved)))
    }

    func testClearResetsPreview() {
        let text = toolUseTurn + "\n" + #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
        let p = TranscriptReader.preview(lines(text))
        XCTAssertNil(p.lastUserMessage)
        XCTAssertNil(p.lastAssistantText)
        XCTAssertEqual(p.messageCount, 0)
    }

    func testSystemInjectedMessagesAreStripped() {
        let text = #"{"type":"user","message":{"role":"user","content":"<system-reminder>ignore</system-reminder>Real question"}}"#
        XCTAssertEqual(TranscriptReader.preview(lines(text)).lastUserMessage, "Real question")
        let pure = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>x</local-command-stdout>"}}"#
        XCTAssertNil(TranscriptReader.preview(lines(pure)).lastUserMessage)
    }

    func testAskingForInput() {
        let asking = toolUseTurn + "\n" + #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"done"}]}}
        {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"I found two fixes. Which approach do you prefer?"}]}}
        """#
        XCTAssertTrue(TranscriptReader.isAskingForInput(lines(asking)))

        let greeting = #"""
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Hello! How can I help you today?"}]}}
        """#
        XCTAssertFalse(TranscriptReader.isAskingForInput(lines(greeting)))
    }

    func testTaskSummaryFromPrompt() {
        let s = TranscriptReader.taskSummary(lines(toolUseTurn))
        XCTAssertEqual(s?.title, "Fix the login bug")
        XCTAssertEqual(s?.description, "It crashes on submit")
        XCTAssertEqual(s?.source, .prompt)
    }

    func testTaskSummaryFromLinear() {
        let text = #"""
        {"type":"user","message":{"role":"user","content":"Implement the linear ticket"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"{\"id\":\"1\",\"identifier\":\"ENG-42\",\"title\":\"Add dark mode\",\"description\":\"* one\\n* two\",\"url\":\"https://linear.app/x/ENG-42\"}"}]}]}}
        """#
        let s = TranscriptReader.taskSummary(lines(text))
        XCTAssertEqual(s?.title, "Add dark mode")
        XCTAssertEqual(s?.ticketId, "ENG-42")
        XCTAssertEqual(s?.source, .linear)
        XCTAssertEqual(s?.description, "one · two")
    }

    func testErrorDetection() {
        let text = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"API Error: 529 overloaded"}]}}"#
        XCTAssertTrue(TranscriptReader.lastMessageHasError(lines(text)))
        XCTAssertFalse(TranscriptReader.lastMessageHasError(lines(toolUseTurn)))
    }

    func testConversationMergesToolOnlyChunks() {
        let text = toolUseTurn + "\n" + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.swift"}}]}}"#
        let conv = TranscriptReader.conversation(lines(text))
        XCTAssertEqual(conv.count, 2)
        XCTAssertEqual(conv[1].toolUses.map(\.name), ["Bash", "Read"])
        XCTAssertEqual(conv[1].toolUses[1].summary, "/a.swift")
    }

    func testTailReadsLastLinesFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        var content = ""
        for i in 0..<200 { content += #"{"type":"user","sessionId":"s\#(i)","message":{"role":"user","content":"msg \#(i)"}}"# + "\n" }
        try content.write(to: file, atomically: true, encoding: .utf8)
        let tail = TranscriptReader.readTail(file.path, lines: 5)
        XCTAssertEqual(tail.count, 5)
        XCTAssertEqual(tail.last?.sessionId, "s199")
        XCTAssertEqual(TranscriptReader.readHead(file.path, lines: 3).first?.sessionId, "s0")
        XCTAssertEqual(TranscriptReader.latestTranscript(in: dir.path), file.path)
        XCTAssertNil(TranscriptReader.latestTranscript(in: dir.path, excluding: [file.path]))
    }
}
