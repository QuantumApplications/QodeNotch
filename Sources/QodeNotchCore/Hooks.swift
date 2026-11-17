import Foundation

/// The last hook event a claude process reported.
public struct HookEvent: Equatable, Sendable {
    public var pid: Int32
    public var event: String
    public var sessionId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    public var timestamp: Date

    public init(pid: Int32, event: String, sessionId: String? = nil, cwd: String? = nil, transcriptPath: String? = nil,
                notificationType: String? = nil, message: String? = nil, toolName: String? = nil, timestamp: Date) {
        self.pid = pid
        self.event = event
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.timestamp = timestamp
    }

    /// Status implied by this event, or nil if the event says nothing definitive.
    public var impliedStatus: SessionStatus? {
        switch event {
        case "UserPromptSubmit", "SubagentStart", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreCompact":
            return .working
        case "Stop", "SessionStart":
            return .idle
        case "SessionEnd":
            return .finished
        case "Notification":
            let type = (notificationType ?? "").lowercased()
            let msg = (message ?? "").lowercased()
            if type == "permission_prompt" || type == "elicitation_dialog" || msg.contains("permission") || msg.contains("needs your") {
                return .waiting
            }
            if type == "idle_prompt" || msg.contains("waiting for your input") { return .idle }
            return nil
        default:
            return nil
        }
    }
}

public enum HookManager {
    /// Events QodeNotch subscribes to in `~/.claude/settings.json`.
    public static let events = [
        "SessionStart", "SessionEnd", "Stop", "UserPromptSubmit", "SubagentStart",
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "Notification", "PreCompact",
    ]

    /// Events that need a tool matcher.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure"]

    /// The hook script. It stores the raw hook payload per claude PID so the
    /// app can map processes to transcripts and statuses without polling.
    public static var script: String {
        """
        #!/bin/sh
        # QodeNotch status hook — records the latest Claude Code hook event per claude process.
        EVENTS_DIR="\(Paths.eventsDir)"
        mkdir -p "$EVENTS_DIR" 2>/dev/null
        INPUT=$(cat)
        [ -z "$INPUT" ] && exit 0

        # Find the claude process that invoked this hook (hooks may run via an
        # intermediate shell, so walk up a few levels).
        PID=$PPID
        CLAUDE_PID=""
        i=0
        while [ $i -lt 6 ] && [ -n "$PID" ] && [ "$PID" -gt 1 ] 2>/dev/null; do
          COMM=$(ps -o comm= -p "$PID" 2>/dev/null | sed 's#.*/##')
          if [ "$COMM" = "claude" ]; then CLAUDE_PID=$PID; break; fi
          PID=$(ps -o ppid= -p "$PID" 2>/dev/null | tr -d ' ')
          i=$((i+1))
        done
        [ -z "$CLAUDE_PID" ] && CLAUDE_PID=$PPID

        TS=$(date +%s)
        TMP="$EVENTS_DIR/.$CLAUDE_PID.$$.tmp"
        printf '{"pid":%s,"ts":%s,"payload":%s}\\n' "$CLAUDE_PID" "$TS" "$INPUT" > "$TMP" && mv -f "$TMP" "$EVENTS_DIR/$CLAUDE_PID.json"
        exit 0
        """
    }

    public enum InstallState: Equatable, Sendable {
        case installed
        case notInstalled
        case partial
        case error(String)
    }

    public static func state() -> InstallState {
        guard FileManager.default.isExecutableFile(atPath: Paths.hookScript) else { return .notInstalled }
        guard let settings = readSettings() else { return .notInstalled }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let registered = events.filter { isRegistered(hooks[$0]) }
        if registered.count == events.count { return .installed }
        return registered.isEmpty ? .notInstalled : .partial
    }

