import Foundation

/// One parsed line of a Claude Code JSONL transcript.
public struct TranscriptLine {
    public var type: String
    public var sessionId: String?
    public var cwd: String?
    /// Text of a `{"type":"summary"}` line (session title written by Claude Code).
    public var summary: String?
    public var gitBranch: String?
    public var timestamp: String?
    public var role: String?
    public var stopReason: String?
    /// `message.content` as either a String or an array of blocks.
    public var content: Any?
    public var isMeta: Bool

    public init(json: [String: Any]) {
        type = json["type"] as? String ?? ""
        sessionId = json["sessionId"] as? String
        cwd = json["cwd"] as? String
        summary = json["summary"] as? String
        gitBranch = json["gitBranch"] as? String
        timestamp = json["timestamp"] as? String
        isMeta = json["isMeta"] as? Bool ?? false
        let message = json["message"] as? [String: Any]
        role = message?["role"] as? String
        stopReason = message?["stop_reason"] as? String
        content = message?["content"]
    }

    var hasMessage: Bool { content != nil }
    var blocks: [[String: Any]]? { content as? [[String: Any]] }
    var isNoise: Bool { type == "progress" || type == "file-history-snapshot" || type == "system" || type == "summary" }
}

public enum TranscriptReader {
    public static let tailLines = 60
    public static let headLines = 30
    public static let previewMaxLength = 240
    public static let taskTitleMaxLength = 120
    public static let taskDescriptionMaxLength = 300

    // MARK: File access

