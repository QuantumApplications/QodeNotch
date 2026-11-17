import Foundation

/// The last hook event a claude process reported.
public struct HookEvent: Equatable, Sendable {
    /// Host PID of the claude process (nil when Claude runs inside a container).
    public var pid: Int32?
    /// Container hostname when the event came from a containerized Claude (airlock, devcontainer …).
    public var container: String?
    public var event: String
    public var sessionId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    public var timestamp: Date

    public init(pid: Int32?, container: String? = nil, event: String, sessionId: String? = nil, cwd: String? = nil,
                transcriptPath: String? = nil, notificationType: String? = nil, message: String? = nil,
                toolName: String? = nil, timestamp: Date) {
        self.pid = pid
        self.container = container
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

/// All hook events currently on disk.
public struct HookSnapshot: Sendable {
    public var byPid: [Int32: HookEvent] = [:]
    /// Events from containerized sessions, matched to host processes by working directory.
    public var containerEvents: [HookEvent] = []

    public init(byPid: [Int32: HookEvent] = [:], containerEvents: [HookEvent] = []) {
        self.byPid = byPid
        self.containerEvents = containerEvents
    }

    /// Newest container event for a working directory.
    public func containerEvent(cwd: String) -> HookEvent? {
        containerEvents.filter { $0.cwd == cwd }.max { $0.timestamp < $1.timestamp }
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

    /// Command registered in settings.json. Uses `$HOME` so it resolves both on
    /// the Mac and inside containers that mount `~/.claude` (airlock mounts it at
    /// /home/claude/.claude). Never fails, so a missing script can't break Claude.
    public static let command = #"f="$HOME/.claude/qodenotch/status-hook.sh"; [ -f "$f" ] && sh "$f"; exit 0"#

    /// Recognizes our own entries, including those written by earlier versions.
    static func isOurs(_ cmd: String) -> Bool {
        cmd == command || cmd.contains("qodenotch/status-hook.sh") || cmd.contains(".qodenotch/hooks/status-hook.sh")
    }

    /// The hook script. It stores the raw hook payload so the app can map
    /// processes to transcripts and statuses without polling Claude itself.
    public static let script = #"""
    #!/bin/sh
    # QodeNotch status hook — records the latest Claude Code hook event.
    # Lives in ~/.claude/qodenotch so it also works when Claude runs in a container
    # that mounts ~/.claude (e.g. airlock); events are written next to it.
    DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    [ -z "$DIR" ] && exit 0
    EVENTS_DIR="$DIR/events"
    mkdir -p "$EVENTS_DIR" 2>/dev/null || exit 0
    INPUT=$(cat)
    [ -z "$INPUT" ] && exit 0
    TS=$(date +%s)

    IN_CONTAINER=0
    if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then IN_CONTAINER=1; fi
    [ -n "${QODENOTCH_IN_CONTAINER:-}" ] && IN_CONTAINER=$QODENOTCH_IN_CONTAINER
    if [ "$IN_CONTAINER" = 1 ]; then
      # Inside a container: PIDs mean nothing on the host, key by session id.
      SID=$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/' | tr -cd 'A-Za-z0-9_-')
      [ -z "$SID" ] && exit 0
      HOST=$(cat /etc/hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-')
      KEY="c-$SID"
      PIDJSON=null
    else
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
      HOST=""
      KEY="$CLAUDE_PID"
      PIDJSON="$CLAUDE_PID"
    fi

    TMP="$EVENTS_DIR/.$KEY.$$.tmp"
    printf '{"pid":%s,"container":"%s","ts":%s,"payload":%s}\n' "$PIDJSON" "$HOST" "$TS" "$INPUT" > "$TMP" && mv -f "$TMP" "$EVENTS_DIR/$KEY.json"
    exit 0
    """#

    public enum InstallState: Equatable, Sendable {
        case installed
        case notInstalled
        case partial
        case error(String)
    }

    public static func state() -> InstallState {
        guard FileManager.default.fileExists(atPath: Paths.hookScript) else { return .notInstalled }
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
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
        }
    }

    /// Remove our entries (current and legacy) from a hooks dictionary.
    static func strippingOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = list.compactMap { entry in
                var e = entry
                let all = entry["hooks"] as? [[String: Any]] ?? []
                let remaining = all.filter { !isOurs($0["command"] as? String ?? "") }
                if remaining.count == all.count { return entry }
                if remaining.isEmpty { return nil }
                e["hooks"] = remaining
                return e
            }
            if cleaned.isEmpty { result.removeValue(forKey: event) } else { result[event] = cleaned }
        }
        return result
    }

    /// Write the hook script and register it for every event (idempotent,
    /// migrates entries from earlier versions).
    @discardableResult
    public static func install() -> InstallState {
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
        let original = settings["hooks"] as? [String: Any] ?? [:]
        let needsUpdate = events.contains { !isRegistered(original[$0]) } || hasLegacy(original)
        if needsUpdate {
            var hooks = strippingOurs(original)
            for event in events {
                var list = hooks[event] as? [[String: Any]] ?? []
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
                if toolEvents.contains(event) { entry["matcher"] = "*" }
                list.append(entry)
                hooks[event] = list
            }
            settings["hooks"] = hooks
            do {
                try writeSettings(settings)
            } catch {
                return .error("~/.claude/settings.json konnte nicht geschrieben werden: \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(atPath: Paths.legacyHooksDir)
        try? FileManager.default.removeItem(atPath: Paths.legacyEventsDir)
        return .installed
    }

    static func hasLegacy(_ hooks: [String: Any]) -> Bool {
        hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    let c = $0["command"] as? String ?? ""
                    return isOurs(c) && c != command
                }
            }
        }
    }

    /// Remove QodeNotch's hook entries (other hooks stay untouched).
    public static func uninstall() throws {
        guard var settings = readSettings() else { return }
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let cleaned = strippingOurs(hooks)
        if cleaned.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = cleaned }
        try writeSettings(settings)
        try? FileManager.default.removeItem(atPath: Paths.hooksDir)
        try? FileManager.default.removeItem(atPath: Paths.legacyHooksDir)
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
        let container = nonEmpty(obj["container"] as? String)
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? fallbackPid
        let sessionId = nonEmpty(payload["session_id"] as? String)
        // Container events need a session id; host events need a PID.
        if pid == nil && sessionId == nil { return nil }
        let ts = (obj["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        return HookEvent(
            pid: pid,
            container: pid == nil ? (container ?? "container") : nil,
            event: event,
            sessionId: sessionId,
            cwd: nonEmpty(payload["cwd"] as? String),
            transcriptPath: nonEmpty(payload["transcript_path"] as? String),
            notificationType: nonEmpty(payload["notification_type"] as? String),
            message: nonEmpty(payload["message"] as? String),
            toolName: nonEmpty(payload["tool_name"] as? String),
            timestamp: Date(timeIntervalSince1970: ts)
        )
    }

    /// Read all event files; removes files older than 24h.
    public static func readAll(now: Date = Date()) -> HookSnapshot {
        let fm = FileManager.default
        var snapshot = HookSnapshot()
        guard let entries = try? fm.contentsOfDirectory(atPath: Paths.eventsDir) else { return snapshot }
        for name in entries where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = Paths.eventsDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 24 * 3600 {
                try? fm.removeItem(atPath: path)
                continue
            }
            guard let data = fm.contents(atPath: path) else { continue }
            guard let ev = parseEventFile(data, fallbackPid: Int32(name.dropLast(5))) else { continue }
            if let pid = ev.pid { snapshot.byPid[pid] = ev } else { snapshot.containerEvents.append(ev) }
        }
        return snapshot
    }

    /// Delete host event files for PIDs that no longer exist.
    public static func pruneDead(alive: Set<Int32>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: Paths.eventsDir) else { return }
        for name in entries where name.hasSuffix(".json") {
            if let pid = Int32(name.dropLast(5)), !alive.contains(pid), !ProcessScanner.isAlive(pid) {
                try? FileManager.default.removeItem(atPath: Paths.eventsDir + "/" + name)
            }
        }
    }

    /// Map a transcript path reported from inside a container
    /// (e.g. /home/claude/.claude/projects/…) to the host's ~/.claude.
    public static func hostTranscriptPath(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        guard let r = path.range(of: "/.claude/") else { return path }
        let mapped = Paths.claudeDir + "/" + path[r.upperBound...]
        return FileManager.default.fileExists(atPath: mapped) ? mapped : path
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
