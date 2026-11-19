import Foundation

/// Translates Codex rollout lines and Copilot CLI events into Claude Code's
/// transcript shape, so preview, tool display, model and token counting work
/// the same for every agent. Stateful: the current model carries over lines.
struct ForeignTranscriptConverter {
    private var model: String?
    private var sessionId: String?
    private var cwd: String?

    static let codexTypes: Set<String> = ["session_meta", "response_item", "event_msg", "turn_context", "compacted"]

    /// Claude-shaped JSON objects, or nil if `obj` is already a Claude line.
    mutating func convert(_ obj: [String: Any]) -> [[String: Any]]? {
        guard let type = obj["type"] as? String else { return nil }
        if Self.codexTypes.contains(type), let payload = obj["payload"] as? [String: Any] {
            return codex(type: type, payload: payload, timestamp: obj["timestamp"] as? String)
        }
        if type.contains("."), let data = obj["data"] as? [String: Any] {
            return copilot(type: type, data: data, timestamp: (obj["timestamp"] as? String) ?? (data["timestamp"] as? String))
        }
        return nil
    }

    private func base(_ type: String, _ ts: String?) -> [String: Any] {
        var d: [String: Any] = ["type": type]
        if let ts { d["timestamp"] = ts }
        if let sessionId { d["sessionId"] = sessionId }
        if let cwd { d["cwd"] = cwd }
        return d
    }

    private func user(_ content: Any, _ ts: String?) -> [String: Any] {
        var d = base("user", ts)
        d["message"] = ["role": "user", "content": content]
        return d
    }

    private func assistant(_ blocks: [[String: Any]], _ ts: String?, id: String? = nil, usage: [String: Any]? = nil) -> [String: Any] {
        var d = base("assistant", ts)
        // Usage-only lines carry no content, so they don't count as messages.
        var message: [String: Any] = ["role": "assistant"]
        if !blocks.isEmpty { message["content"] = blocks }
        if let model { message["model"] = model }
        if let id { message["id"] = id }
        if let usage { message["usage"] = usage }
        d["message"] = message
        return d
    }

