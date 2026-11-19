import Foundation

public enum Keystroke: Equatable, Sendable {
    case enter, escape, up, down, tab, space
    case text(String)

    var systemEvents: String {
        switch self {
        case .enter: return "key code 36"
        case .escape: return "key code 53"
        case .up: return "key code 126"
        case .down: return "key code 125"
        case .tab: return "key code 48"
        case .space: return "keystroke \" \""
        case let .text(s): return "keystroke \"\(AppleScript.escape(s))\""
        }
    }

    var tmuxKey: String {
        switch self {
        case .enter: return "Enter"
        case .escape: return "Escape"
        case .up: return "Up"
        case .down: return "Down"
        case .tab: return "Tab"
        case .space: return "Space"
        case let .text(s): return s
        }
    }

    /// Raw bytes sent to a PTY (WezTerm / kitty send-text).
    var rawBytes: String {
        switch self {
        case .enter: return "\r"
        case .escape: return "\u{1b}"
        case .up: return "\u{1b}[A"
        case .down: return "\u{1b}[B"
        case .tab: return "\t"
        case .space: return " "
        case let .text(s): return s
        }
    }
}

public enum OpenIn: String, Codable, CaseIterable, Sendable {
    case tab, window
}

public enum AppleScript {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    @discardableResult
    public static func run(_ script: String, timeout: TimeInterval = 10) async throws -> String {
        try await Shell.runChecked("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }

    static func systemEvents(process: String, _ action: String) -> String {
        """
        tell application "System Events"
          tell process "\(escape(process))"
            \(action)
          end tell
        end tell
        """
    }

    static func activate(_ app: String) -> String {
        "tell application \"\(escape(app))\" to activate"
    }

    static let focusDelay = "delay 0.25"
}

/// Focus, type into, and open terminal tabs. tmux panes are addressed
/// directly through `tmux send-keys`, which works without focusing anything.
public enum TerminalController {

    // MARK: Public API

    public static func focus(_ info: TerminalInfo) async throws {
        var effective = info
        if let tmux = info.tmux {
            let bin = TerminalDetector.tmuxBinary()
            _ = await Shell.run(bin, ["select-window", "-t", "\(tmux.sessionName):\(tmux.windowIndex)"], timeout: 5)
            _ = await Shell.run(bin, ["select-pane", "-t", tmux.paneId], timeout: 5)
            if !tmux.clientTty.isEmpty { effective.tty = tmux.clientTty }
            if let cp = tmux.clientPid { effective.pid = cp }
        }
        try await adapterFocus(effective)
    }

    public static func sendText(_ info: TerminalInfo, _ text: String) async throws {
        if let tmux = info.tmux {
            let bin = TerminalDetector.tmuxBinary()
            try await Shell.runChecked(bin, ["send-keys", "-t", tmux.paneId, "-l", text], timeout: 5)
            try await Shell.runChecked(bin, ["send-keys", "-t", tmux.paneId, "Enter"], timeout: 5)
            return
        }
        try await adapterSendText(info, text)
    }

    public static func sendKeystroke(_ info: TerminalInfo, _ key: Keystroke) async throws {
        if let tmux = info.tmux {
            var args = ["send-keys", "-t", tmux.paneId]
            if case .text = key { args.append("-l") }
            args.append(key.tmuxKey)
            try await Shell.runChecked(TerminalDetector.tmuxBinary(), args, timeout: 5)
            return
        }
        try await adapterSendKeystroke(info, key)
    }

    public static func close(_ info: TerminalInfo) async throws {
        if let tmux = info.tmux {
            try await Shell.runChecked(TerminalDetector.tmuxBinary(), ["kill-pane", "-t", tmux.paneId], timeout: 5)
            return
        }
        switch info.app {
        case .terminalApp:
            try await AppleScript.run(terminalAppFocusScript(tty: info.tty) + "\n" + AppleScript.focusDelay + "\n"
                                      + AppleScript.systemEvents(process: "Terminal", "keystroke \"w\" using command down"))
        case .iterm:
            try await AppleScript.run(itermForSession(tty: info.tty, action: "close aSession"))
        case .kitty:
            if let id = await Kitty.windowId(for: info) { _ = await Kitty.remote(["close-window", "--match", "id:\(id)"]) }
        case .wezterm:
            if let pane = await WezTerm.pane(forTty: info.tty) {
                _ = await Shell.run(WezTerm.binary(), ["cli", "kill-pane", "--pane-id", String(pane)], timeout: 5)
            }
        default:
            break
        }
    }

    public struct CreateOptions: Sendable {
        public var terminal: TerminalApp
        public var openIn: OpenIn
        public var useTmux: Bool
        public var tmuxSession: String?
        public var cwd: String
        public var prompt: String?
        public var initialCommand: String

        public init(terminal: TerminalApp, openIn: OpenIn, useTmux: Bool, tmuxSession: String?, cwd: String, prompt: String?, initialCommand: String) {
            self.terminal = terminal
            self.openIn = openIn
            self.useTmux = useTmux
            self.tmuxSession = tmuxSession
            self.cwd = cwd
            self.prompt = prompt
            self.initialCommand = initialCommand
        }
    }

    /// Build the shell command that starts claude in `cwd`.
    public static func claudeCommand(cwd: String, prompt: String?, initialCommand: String) -> String {
        var command = initialCommand.trimmingCharacters(in: .whitespaces).isEmpty ? "claude" : initialCommand
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += " " + Shell.quote(prompt)
        }
        return "cd \(Shell.quote(cwd)) && \(command)"
    }

    /// Open a new terminal tab/window (optionally inside tmux) running claude.
    public static func createSession(_ opts: CreateOptions) async throws {
        let cmd = claudeCommand(cwd: opts.cwd, prompt: opts.prompt, initialCommand: opts.initialCommand)
        let tmuxBin = TerminalDetector.tmuxBinary()

        if opts.useTmux, let name = opts.tmuxSession, !name.isEmpty {
            // Existing tmux session → add a window and focus its client.
            let r = await Shell.run(tmuxBin, ["new-window", "-t", name, "-c", opts.cwd, cmd], timeout: 10)
            if r.ok {
                let clients = await TerminalDetector.tmuxClients()
                if let client = clients.first(where: { $0.sessionName == name }) {
                    let tree = await ProcessScanner.buildTree()
                    let r = TerminalDetector.resolve(from: client.pid, in: tree)
                    try? await adapterFocus(TerminalInfo(app: r.app, pid: client.pid, tty: client.tty, hostApp: r.host))
                    return
                }
                // Detached session: attach it in a new terminal tab.
                try await adapterCreate("\(tmuxBin) attach -t \(Shell.quote(name))", terminal: opts.terminal, openIn: opts.openIn, cwd: opts.cwd)
                return
            }
        }

        var effective = cmd
        if opts.useTmux {
            let name = (opts.tmuxSession?.isEmpty == false) ? opts.tmuxSession! : "claude-" + String(UUID().uuidString.prefix(4)).lowercased()
            effective = "\(tmuxBin) new-session -s \(Shell.quote(name)) \"\(Shell.escapeDouble(cmd))\""
        }
        try await adapterCreate(effective, terminal: opts.terminal, openIn: opts.openIn, cwd: opts.cwd)
    }

    /// Open a terminal tab attached to an existing (detached) tmux session.
    public static func reattach(tmuxSession: String, terminal: TerminalApp, openIn: OpenIn, cwd: String) async throws {
        try await adapterCreate("\(TerminalDetector.tmuxBinary()) attach -t \(Shell.quote(tmuxSession))", terminal: terminal, openIn: openIn, cwd: cwd)
    }

    // MARK: Adapters

    private static func adapterFocus(_ info: TerminalInfo) async throws {
        switch info.app {
        case .terminalApp:
            try await AppleScript.run(terminalAppFocusScript(tty: info.tty))
        case .iterm:
            try await AppleScript.run(itermFocusScript(tty: info.tty))
        case .kitty:
            if let id = await Kitty.windowId(for: info) {
                _ = await Kitty.remote(["focus-window", "--match", "id:\(id)"])
            }
            _ = await Shell.run("/usr/bin/open", ["-a", "kitty"], timeout: 5)
        case .wezterm:
            if let pane = await WezTerm.pane(forTty: info.tty) {
                _ = await Shell.run(WezTerm.binary(), ["cli", "activate-pane", "--pane-id", String(pane)], timeout: 5)
            }
            _ = await Shell.run("/usr/bin/open", ["-a", "WezTerm"], timeout: 5)
        case .cmux:
            if let id = Cmux.terminalId(forTty: info.tty) {
                try await AppleScript.run(Cmux.script(terminalId: id, action: "focus t"))
            } else {
                try await AppleScript.run(AppleScript.activate("cmux"))
            }
        case .ghostty, .alacritty, .warp:
            _ = await Shell.run("/usr/bin/open", ["-a", info.app.appName], timeout: 5)
        case .ide:
            try await IDETerminal.focus(info)
        case .unknown:
            break
        }
    }

    private static func adapterSendText(_ info: TerminalInfo, _ text: String) async throws {
        switch info.app {
        case .iterm:
            try await AppleScript.run(itermForSession(tty: info.tty, action: "tell aSession to write text \"\(AppleScript.escape(text))\""))
        case .kitty:
            if let id = await Kitty.windowId(for: info),
               await Kitty.remote(["send-text", "--match", "id:\(id)", text + "\r"]) != nil { return }
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, "keystroke \"\(AppleScript.escape(text))\"\n    key code 36"))
        case .wezterm:
            if let pane = await WezTerm.pane(forTty: info.tty) {
                try await Shell.runChecked(WezTerm.binary(), ["cli", "send-text", "--pane-id", String(pane), "--no-paste", text + "\r"], timeout: 5)
                return
            }
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, "keystroke \"\(AppleScript.escape(text))\"\n    key code 36"))
        case .cmux:
            if let id = Cmux.terminalId(forTty: info.tty) {
                try await AppleScript.run(Cmux.script(terminalId: id, action: "input text \"\(AppleScript.escape(text + "\n"))\" to t"))
                return
            }
            try await genericSend(info, AppleScript.systemEvents(process: "cmux", "keystroke \"\(AppleScript.escape(text))\"\n    key code 36"))
        case .terminalApp:
            try await AppleScript.run(terminalAppFocusScript(tty: info.tty) + "\n" + AppleScript.focusDelay + "\n"
                                      + AppleScript.systemEvents(process: "Terminal", "keystroke \"\(AppleScript.escape(text))\"\n    key code 36"))
        case .ghostty, .alacritty, .warp:
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, "keystroke \"\(AppleScript.escape(text))\"\n    key code 36"))
        case .ide:
            try await IDETerminal.send(info, "keystroke \"\(AppleScript.escape(text))\"\n    key code 36")
        case .unknown:
            throw TerminalError.unsupported
        }
    }

    private static func adapterSendKeystroke(_ info: TerminalInfo, _ key: Keystroke) async throws {
        switch info.app {
        case .iterm:
            // iTerm can write raw bytes to a session without focusing it.
            let write: String?
            switch key {
            case .enter: write = "write text \"\""
            case .escape: write = "write text (ASCII character 27) newline NO"
            case let .text(s): write = "write text \"\(AppleScript.escape(s))\" newline NO"
            default: write = nil
            }
            if let write {
                try await AppleScript.run(itermForSession(tty: info.tty, action: "tell aSession to \(write)"))
            } else {
                try await AppleScript.run(itermFocusScript(tty: info.tty) + "\n" + AppleScript.focusDelay + "\n"
                                          + AppleScript.systemEvents(process: "iTerm2", key.systemEvents))
            }
        case .kitty:
            if let id = await Kitty.windowId(for: info) {
                let ok: String?
                switch key {
                case .enter: ok = await Kitty.remote(["send-key", "--match", "id:\(id)", "enter"])
                case .escape: ok = await Kitty.remote(["send-key", "--match", "id:\(id)", "escape"])
                case .up: ok = await Kitty.remote(["send-key", "--match", "id:\(id)", "up"])
                case .down: ok = await Kitty.remote(["send-key", "--match", "id:\(id)", "down"])
                case .tab: ok = await Kitty.remote(["send-key", "--match", "id:\(id)", "tab"])
                default: ok = await Kitty.remote(["send-text", "--match", "id:\(id)", key.rawBytes])
                }
                if ok != nil { return }
            }
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, key.systemEvents))
        case .wezterm:
            if let pane = await WezTerm.pane(forTty: info.tty) {
                try await Shell.runChecked(WezTerm.binary(), ["cli", "send-text", "--pane-id", String(pane), "--no-paste", key.rawBytes], timeout: 5)
                return
            }
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, key.systemEvents))
        case .terminalApp:
            try await AppleScript.run(terminalAppFocusScript(tty: info.tty) + "\n" + AppleScript.focusDelay + "\n"
                                      + AppleScript.systemEvents(process: "Terminal", key.systemEvents))
        case .cmux:
            if let id = Cmux.terminalId(forTty: info.tty) {
                try await AppleScript.run(Cmux.script(terminalId: id, action: "focus t\n          delay 0.1\n" + AppleScript.systemEvents(process: "cmux", key.systemEvents)))
                return
            }
            try await genericSend(info, AppleScript.systemEvents(process: "cmux", key.systemEvents))
        case .ghostty, .alacritty, .warp:
            try await genericSend(info, AppleScript.systemEvents(process: info.app.processName, key.systemEvents))
        case .ide:
            try await IDETerminal.send(info, key.systemEvents)
        case .unknown:
            throw TerminalError.unsupported
        }
    }

    /// Activate the app, then run a System Events action (app-level targeting only).
    private static func genericSend(_ info: TerminalInfo, _ action: String) async throws {
        try await AppleScript.run(AppleScript.activate(info.app.appName) + "\n" + AppleScript.focusDelay + "\n" + action)
    }

    private static func adapterCreate(_ command: String, terminal: TerminalApp, openIn: OpenIn, cwd: String) async throws {
        let asCmd = AppleScript.escape(command)
        switch terminal {
        case .terminalApp, .ide, .unknown:
            let script = openIn == .tab ? """
            tell application "Terminal"
              activate
              if (count of windows) > 0 then
                tell application "System Events" to tell process "Terminal" to keystroke "t" using command down
                delay 0.3
                do script "\(asCmd)" in front window
              else
                do script "\(asCmd)"
              end if
            end tell
            """ : """
            tell application "Terminal"
              activate
              do script "\(asCmd)"
            end tell
            """
            try await AppleScript.run(script)
        case .iterm:
            let script = openIn == .tab ? """
            tell application "iTerm"
              activate
              if (count of windows) = 0 then
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text "\(asCmd)"
              else
                tell current window
                  set newTab to (create tab with default profile)
                  tell current session of newTab to write text "\(asCmd)"
                end tell
              end if
            end tell
            """ : """
            tell application "iTerm"
              activate
              set newWindow to (create window with default profile)
              tell current session of newWindow to write text "\(asCmd)"
            end tell
            """
            try await AppleScript.run(script)
        case .kitty:
            let ok = await Kitty.remote(["launch", "--type=\(openIn == .window ? "os-window" : "tab")", "--cwd=\(cwd)", "sh", "-lc", command])
            if ok == nil {
                if FileManager.default.fileExists(atPath: "/Applications/kitty.app") {
                    Shell.spawnDetached("/usr/bin/open", ["-na", "kitty", "--args", "sh", "-lc", command])
                } else {
                    Shell.spawnDetached("kitty", ["sh", "-lc", command])
                }
            }
        case .wezterm:
            let bin = WezTerm.binary()
            if openIn == .tab, await Shell.run(bin, ["cli", "spawn", "--cwd", cwd, "--", "sh", "-lc", command], timeout: 5).ok {
                _ = await Shell.run("/usr/bin/open", ["-a", "WezTerm"], timeout: 5)
                return
            }
            Shell.spawnDetached(bin, ["start", "--cwd", cwd, "--", "sh", "-lc", command])
        case .ghostty:
            // Ghostty has no tab scripting; open a new window running the command.
            Shell.spawnDetached("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", "sh", "-lc", command])
        case .alacritty:
            Shell.spawnDetached("/usr/bin/open", ["-na", "Alacritty", "--args", "--working-directory", cwd, "-e", "sh", "-lc", command])
        case .warp:
            try await AppleScript.run("""
            tell application "Warp" to activate
            delay 0.5
            tell application "System Events"
              tell process "Warp"
                keystroke "\(openIn == .window ? "n" : "t")" using command down
                delay 0.5
                keystroke "\(asCmd)"
                key code 36
              end tell
            end tell
            """)
        case .cmux:
            try await AppleScript.run("""
            tell application "cmux"
              activate
              set newWs to new tab
              select tab newWs
              delay 0.15
              set t to focused terminal of newWs
              focus t
              input text "\(AppleScript.escape(command + "\n"))" to t
            end tell
            """)
        }
    }

    // MARK: AppleScript snippets

    static func terminalAppFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
          activate
          set found to false
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              if tty of aTab is "\(AppleScript.escape(tty))" then
                set selected tab of aWindow to aTab
                set index of aWindow to 1
                set found to true
                exit repeat
              end if
            end repeat
            if found then exit repeat
          end repeat
        end tell
        """
    }

    static func itermFocusScript(tty: String) -> String {
        """
        tell application "iTerm"
          activate
          set found to false
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if tty of aSession is "\(AppleScript.escape(tty))" then
                  select aWindow
                  select aTab
                  select aSession
                  set found to true
                  exit repeat
                end if
              end repeat
              if found then exit repeat
            end repeat
            if found then exit repeat
          end repeat
        end tell
        """
    }

    static func itermForSession(tty: String, action: String) -> String {
        """
        tell application "iTerm"
          repeat with aWindow in windows
            repeat with aTab in tabs of aWindow
              repeat with aSession in sessions of aTab
                if tty of aSession is "\(AppleScript.escape(tty))" then
                  \(action)
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }
}

