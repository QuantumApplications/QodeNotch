import Foundation

/// Supported terminal emulators.
public enum TerminalApp: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminalApp = "terminal-app"
    case iterm
    case ghostty
    case kitty
    case wezterm
    case alacritty
    case warp
    case cmux
    /// Terminal built into another app (PyCharm & other JetBrains IDEs, VS Code, Cursor …).
    case ide
    case unknown

    public var id: String { rawValue }

    /// Name used with `open -a` / `tell application`.
    public var appName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm: return "iTerm"
        case .ghostty: return "Ghostty"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .alacritty: return "Alacritty"
        case .warp: return "Warp"
        case .cmux: return "cmux"
        case .ide, .unknown: return "Terminal"
        }
    }

    /// Process name as seen by System Events.
    public var processName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "ghostty"
        case .kitty: return "kitty"
        case .wezterm: return "wezterm-gui"
        case .alacritty: return "alacritty"
        case .warp: return "Warp"
        case .cmux: return "cmux"
        case .ide, .unknown: return "Terminal"
        }
    }

    public var displayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .kitty: return "kitty"
        case .wezterm: return "WezTerm"
        case .alacritty: return "Alacritty"
        case .warp: return "Warp"
        case .cmux: return "cmux"
        case .ide: return "IDE-Terminal"
        case .unknown: return "Unbekannt"
        }
    }

    /// Tab-level focus + background text input.
    public var hasFullSupport: Bool {
        switch self {
        case .terminalApp, .iterm, .kitty, .wezterm, .cmux: return true
        default: return false
        }
    }

    public static var selectable: [TerminalApp] { allCases.filter { $0 != .unknown && $0 != .ide } }
}

/// Everything needed to address the terminal tab/pane hosting a claude process.
public struct TerminalInfo: Equatable, Sendable {
    public struct Tmux: Equatable, Sendable {
        public var paneId: String
        public var sessionName: String
        public var windowIndex: Int
        public var paneIndex: Int
        public var clientPid: Int32?
        /// TTY of the tmux client (the terminal tab), not the pane.
        public var clientTty: String
    }

    public var app: TerminalApp
    public var pid: Int32
    public var tty: String
    public var tmux: Tmux?
    /// The app hosting the terminal when `app == .ide`.
    public var hostApp: HostApp?
    /// Folder names that identify the session's window (deepest first).
    public var projectHints: [String] = []

    public var inTmux: Bool { tmux != nil }

    public init(app: TerminalApp, pid: Int32, tty: String, tmux: Tmux? = nil, hostApp: HostApp? = nil) {
        self.app = app
        self.pid = pid
        self.tty = tty
        self.tmux = tmux
        self.hostApp = hostApp
    }

    public var displayName: String { app == .ide ? (hostApp?.name ?? "IDE") : app.displayName }
}

/// A GUI app whose integrated terminal runs the session.
public struct HostApp: Equatable, Sendable {
    /// Bundle name, e.g. "PyCharm", "PyCharm CE", "Visual Studio Code".
    public var name: String
    /// PID of the app's main process (for System Events), if found.
    public var pid: Int32?

    public init(name: String, pid: Int32?) {
        self.name = name
        self.pid = pid
    }
}

public struct TmuxClientInfo: Equatable, Sendable {
    public var tty: String
    public var pid: Int32
    public var sessionName: String
}

public enum TerminalDetector {
    /// Lower-cased process basename → terminal.
    static let known: [(key: String, app: TerminalApp)] = [
        ("iterm2", .iterm), ("terminal", .terminalApp), ("ghostty", .ghostty), ("kitty", .kitty),
        ("wezterm-gui", .wezterm), ("wezterm", .wezterm), ("alacritty", .alacritty),
        ("warp", .warp), ("stable", .warp), ("cmux", .cmux),
    ]