    static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: Paths.claudeSettingsFile) else { return [:] }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isRegistered(_ entries: Any?) -> Bool {
        guard let list = entries as? [[String: Any]] else { return false }
        return list.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == Paths.hookScript }
        }
    }

    /// Write the hook script and register it for every event (idempotent).
    @discardableResult
    public static func install() -> InstallState {
        Paths.ensureDirectory(Paths.hooksDir)
        Paths.ensureDirectory(Paths.eventsDir)
        do {
            try script.write(toFile: Paths.hookScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hookScript)
        } catch {
            return .error("Hook-Skript konnte nicht geschrieben werden: \(error.localizedDescription)")
        }

        guard var settings = readSettings() else {
            return .error("~/.claude/settings.json ist kein gültiges JSON – Hooks wurden nicht eingetragen.")
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events where !isRegistered(hooks[event]) {
            var list = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": Paths.hookScript, "timeout": 5]],
            ]
            if toolEvents.contains(event) { entry["matcher"] = "*" }
            list.append(entry)
            hooks[event] = list
            changed = true
        }
        if changed {
            settings["hooks"] = hooks
            do {
                try writeSettings(settings)
            } catch {
                return .error("~/.claude/settings.json konnte nicht geschrieben werden: \(error.localizedDescription)")
            }
        }
        return .installed
    }

    /// Remove QodeNotch's hook entries (other hooks stay untouched).
    public static func uninstall() throws {
        guard var settings = readSettings() else { return }
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard var list = value as? [[String: Any]] else { continue }
            list = list.compactMap { entry in
                var e = entry
                let remaining = (entry["hooks"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String) != Paths.hookScript }
                if remaining.isEmpty { return nil }
                e["hooks"] = remaining
                return e
            }
            if list.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = list }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try writeSettings(settings)
        try? FileManager.default.removeItem(atPath: Paths.hookScript)
    }

    static func writeSettings(_ settings: [String: Any]) throws {
        Paths.ensureDirectory(Paths.claudeDir)
        // Keep a one-time backup of the user's original settings.
        let backup = Paths.claudeSettingsFile + ".qodenotch-backup"
        if FileManager.default.fileExists(atPath: Paths.claudeSettingsFile), !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: Paths.claudeSettingsFile, toPath: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: Paths.claudeSettingsFile), options: .atomic)
    }

    // MARK: Reading events

    /// Parse one event file written by the hook script.
    public static func parseEventFile(_ data: Data, fallbackPid: Int32?) -> HookEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? obj
        guard let event = (payload["hook_event_name"] as? String) ?? (obj["event"] as? String) else { return nil }
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? fallbackPid
        guard let pid else { return nil }
        let ts = (obj["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        return HookEvent(
            pid: pid,
            event: event,
            sessionId: nonEmpty(payload["session_id"] as? String),
            cwd: nonEmpty(payload["cwd"] as? String),
            transcriptPath: nonEmpty(payload["transcript_path"] as? String),
            notificationType: nonEmpty(payload["notification_type"] as? String),
            message: nonEmpty(payload["message"] as? String),
            toolName: nonEmpty(payload["tool_name"] as? String),
            timestamp: Date(timeIntervalSince1970: ts)
        )
    }

    /// Read all event files; removes files older than 24h.
    public static func readAll(now: Date = Date()) -> [Int32: HookEvent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Paths.eventsDir) else { return [:] }
        var result: [Int32: HookEvent] = [:]
        for name in entries where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = Paths.eventsDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 24 * 3600 {
                try? fm.removeItem(atPath: path)
                continue
            }
            guard let data = fm.contents(atPath: path) else { continue }
            let pid = Int32(name.dropLast(5))
            if let ev = parseEventFile(data, fallbackPid: pid) { result[ev.pid] = ev }
        }
        return result
    }

    /// Delete event files for PIDs that no longer exist.
    public static func pruneDead(alive: Set<Int32>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: Paths.eventsDir) else { return }
        for name in entries where name.hasSuffix(".json") {
            if let pid = Int32(name.dropLast(5)), !alive.contains(pid), !ProcessScanner.isAlive(pid) {
                try? FileManager.default.removeItem(atPath: Paths.eventsDir + "/" + name)
            }
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