    public static func parse(_ text: String) -> [TranscriptLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return TranscriptLine(json: obj)
        }
    }

    public static func readTail(_ path: String, lines: Int = tailLines) -> [TranscriptLine] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk = UInt64(lines * 10_240)
        let offset = size > chunk ? size - chunk : 0
        try? fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return Array(parse(text).suffix(lines))
    }

    public static func readHead(_ path: String, lines: Int = headLines) -> [TranscriptLine] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: lines * 4096)
        var text = String(decoding: data, as: UTF8.self)
        // Drop a trailing partial line.
        if data.count == lines * 4096, let nl = text.lastIndex(of: "\n") { text = String(text[..<nl]) }
        return Array(parse(text).prefix(lines))
    }

    public static func readAll(_ path: String) -> [TranscriptLine] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Newest `.jsonl` in a project directory, skipping already-claimed paths.
    public static func latestTranscript(in projectDir: String, excluding: Set<String> = []) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectDir) else { return nil }
        var best: (String, Date)?
        for e in entries where e.hasSuffix(".jsonl") {
            let p = projectDir + "/" + e
            if excluding.contains(p) { continue }
            guard let m = mtime(p) else { continue }
            if best == nil || m > best!.1 { best = (p, m) }
        }
        return best?.0
    }

    // MARK: Extraction

    public static func sessionId(_ lines: [TranscriptLine]) -> String? {
        lines.first { $0.sessionId != nil }?.sessionId
    }

    public static func startedAt(_ lines: [TranscriptLine]) -> Date? {
        lines.lazy.compactMap { $0.timestamp }.first.flatMap(parseDate)
    }

    public static func branch(_ lines: [TranscriptLine]) -> String? {
        lines.last { ($0.gitBranch ?? "").isEmpty == false }?.gitBranch
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Text typed by the user (content string or text blocks). nil for tool_result-only turns.
    static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    static func isSystemInjected(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "<", t.count > 1 else { return false }
        let second = t[t.index(after: t.startIndex)]
        return second.isLetter
    }

    /// Strip XML-ish tags (and paired tag content) injected by Claude Code.
    static func stripTags(_ text: String) -> String? {
        var s = text
        if let paired = try? NSRegularExpression(pattern: "<([a-zA-Z][a-zA-Z0-9-]*)(?:\\s[^>]*)?>[\\s\\S]*?</\\1>") {
            s = paired.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let any = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = any.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Risky-looking Bash commands.
    public static func commandWarnings(tool: String, input: [String: Any]?) -> [String] {
        guard tool == "Bash", let cmd = input?["command"] as? String else { return [] }
        var w: [String] = []
        func has(_ pattern: String) -> Bool { cmd.range(of: pattern, options: .regularExpression) != nil }
        if has("\\$\\(") { w.append("Befehlssubstitution $()") }
        if has("`[^`]+`") { w.append("Backtick-Substitution") }
        if has("\\|\\s*(sudo|bash|sh|zsh)\\b") { w.append("Pipe in eine Shell") }
        if has("\\brm\\s+-\\w*[rf]") { w.append("Rekursives/erzwungenes Löschen") }
        if has("\\bsudo\\b") { w.append("Läuft mit Root-Rechten") }
        if has("--force|--hard|\\bpush\\s+-f\\b") { w.append("Force/Hard-Flag") }
        if has("\\beval\\b") { w.append("Verwendet eval") }
        return w
    }

    public static func summarizeToolInput(tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "Bash": return str("command").map { truncate($0, previewMaxLength) }
        case "Edit", "MultiEdit", "Read", "Write", "NotebookEdit": return str("file_path") ?? str("notebook_path")
        case "Glob": return str("pattern")
        case "Grep": return str("pattern").map { "/\($0)/" }
        case "Skill": return str("skill")
        case "WebFetch": return str("url")
        case "WebSearch": return str("query")
        case "Agent", "Task": return str("description") ?? str("prompt").map { truncate($0, previewMaxLength) }
        default:
            for (_, v) in input.sorted(by: { $0.key < $1.key }) {
                if let s = v as? String, !s.isEmpty, s.count <= previewMaxLength { return s }
            }
            return nil
        }
    }

    public static func preview(_ lines: [TranscriptLine]) -> ConversationPreview {
        var p = ConversationPreview()
        for line in lines where !line.isNoise && line.hasMessage {
            if line.type == "user" {
                guard let raw = userText(line.content) else { continue }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if text == "/clear" || text.contains("<command-name>/clear</command-name>") {
                    p = ConversationPreview()
                    continue
                }
                if isSystemInjected(text) {
                    if let cleaned = stripTags(text) {
                        p.lastUserMessage = truncate(cleaned, previewMaxLength)
                        p.assistantIsNewer = false
                        p.messageCount += 1
                    }
                    continue
                }
                p.lastUserMessage = truncate(text, previewMaxLength)
                p.assistantIsNewer = false
                p.messageCount += 1
            } else if line.type == "assistant", let blocks = line.blocks {
                p.messageCount += 1
                var tools: [ToolInfo] = []
                for b in blocks {
                    let type = b["type"] as? String
                    if type == "text", let t = b["text"] as? String, !t.isEmpty {
                        p.lastAssistantText = truncate(t.trimmingCharacters(in: .whitespacesAndNewlines), previewMaxLength)
                    }
                    if type == "tool_use", let name = b["name"] as? String {
                        let input = b["input"] as? [String: Any]
                        tools.append(ToolInfo(name: name, input: summarizeToolInput(tool: name, input: input),
                                              description: input?["description"] as? String,
                                              warnings: commandWarnings(tool: name, input: input)))
                    }
                }
                p.lastTools = tools
                p.assistantIsNewer = true
            }
        }
        return p
    }

    /// Last meaningful message is an assistant error.
    public static func lastMessageHasError(_ lines: [TranscriptLine]) -> Bool {
        for line in lines.reversed() where !line.isNoise && line.hasMessage {
            if line.type == "assistant", let blocks = line.blocks {
                for b in blocks where (b["type"] as? String) == "text" {
                    let lower = (b["text"] as? String ?? "").lowercased()
                    if lower.hasPrefix("api error") { return true }
                    if lower.contains("error") && lower.contains("failed") && lower.count < 400 { return true }
                }
            }
            return false
        }
        return false
    }

    /// The last assistant turn issued tool_use and no tool_result came back yet.
    public static func hasPendingToolUse(_ lines: [TranscriptLine]) -> Bool {
        for line in lines.reversed() where !line.isNoise && line.hasMessage {
            if line.type == "assistant", let blocks = line.blocks {
                return blocks.contains { ($0["type"] as? String) == "tool_use" }
            }
            return false
        }
        return false
    }

    /// Claude's last message is a genuine mid-task question.
    public static func isAskingForInput(_ lines: [TranscriptLine]) -> Bool {
        var lastAssistant: TranscriptLine?
        var assistantTurns = 0
        var toolUseInSession = false
        for line in lines.reversed() where !line.isNoise {
            if line.type == "assistant", let blocks = line.blocks {
                assistantTurns += 1
                if lastAssistant == nil { lastAssistant = line }
                if blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) { toolUseInSession = true }
            }
            if line.type == "user", lastAssistant == nil, userText(line.content) != nil || line.blocks != nil { return false }
        }
        guard let last = lastAssistant, let blocks = last.blocks else { return false }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_use" }) { return false }
        guard last.stopReason == "end_turn" else { return false }
        if assistantTurns <= 1 && !toolUseInSession { return false }

        let full = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !full.isEmpty else { return false }
        let lower = full.lowercased()
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)

        let greetings = [
            "^(hey|hi|hello|hallo)[\\s!.,]*(what|how) can i (help|assist)",
            "what (can|would you like me to|shall) i help.*with",
            "how can i (help|assist) you",
        ]
        for g in greetings where trimmed.range(of: g, options: [.regularExpression, .caseInsensitive]) != nil { return false }

        let phrases = [
            "shall i proceed", "should i proceed", "shall i go ahead", "should i go ahead", "would you like me to",
            "please confirm", "which approach", "which option", "do you want me to", "is that okay",
            "does that look right", "soll ich", "möchtest du", "willst du", "bitte bestätige", "welche option",
        ]
        if phrases.contains(where: lower.contains) { return true }
        if lower.contains("before i ") && full.contains("?") { return true }
        if lower.contains("let me know") && (lower.contains("prefer") || lower.contains("choose") || lower.contains("decision")) { return true }
        return false
    }

    /// Task summary from a Linear issue in early tool results, else the first prompt.
    public static func taskSummary(_ head: [TranscriptLine]) -> TaskSummary? {
        for line in head where line.type == "user" {
            for block in line.blocks ?? [] where (block["type"] as? String) == "tool_result" {
                for inner in block["content"] as? [[String: Any]] ?? [] where (inner["type"] as? String) == "text" {
                    guard let text = inner["text"] as? String, let data = text.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let title = obj["title"] as? String,
                          let ident = (obj["identifier"] as? String) ?? (obj["id"] as? String) else { continue }
                    var desc = obj["description"] as? String
                    if var d = desc {
                        d = d.replacingOccurrences(of: "\\n", with: "\n")
                        d = d.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " *")) }
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                        desc = truncate(d, taskDescriptionMaxLength)
                    }
                    return TaskSummary(title: title, description: desc, source: .linear, ticketId: ident, ticketUrl: obj["url"] as? String)
                }
            }
        }
        for line in head where line.type == "user" && !line.isMeta {
            guard var text = userText(line.content)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if isSystemInjected(text) {
                guard let cleaned = stripTags(text) else { continue }
                text = cleaned
            }
            if text.count < 100, text.range(of: "^(implement|start|work on|fix|do)\\s+(the\\s+)?(linear|referenced|ticket)", options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            let parts = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = parts.first else { continue }
            let title = truncate(first.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression), taskTitleMaxLength)
            let desc = parts.count > 1 ? truncate(parts.dropFirst().joined(separator: " "), taskDescriptionMaxLength) : nil
            return TaskSummary(title: title, description: desc, source: .prompt)
        }
        return nil
    }

    /// Full conversation for the detail view.
    public static func conversation(_ lines: [TranscriptLine]) -> [ConversationMessage] {
        var out: [ConversationMessage] = []
        for line in lines where !line.isNoise && line.hasMessage && !line.isMeta {
            if line.type == "user" {
                guard let text = userText(line.content) else { continue }
                if isSystemInjected(text) { continue }
                out.append(ConversationMessage(id: out.count, role: .user, timestamp: line.timestamp.flatMap(parseDate), text: text, toolUses: []))
            } else if line.type == "assistant", let blocks = line.blocks {
                var text: String?
                var tools: [ConversationMessage.ToolUse] = []
                for b in blocks {
                    let type = b["type"] as? String
                    if type == "text", let t = b["text"] as? String, !t.isEmpty { text = text.map { $0 + "\n" + t } ?? t }
                    if type == "tool_use", let name = b["name"] as? String {
                        tools.append(.init(name: name, summary: summarizeToolInput(tool: name, input: b["input"] as? [String: Any])))
                    }
                }
                if text == nil && tools.isEmpty { continue }
                // Merge consecutive assistant chunks of the same turn.
                if let last = out.last, last.role == .assistant, text == nil {
                    out[out.count - 1].toolUses.append(contentsOf: tools)
                    continue
                }
                out.append(ConversationMessage(id: out.count, role: .assistant, timestamp: line.timestamp.flatMap(parseDate), text: text, toolUses: tools))
            }
        }
        return out
    }
}