    /// Match a `ps` comm (basename or full path) to a terminal.
    public static func match(_ comm: String) -> TerminalApp? {
        let base = (comm.split(separator: "/").last.map(String.init) ?? comm).lowercased()
        let full = comm.lowercased()
        // Warp's binary is called "stable" — only trust that inside Warp.app.
        if base == "stable" { return full.contains("warp") ? .warp : nil }
        if let direct = known.first(where: { $0.key == base }) { return direct.app }
        for (key, app) in known where key != "stable" && key != "terminal" && base.hasPrefix(key) { return app }
        if full.contains("iterm") { return .iterm }
        if full.contains("terminal.app") { return .terminalApp }
        if full.contains("ghostty") { return .ghostty }
        if full.contains("kitty") { return .kitty }
        if full.contains("wezterm") { return .wezterm }
        if full.contains("alacritty") { return .alacritty }
        if full.contains("warp.app") { return .warp }
        if full.contains("cmux") { return .cmux }
        return nil
    }

    /// Name of the outermost `.app` bundle in an executable path:
    /// "/Applications/PyCharm CE.app/Contents/MacOS/pycharm" → "PyCharm CE".
    public static func appBundleName(fromComm comm: String) -> String? {
        guard let r = comm.range(of: ".app/") else { return nil }
        let prefix = comm[..<r.lowerBound]
        guard let name = prefix.split(separator: "/").last, !name.isEmpty else { return nil }
        return String(name)
    }

    /// Apps whose child processes are not "the terminal" of a session.
    static let ignoredHosts: Set<String> = ["Claude", "QodeNotch", "Finder", "Dock", "loginwindow"]

    /// The GUI app hosting the shell when no known terminal is in the ancestry
    /// (integrated terminals of IDEs). Prefers the app's main process.
    public static func findHostApp(from pid: Int32, in tree: ProcessTree) -> HostApp? {
        var current = pid
        var visited = Set<Int32>()
        var name: String?
        var fallbackPid: Int32?
        while current > 1, !visited.contains(current), let entry = tree[current] {
            visited.insert(current)
            if let bundle = appBundleName(fromComm: entry.comm), !ignoredHosts.contains(bundle) {
                if name == nil { name = bundle; fallbackPid = current }
                // Main executable: "<bundle>.app/Contents/MacOS/…" without nested helper bundles.
                if bundle == name, entry.comm.contains(bundle + ".app/Contents/MacOS/"), !entry.comm.contains("/Frameworks/") {
                    return HostApp(name: bundle, pid: current)
                }
            }
            current = entry.ppid
        }
        guard let name else { return nil }
        // Helper process (e.g. VS Code's "Code Helper"): no UI of its own.
        let helper = tree[fallbackPid ?? 0]?.comm.contains("/Frameworks/") ?? true
        return HostApp(name: name, pid: helper ? nil : fallbackPid)
    }

    /// Terminal or host app for a process: known terminal first, then IDE.
    public static func resolve(from pid: Int32, in tree: ProcessTree) -> (app: TerminalApp, host: HostApp?) {
        let app = findTerminal(from: pid, in: tree)
        if app != .unknown { return (app, nil) }
        if let host = findHostApp(from: pid, in: tree) { return (.ide, host) }
        return (.unknown, nil)
    }

    /// Walk up from `pid` until a known terminal is found.
    public static func findTerminal(from pid: Int32, in tree: ProcessTree) -> TerminalApp {
        var current = pid
        var visited = Set<Int32>()
        while current > 1, !visited.contains(current), let entry = tree[current] {
            visited.insert(current)
            if let app = match(entry.comm) { return app }
            current = entry.ppid
        }
        return .unknown
    }

    public static func tmuxBinary() -> String {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return Shell.which("tmux") ?? "tmux"
    }

    /// All tmux panes keyed by pane TTY.
    public static func tmuxPanes() async -> [String: TmuxPaneInfo] {
        let r = await Shell.run(tmuxBinary(), ["list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_name}\t#{window_index}\t#{pane_index}"], timeout: 5)
        guard r.ok else { return [:] }
        return parseTmuxPanes(r.stdout)
    }