public enum TerminalError: Error, LocalizedError {
    case unsupported
    case noProcess

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Terminal wurde nicht erkannt – Eingaben können nicht gesendet werden."
        case .noProcess: return "Zu dieser Session gibt es keinen laufenden Prozess."
        }
    }
}

// MARK: - kitty remote control

enum Kitty {
    static func socket() -> String? {
        if let env = ProcessInfo.processInfo.environment["KITTY_LISTEN_ON"], !env.isEmpty { return env }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return nil }
        return entries.first { $0.hasPrefix("kitty-") || $0 == "kitty" || $0.hasPrefix("mykitty") }.map { "unix:/tmp/\($0)" }
    }

    static func binary() -> String {
        if let k = Shell.which("kitten") { return k }
        let bundled = "/Applications/kitty.app/Contents/MacOS/kitten"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "kitten"
    }

    static func remote(_ args: [String]) async -> String? {
        guard let socket = socket() else { return nil }
        let r = await Shell.run(binary(), ["@", "--to", socket] + args, timeout: 3)
        return r.ok ? r.stdout : nil
    }

    static func windowId(for info: TerminalInfo) async -> Int? {
        guard let out = await remote(["ls"]),
              let data = out.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var targets: [Int] = [Int(info.pid)]
        if let cp = info.tmux?.clientPid { targets.append(Int(cp)) }
        for osw in osWindows {
            for tab in osw["tabs"] as? [[String: Any]] ?? [] {
                for win in tab["windows"] as? [[String: Any]] ?? [] {
                    let id = win["id"] as? Int
                    let pid = win["pid"] as? Int
                    let fg = (win["foreground_processes"] as? [[String: Any]] ?? []).compactMap { $0["pid"] as? Int }
                    if let id, targets.contains(where: { $0 == pid || fg.contains($0) }) { return id }
                }
            }
        }
        return nil
    }
}