    /// Shell-like tools become "Bash" so command preview and warnings apply.
    static func toolUse(name: String, arguments: Any?) -> [String: Any] {
        var input: [String: Any] = [:]
        if let s = arguments as? String, let data = s.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            input = parsed
        } else if let dict = arguments as? [String: Any] {
            input = dict
        } else if let s = arguments as? String {
            input = ["input": s]
        }
        let lower = name.lowercased()
        if ["shell", "local_shell", "exec_command", "bash", "container.exec", "shell_command"].contains(lower) {
            if let cmd = input["command"] as? [String] {
                let joined = (cmd.count >= 3 && ["bash", "sh", "zsh"].contains(cmd[0]) && cmd[1].hasPrefix("-")) ? cmd[2] : cmd.joined(separator: " ")
                input["command"] = joined
            } else if let cmd = input["cmd"] as? String {
                input["command"] = cmd
            }
            return ["type": "tool_use", "name": "Bash", "input": input]
        }
        if lower == "apply_patch" { return ["type": "tool_use", "name": "Edit", "input": input] }
        if lower == "view" || lower == "read_file" { return ["type": "tool_use", "name": "Read", "input": input] }
        return ["type": "tool_use", "name": name, "input": input]
    }

    // MARK: Codex (~/.codex/sessions/…/rollout-*.jsonl)

    private mutating func codex(type: String, payload: [String: Any], timestamp ts: String?) -> [[String: Any]] {
        switch type {
        case "session_meta":
            sessionId = payload["id"] as? String ?? sessionId
            cwd = payload["cwd"] as? String ?? cwd
            if let m = payload["model"] as? String { model = m }
            var d = base("system", ts ?? payload["timestamp"] as? String)
            if let branch = (payload["git"] as? [String: Any])?["branch"] as? String { d["gitBranch"] = branch }
            return [d]
        case "turn_context":
            if let m = payload["model"] as? String { model = m }
            if let c = payload["cwd"] as? String { cwd = c }
            return []
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                guard let msg = payload["message"] as? String, !msg.isEmpty else { return [] }
                return [user(msg, ts)]
            case "agent_message":
                guard let msg = payload["message"] as? String, !msg.isEmpty else { return [] }
                var d = assistant([["type": "text", "text": msg]], ts)
                if var m = d["message"] as? [String: Any] { m["stop_reason"] = "end_turn"; d["message"] = m }
                return [d]
            case "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else { return [] }
                func n(_ k: String) -> Int { (last[k] as? NSNumber)?.intValue ?? 0 }
                let cached = n("cached_input_tokens")
                let usage: [String: Any] = [
                    "input_tokens": max(0, n("input_tokens") - cached),
                    "cache_read_input_tokens": cached,
                    "output_tokens": n("output_tokens"),
                ]
                return [assistant([], ts, id: "codex-usage-" + (ts ?? UUID().uuidString), usage: usage)]
            case "error", "stream_error":
                let msg = payload["message"] as? String ?? "Fehler"
                return [assistant([["type": "text", "text": "API Error: " + msg]], ts)]
            default:
                return []
            }
        case "response_item":
            switch payload["type"] as? String {
            case "function_call", "custom_tool_call", "local_shell_call":
                let name = payload["name"] as? String ?? (payload["type"] as? String == "local_shell_call" ? "shell" : "tool")
                let args = payload["arguments"] ?? payload["input"] ?? payload["action"]
                return [assistant([Self.toolUse(name: name, arguments: args)], ts)]
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                return [user([["type": "tool_result", "content": ""]], ts)]
            default:
                return []
            }
        default:
            return []
        }
    }

    // MARK: Copilot CLI (~/.copilot/session-state/<id>/events.jsonl)

    private mutating func copilot(type: String, data: [String: Any], timestamp ts: String?) -> [[String: Any]] {
        if let m = (data["currentModel"] as? String) ?? (data["model"] as? String) ?? (data["newModel"] as? String), !m.isEmpty {
            model = m
        }
        switch type {
        case "session.start", "session.resume":
            if let ctx = data["context"] as? [String: Any], let c = ctx["cwd"] as? String { cwd = c }
            if let id = data["sessionId"] as? String { sessionId = id }
            var d = base("system", ts)
            if let branch = (data["context"] as? [String: Any])?["branch"] as? String { d["gitBranch"] = branch }
            return [d]
        case "user.message":
            guard let text = data["content"] as? String, !text.isEmpty else { return [] }
            return [user(text, ts)]
        case "assistant.message":
            guard let text = data["content"] as? String, !text.isEmpty else { return [] }
            var d = assistant([["type": "text", "text": text]], ts)
            if var m = d["message"] as? [String: Any] { m["stop_reason"] = "end_turn"; d["message"] = m }
            return [d]
        case "tool.execution_start":
            let name = data["toolName"] as? String ?? "tool"
            return [assistant([Self.toolUse(name: name, arguments: data["arguments"])], ts)]
        case "tool.execution_complete":
            return [user([["type": "tool_result", "content": ""]], ts)]
        case "assistant.usage":
            func n(_ k: String) -> Int { (data[k] as? NSNumber)?.intValue ?? 0 }
            let usage: [String: Any] = [
                "input_tokens": n("inputTokens"), "output_tokens": n("outputTokens"),
                "cache_read_input_tokens": n("cacheReadTokens"), "cache_creation_input_tokens": n("cacheWriteTokens"),
            ]
            return [assistant([], ts, id: "copilot-usage-" + (ts ?? UUID().uuidString), usage: usage)]
        case "session.error":
            return [assistant([["type": "text", "text": "API Error: " + (data["message"] as? String ?? "Fehler")]], ts)]
        default:
            return []
        }
    }
}