    public static func parseTmuxPanes(_ output: String) -> [String: TmuxPaneInfo] {
        var panes: [String: TmuxPaneInfo] = [:]
        for line in output.split(separator: "\n") {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 5 else { continue }
            let tty = ProcessScanner.normalizeTty(p[0])
            panes[tty] = TmuxPaneInfo(tty: tty, paneId: p[1], sessionName: p[2], windowIndex: Int(p[3]) ?? 0, paneIndex: Int(p[4]) ?? 0)
        }
        return panes
    }

    public static func tmuxClients() async -> [TmuxClientInfo] {
        let r = await Shell.run(tmuxBinary(), ["list-clients", "-F", "#{client_tty}\t#{client_pid}\t#{client_session}"], timeout: 5)
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 3, let pid = Int32(p[1]) else { return nil }
            return TmuxClientInfo(tty: ProcessScanner.normalizeTty(p[0]), pid: pid, sessionName: p[2])
        }
    }

    public struct TmuxSessionInfo: Identifiable, Equatable, Sendable {
        public var name: String
        public var windows: Int
        public var attached: Bool
        public var id: String { name }
    }

    public static func tmuxSessions() async -> [TmuxSessionInfo] {
        let r = await Shell.run(tmuxBinary(), ["list-sessions", "-F", "#{session_name}\t#{session_windows}\t#{session_attached}"], timeout: 5)
        guard r.ok else { return [] }
        return r.stdout.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard !p.isEmpty, !p[0].isEmpty else { return nil }
            return TmuxSessionInfo(name: p[0], windows: p.count > 1 ? Int(p[1]) ?? 0 : 0, attached: p.count > 2 && p[2] != "0")
        }
    }

    /// Resolve the terminal hosting a claude PID, including tmux pane info.
    public static func detect(pid: Int32, tree: ProcessTree? = nil) async -> TerminalInfo {
        async let treeTask = tree == nil ? ProcessScanner.buildTree() : tree!
        async let ttyTask = ProcessScanner.ttys(for: [pid])
        async let panesTask = tmuxPanes()
        let (t, ttys, panes) = await (treeTask, ttyTask, panesTask)
        let tty = ttys[pid] ?? ""

        if let pane = panes[tty] {
            let clients = await tmuxClients()
            let client = clients.first { $0.sessionName == pane.sessionName }
            let resolved = client.map { resolve(from: $0.pid, in: t) } ?? (.unknown, nil)
            return TerminalInfo(app: resolved.app, pid: pid, tty: tty, tmux: .init(
                paneId: pane.paneId, sessionName: pane.sessionName, windowIndex: pane.windowIndex,
                paneIndex: pane.paneIndex, clientPid: client?.pid, clientTty: client?.tty ?? ""), hostApp: resolved.host)
        }
        let resolved = resolve(from: pid, in: t)
        return TerminalInfo(app: resolved.app, pid: pid, tty: tty, hostApp: resolved.host)
    }

    /// A session is orphaned when its terminal is gone (or its tmux session is detached).
    public static func isOrphaned(pid: Int32, tree: ProcessTree, inTmux: Bool, tmuxHasClient: Bool) -> Bool {
        if inTmux { return !tmuxHasClient }
        guard tree[pid] != nil else { return false }
        if resolve(from: pid, in: tree).app != .unknown { return false }
        // Remote (SSH) or IDE-hosted sessions are not orphans.
        var current = pid
        var visited = Set<Int32>()
        while current > 1, !visited.contains(current), let entry = tree[current] {
            visited.insert(current)
            let base = entry.basename.lowercased()
            if base == "sshd" || base == "ssh" || base.contains("code helper") || base.contains("cursor") || base.contains("zed") || base == "idea" {
                return false
            }
            current = entry.ppid
        }
        return true
    }
}
