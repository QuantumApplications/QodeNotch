import Foundation

/// File-system locations and path helpers.
public enum Paths {
    public static var home: String {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }

    public static var claudeDir: String { home + "/.claude" }
    public static var claudeProjectsDir: String { claudeDir + "/projects" }
    public static var claudeSettingsFile: String { claudeDir + "/settings.json" }

    /// QodeNotch's own state directory.
    public static var appDir: String { home + "/.qodenotch" }
    public static var hooksDir: String { appDir + "/hooks" }
    public static var eventsDir: String { appDir + "/events" }
    public static var hookScript: String { hooksDir + "/status-hook.sh" }
    public static var configFile: String { appDir + "/config.json" }
    public static var sessionMetaFile: String { appDir + "/session-meta.json" }

    /// Claude Code stores transcripts in `~/.claude/projects/<sanitized cwd>`. Current
    /// versions replace every non-alphanumeric character with `-`; older ones only `/`.
    public static func escapedProjectNames(for workingDirectory: String) -> [String] {
        let alnum = String(workingDirectory.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        let slashes = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let slashesDots = String(workingDirectory.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        var seen = Set<String>()
        return [alnum, slashesDots, slashes].filter { seen.insert($0).inserted }
    }

    /// The first existing project directory for a working directory (or the canonical one).
    public static func projectDir(for workingDirectory: String) -> String {
        let candidates = escapedProjectNames(for: workingDirectory).map { claudeProjectsDir + "/" + $0 }
        var isDir: ObjCBool = false
        for c in candidates where FileManager.default.fileExists(atPath: c, isDirectory: &isDir) && isDir.boolValue {
            return c
        }
        return candidates[0]
    }

    public static func repoName(from path: String) -> String {
        let parts = path.split(separator: "/").filter { !$0.isEmpty }
        return parts.last.map(String.init) ?? path
    }

    public static func abbreviateHome(_ path: String) -> String {
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func ensureDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
}
