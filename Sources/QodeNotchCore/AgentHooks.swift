import Foundation

/// Hook installation for OpenAI Codex CLI and GitHub Copilot CLI. Both call the
/// same status script as Claude Code (see `HookManager.script`) with the agent
/// name as argument, so all events end up in `~/.claude/qodenotch/events`.
public enum AgentHooks {

    static func command(agent: Agent, event: String? = nil) -> String {
        let args = [agent.rawValue] + (event.map { [$0] } ?? [])
        return #"f="$HOME/.claude/qodenotch/status-hook.sh"; [ -f "$f" ] && sh "$f" "# + args.joined(separator: " ") + "; exit 0"
    }

    // MARK: Codex

    /// `$CODEX_HOME` or `~/.codex`.
    public static var codexHome: String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? Paths.home + "/.codex" : Paths.expandTilde(raw)
    }

    public static var isCodexPresent: Bool { FileManager.default.fileExists(atPath: codexHome) }

    /// Events supported by every Codex release with hooks.
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"]

    public static func codexState() -> HookManager.InstallState {
        guard isCodexPresent else { return .notInstalled }
        let hooks = readJSON(codexHome + "/hooks.json")?["hooks"] as? [String: Any] ?? [:]
        let ours = codexEvents.filter { containsCommand(hooks[$0], command(agent: .codex)) }
        let flag = (try? String(contentsOfFile: codexHome + "/config.toml", encoding: .utf8)).map(CodexConfig.hooksEnabled) ?? false
        if ours.count == codexEvents.count && flag { return .installed }
        return ours.isEmpty ? .notInstalled : .partial
    }

    @discardableResult
    public static func installCodex() -> HookManager.InstallState {
        guard isCodexPresent else { return .notInstalled }
        let path = codexHome + "/hooks.json"
        var root = readJSON(path) ?? [:]
        var hooks = stripOurs(root["hooks"] as? [String: Any] ?? [:])
        for event in codexEvents {
            var list = hooks[event] as? [[String: Any]] ?? []
            list.append(["hooks": [["type": "command", "command": command(agent: .codex), "timeout": 5]]])
            hooks[event] = list
        }
        root["hooks"] = hooks
        do {
            try writeJSON(root, to: path, backup: true)
            // Codex only runs hooks with the feature flag on.
            let configPath = codexHome + "/config.toml"
            let current = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
            guard let updated = CodexConfig.enablingHooks(current) else {
                return .error("~/.codex/config.toml konnte nicht automatisch angepasst werden – bitte `[features]` → `hooks = true` von Hand eintragen.")
            }
            if updated != current {
                backupOnce(configPath)
                try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return .error("Codex-Hooks: \(error.localizedDescription)")
        }
        return codexState()
    }

    public static func uninstallCodex() {
        let path = codexHome + "/hooks.json"
        guard var root = readJSON(path), let hooks = root["hooks"] as? [String: Any] else { return }
        let cleaned = stripOurs(hooks)
        if cleaned.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = cleaned }
        try? writeJSON(root, to: path, backup: false)
    }

    // MARK: Copilot

    public static var copilotHome: String { Paths.home + "/.copilot" }
    public static var isCopilotPresent: Bool { FileManager.default.fileExists(atPath: copilotHome) }
    /// Our own hooks file – Copilot CLI reads every JSON file in ~/.copilot/hooks.
    public static var copilotHookFile: String { copilotHome + "/hooks/qodenotch.json" }

    /// Copilot's payload has no event name, so it is passed as argument.
    static let copilotEvents = ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse", "agentStop", "errorOccurred"]

    public static func copilotState() -> HookManager.InstallState {
        guard isCopilotPresent else { return .notInstalled }
        guard let hooks = readJSON(copilotHookFile)?["hooks"] as? [String: Any] else { return .notInstalled }
        let ok = copilotEvents.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { ($0["bash"] as? String) == command(agent: .copilot, event: event) }
        }
        return ok ? .installed : .partial
    }

    @discardableResult
    public static func installCopilot() -> HookManager.InstallState {
        guard isCopilotPresent else { return .notInstalled }
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            hooks[event] = [["type": "command", "bash": command(agent: .copilot, event: event), "timeoutSec": 5]]
        }
        do {
            try FileManager.default.createDirectory(atPath: copilotHome + "/hooks", withIntermediateDirectories: true)
            try writeJSON(["version": 1, "hooks": hooks], to: copilotHookFile, backup: false)
        } catch {
            return .error("Copilot-Hooks: \(error.localizedDescription)")
        }
        return copilotState()
    }

    public static func uninstallCopilot() {
        try? FileManager.default.removeItem(atPath: copilotHookFile)
    }

    // MARK: Helpers

    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func writeJSON(_ obj: [String: Any], to path: String, backup: Bool) throws {
        if backup { backupOnce(path) }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func backupOnce(_ path: String) {
        let backup = path + ".qodenotch-backup"
        if FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: path, toPath: backup)
        }
    }

    static func containsCommand(_ entries: Any?, _ cmd: String) -> Bool {
        (entries as? [[String: Any]] ?? []).contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == cmd }
        }
    }

    static func stripOurs(_ hooks: [String: Any]) -> [String: Any] {
        HookManager.strippingOurs(hooks)
    }
}

/// Minimal, source-preserving edit of Codex's `config.toml` to turn on hooks
/// (`[features] hooks = true`). Values are never parsed; ambiguous layouts are
/// refused instead of risking a duplicate key that would stop Codex from starting.
public enum CodexConfig {
    static func strip(_ line: Substring) -> String {
        var l = String(line)
        if let hash = l.firstIndex(of: "#") { l = String(l[..<hash]) }
        return l.trimmingCharacters(in: .whitespaces)
    }

    static func tableName(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") else { return nil }
        return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    static func key(_ line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
        let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return (k, v)
    }

    public static func hooksEnabled(_ toml: String) -> Bool {
        var table = ""
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = strip(raw)
            if let t = tableName(line) { table = t; continue }
            guard let kv = key(line) else { continue }
            let full = table.isEmpty ? kv.key : table + "." + kv.key
            if full == "features.hooks" || full == "features.codex_hooks" { return kv.value == "true" }
        }
        return false
    }

    /// The config with hooks enabled, or nil when it can't be edited safely.
    public static func enablingHooks(_ toml: String) -> String? {
        if hooksEnabled(toml) { return toml }
        var lines = toml.components(separatedBy: "\n")
        var table = ""
        var featuresHeader: Int?
        var firstTable: Int?
        var dottedFeatures = false
        for (i, raw) in lines.enumerated() {
            let line = strip(Substring(raw))
            if let t = tableName(line) {
                table = t
                if firstTable == nil { firstTable = i }
                if t == "features" {
                    if featuresHeader != nil { return nil }
                    featuresHeader = i
                }
                continue
            }
            guard let kv = key(line) else { continue }
            let full = table.isEmpty ? kv.key : table + "." + kv.key
            if table.isEmpty && kv.key.hasPrefix("features.") { dottedFeatures = true }
            if full == "features.hooks" || full == "features.codex_hooks" {
                // Present but false: flip it in place.
                lines[i] = raw.replacingOccurrences(of: kv.value, with: "true")
                return lines.joined(separator: "\n")
            }
        }
        if let header = featuresHeader {
            if dottedFeatures { return nil }
            lines.insert("hooks = true", at: header + 1)
        } else {
            // Root-level dotted key must come before the first table.
            var position = firstTable ?? lines.count
            if firstTable == nil { while position > 0 && lines[position - 1].isEmpty { position -= 1 } }
            lines.insert("features.hooks = true", at: position)
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}