// MARK: - WezTerm CLI

enum WezTerm {
    static func binary() -> String {
        if let w = Shell.which("wezterm") { return w }
        let bundled = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "wezterm"
    }

    static func pane(forTty tty: String) async -> Int? {
        let r = await Shell.run(binary(), ["cli", "list", "--format", "json"], timeout: 5)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return panes.first { ($0["tty_name"] as? String) == tty }?["pane_id"] as? Int
    }
}

// MARK: - cmux

enum Cmux {
    static var sessionFile: String {
        Paths.home + "/Library/Application Support/cmux/session-com.cmuxterm.app.json"
    }

    static func terminalId(forTty tty: String) -> String? {
        guard let data = FileManager.default.contents(atPath: sessionFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let short = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        for window in json["windows"] as? [[String: Any]] ?? [] {
            let tm = window["tabManager"] as? [String: Any]
            for ws in tm?["workspaces"] as? [[String: Any]] ?? [] {
                for panel in ws["panels"] as? [[String: Any]] ?? [] where (panel["ttyName"] as? String) == short {
                    return panel["id"] as? String
                }
            }
        }
        return nil
    }

    static func script(terminalId: String, action: String) -> String {
        """
        tell application "cmux"
          activate
          repeat with w in every window
            repeat with tb in every tab of w
              repeat with t in every terminal of tb
                if id of t is "\(AppleScript.escape(terminalId))" then
                  select tab tb
                  delay 0.15
                  \(action)
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }
}

// MARK: - Integrated terminals of IDEs (PyCharm, IntelliJ, VS Code, Cursor …)

/// IDEs have no scripting interface for their terminal tabs. QodeNotch raises
/// the IDE window of the session's project and types via System Events into the
/// focused component – but only when that component is not a code editor.
public enum IDETerminal {
    static func processRef(_ host: HostApp?) -> String {
        if let pid = host?.pid { return "(first process whose unix id is \(pid))" }
        return "(first process whose frontmost is true)"
    }

    static func focusScript(_ info: TerminalInfo) -> String {
        let host = info.hostApp
        let activate = host?.pid == nil ? "tell application \"\(AppleScript.escape(host?.name ?? "Terminal"))\" to activate\ndelay 0.2\n" : ""
        let hints = info.projectHints.map { "\"\(AppleScript.escape($0))\"" }.joined(separator: ", ")
        return activate + """
        tell application "System Events"
          set p to \(processRef(host))
          set frontmost of p to true
          set done to false
          repeat with h in {\(hints)}
            repeat with w in (windows of p)
              try
                if (name of w) contains (h as text) then
                  perform action "AXRaise" of w
                  set done to true
                  exit repeat
                end if
              end try
            end repeat
            if done then exit repeat
          end repeat
        end tell
        """
    }

    public static func focus(_ info: TerminalInfo) async throws {
        try await AppleScript.run(focusScript(info))
    }

    /// Describes the focused UI element of the IDE (role, description, title).
    static func focusedElementScript(_ host: HostApp?) -> String {
        """
        tell application "System Events"
          set p to \(processRef(host))
          set out to ""
          try
            set f to value of attribute "AXFocusedUIElement" of p
            try
              set out to out & (role of f) & " | "
            end try
            try
              set out to out & (description of f) & " | "
            end try
            try
              set out to out & (name of f) & " | "
            end try
            try
              set out to out & (value of attribute "AXRoleDescription" of f)
            end try
          end try
          return out
        end tell
        """
    }

    /// True when the focused element is clearly a code editor (typing there would edit code).
    public static func isEditor(_ description: String) -> Bool {
        let d = description.lowercased()
        return d.contains("editor") && !d.contains("terminal")
    }

    public static func send(_ info: TerminalInfo, _ action: String) async throws {
        try await focus(info)
        try await Task.sleep(nanoseconds: 300_000_000)
        let focused = try await AppleScript.run(focusedElementScript(info.hostApp))
        if isEditor(focused) {
            throw ActionError.message("In \(info.hostApp?.name ?? "der IDE") ist gerade der Editor aktiv – bitte einmal ins Terminal-Fenster mit Claude klicken und erneut versuchen.")
        }
        try await AppleScript.run("""
        tell application "System Events"
          tell \(processRef(info.hostApp))
            \(action)
          end tell
        end tell
        """)
    }
}