// MARK: - Codex & Copilot session stores

public enum AgentStores {
    public static var codexSessionsDir: String { AgentHooks.codexHome + "/sessions" }
    public static var copilotSessionsDir: String { AgentHooks.copilotHome + "/session-state" }

    /// Rollout files of the last `days` days (Codex stores them per date).
    public static func codexRollouts(days: Int = 14, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let cal = Calendar.current
        var files: [String] = []
        for i in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/%04d/%02d/%02d", codexSessionsDir, c.year ?? 0, c.month ?? 0, c.day ?? 0)
            for e in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where e.hasSuffix(".jsonl") {
                files.append(dir + "/" + e)
            }
        }
        return files
    }

    public static func copilotEventFiles() -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: copilotSessionsDir)) ?? []).compactMap { dir in
            let p = copilotSessionsDir + "/" + dir + "/events.jsonl"
            return fm.fileExists(atPath: p) ? p : nil
        }
    }

    /// Working directory recorded at the top of a Codex/Copilot transcript.
    public static func recordedCwd(_ path: String) -> String? {
        TranscriptReader.readHead(path, lines: 8).lazy.compactMap(\.cwd).first
    }

    /// Newest transcript of `agent` for a working directory, modified after `since`.
    public static func latestTranscript(agent: Agent, cwd: String, since: Date? = nil, excluding: Set<String> = []) -> String? {
        let files: [String]
        switch agent {
        case .claude: return TranscriptReader.latestTranscript(in: Paths.projectDir(for: cwd), excluding: excluding)
        case .codex: files = codexRollouts(days: 3)
        case .copilot: files = copilotEventFiles()
        }
        let candidates = files.compactMap { p -> (String, Date)? in
            guard !excluding.contains(p), let m = TranscriptReader.mtime(p) else { return nil }
            if let since, m < since.addingTimeInterval(-60) { return nil }
            return (p, m)
        }.sorted { $0.1 > $1.1 }
        for (p, _) in candidates.prefix(40) where recordedCwd(p) == cwd { return p }
        return nil
    }

    /// Codex' own rate limits (ChatGPT plan), from the newest `token_count` event.
    public static func codexLimits() -> UsageLimits? {
        let files = codexRollouts(days: 7).compactMap { p in TranscriptReader.mtime(p).map { (p, $0) } }.sorted { $0.1 > $1.1 }
        for (path, mtime) in files.prefix(5) {
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            let text = String(decoding: fh.readDataToEndOfFile(), as: UTF8.self)
            for raw in text.split(separator: "\n").reversed() where raw.contains("rate_limits") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                if let l = parseCodexRateLimits(rl, observedAt: mtime) { return l }
            }
        }
        return nil
    }

    static func parseCodexRateLimits(_ rl: [String: Any], observedAt: Date) -> UsageLimits? {
        var limits: [UsageLimit] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let pct = UsageLimits.number(w["used_percent"]) else { continue }
            let minutes = UsageLimits.number(w["window_minutes"]) ?? 0
            var reset: Date?
            if let at = UsageLimits.number(w["resets_at"]) { reset = Date(timeIntervalSince1970: at) }
            else if let secs = UsageLimits.number(w["resets_in_seconds"]) { reset = observedAt.addingTimeInterval(secs) }
            let kind: UsageLimit.Kind = minutes > 0 && minutes <= 24 * 60 ? .session : .weekly
            var l = UsageLimit(kind: kind, percent: pct, resetsAt: reset, modelLabel: nil)
            if minutes > 0 && minutes != 300 && minutes != 10080 {
                l.modelLabel = minutes < 120 ? "\(Int(minutes)) min" : "\(Int(minutes / 60)) h"
            }
            limits.append(l)
        }
        guard !limits.isEmpty else { return nil }
        return UsageLimits(limits: limits, fetchedAt: observedAt, plan: rl["plan_type"] as? String)
    }
}
