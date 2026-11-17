import Foundation

public struct EditorOption: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var command: String
    public var appName: String
    /// Other bundle names the same editor may be installed under.
    public var alternateAppNames: [String] = []
}

public struct AppOption: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var appName: String
}

public enum Theme: String, Codable, CaseIterable, Sendable {
    case dark, light, system

    public var label: String {
        switch self {
        case .dark: return "Dunkel"
        case .light: return "Hell"
        case .system: return "Wie System"
        }
    }
}

/// How a past session is reopened.
public enum ResumeStrategy: String, Codable, CaseIterable, Sendable {
    /// airlock if it is installed, otherwise `claude --resume`.
    case auto
    /// `cd <dir> && claude --resume <session-id>`.
    case resume
    /// `cd <dir> && claude` – airlock continues the folder's last session by itself.
    case airlock

    public var label: String {
        switch self {
        case .auto: return "Automatisch"
        case .resume: return "claude --resume <id>"
        case .airlock: return "airlock (Ordner öffnen, setzt automatisch fort)"
        }
    }
}

/// A global keyboard shortcut (Carbon key code + Carbon modifier mask).
public struct HotKeySpec: Codable, Equatable, Sendable {
    public var keyCode: Int
    /// cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000
    public var modifiers: Int
    /// Key label as typed, e.g. "I".
    public var key: String

    public init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    public static let cmd = 0x100, shift = 0x200, option = 0x800, control = 0x1000

    /// "⌃⌥⇧⌘I"
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s + key
    }

    // kVK_ANSI_I = 34, kVK_ANSI_A = 0, kVK_ANSI_D = 2
    public static let defaultToggle = HotKeySpec(keyCode: 34, modifiers: cmd | shift, key: "I")
    public static let defaultApprove = HotKeySpec(keyCode: 0, modifiers: cmd | shift, key: "A")
    public static let defaultDeny = HotKeySpec(keyCode: 2, modifiers: cmd | shift, key: "D")
}

/// Where pull/merge requests come from.
public enum ForgePreference: String, Codable, CaseIterable, Sendable {
    case auto, github, gitlab

    public var label: String {
        switch self {
        case .auto: return "Automatisch (nach Git-Remote)"
        case .github: return "GitHub (gh)"
        case .gitlab: return "GitLab (glab)"
        }
    }
}

public enum TmuxMode: String, Codable, CaseIterable, Sendable {
    case perProject = "per-project"
    case choose
}

/// User configuration stored in `~/.qodenotch/config.json`.
public struct AppConfig: Codable, Equatable, Sendable {
    // Workflow
    public var codeDirectories: [String] = []
    public var editor: String = "vscode"
    public var gitGui: String = "fork"
    public var browser: String = "default"
    public var terminalApp: TerminalApp = .terminalApp
    public var terminalOpenIn: OpenIn = .tab
    public var terminalUseTmux: Bool = false
    public var terminalTmuxMode: TmuxMode = .perProject
    public var initialCommand: String = "claude"
    public var initialPrompt: String = AppConfig.defaultInitialPrompt
    public var createPrPrompt: String = AppConfig.defaultCreatePrPrompt
    public var defaultBaseBranch: String = "main"
    public var staleThresholdMinutes: Int = 90
    public var cleanupCloseTabs: Bool = false

    // Notifications
    public var notifications: Bool = true
    public var notificationSound: Bool = true
    public var alwaysNotify: Bool = false
    public var soundWaiting: String = "Glass"
    public var soundFinished: String = "Hero"
    public var soundError: String = "Basso"
    public var soundVolume: Double = 0.7

    // Notch
    public var autoExpandOnWaiting: Bool = true
    public var hoverDelayMs: Int = 150
    public var collapseDelayMs: Int = 350
    public var expandedWidth: Double = 560
    public var maxExpandedHeight: Double = 560
    public var displayID: String = "auto"   // "auto" | "main" | screen localizedName
    public var showOnNonNotchDisplays: Bool = true
    public var hideInFullscreen: Bool = true
    public var showFinishedSessions: Bool = false
    public var showKeyboardHints: Bool = true
    public var groupByRepo: Bool = true
    public var theme: Theme = .dark
    /// Size of text and controls in the notch (1.0 = 100 %).
    public var uiScale: Double = 1.0
    /// Fetch plan limits (5 h / weekly) with Claude Code's login.
    public var showLimits: Bool = true
    public var resumeStrategy: ResumeStrategy = .auto
    public var launchAtLogin: Bool = false

    // Global hotkeys
    public var hotkeyToggle: Bool = true
    public var hotkeyApproveDeny: Bool = false
    public var hotkeyToggleKey: HotKeySpec = .defaultToggle
    public var hotkeyApproveKey: HotKeySpec = .defaultApprove
    public var hotkeyDenyKey: HotKeySpec = .defaultDeny
    public var forge: ForgePreference = .auto
    public var createMrPrompt: String = AppConfig.defaultCreateMrPrompt

    public init() {}

    public static let defaultInitialPrompt =
        "Implement the feature or fix referenced in the branch name. Think step-by-step: first understand the codebase and requirements, then plan your approach, then implement with tests."

    public static let defaultCreatePrPrompt =
        "Please commit all your changes with a descriptive commit message, push the branch to origin, and create a pull request. Include a clear title and description of what changed and why."

    public static let defaultCreateMrPrompt =
        "Please commit all your changes with a descriptive commit message, push the branch to origin, and create a GitLab merge request with `glab mr create`. Include a clear title and description of what changed and why."

    public static let editors: [EditorOption] = [
        .init(id: "none", label: "Keiner", command: "", appName: ""),
        .init(id: "vscode", label: "VS Code", command: "code", appName: "Visual Studio Code"),
        .init(id: "cursor", label: "Cursor", command: "cursor", appName: "Cursor"),
        .init(id: "zed", label: "Zed", command: "zed", appName: "Zed"),
        .init(id: "xcode", label: "Xcode", command: "xed", appName: "Xcode"),
        .init(id: "sublime", label: "Sublime Text", command: "subl", appName: "Sublime Text"),
        .init(id: "webstorm", label: "WebStorm", command: "webstorm", appName: "WebStorm"),
        .init(id: "intellij", label: "IntelliJ IDEA", command: "idea", appName: "IntelliJ IDEA",
              alternateAppNames: ["IntelliJ IDEA CE", "IntelliJ IDEA Ultimate"]),
        .init(id: "pycharm", label: "PyCharm", command: "pycharm", appName: "PyCharm",
              alternateAppNames: ["PyCharm CE", "PyCharm Professional Edition", "PyCharm Community Edition"]),
        .init(id: "nova", label: "Nova", command: "nova", appName: "Nova"),
    ]

    public static let gitGuis: [AppOption] = [
        .init(id: "none", label: "Keins", appName: ""),
        .init(id: "fork", label: "Fork", appName: "Fork"),
        .init(id: "tower", label: "Tower", appName: "Tower"),
        .init(id: "sublime-merge", label: "Sublime Merge", appName: "Sublime Merge"),
        .init(id: "gitkraken", label: "GitKraken", appName: "GitKraken"),
        .init(id: "sourcetree", label: "Sourcetree", appName: "Sourcetree"),
        .init(id: "github-desktop", label: "GitHub Desktop", appName: "GitHub Desktop"),
    ]

    public static let browsers: [AppOption] = [
        .init(id: "default", label: "Systemstandard", appName: ""),
        .init(id: "safari", label: "Safari", appName: "Safari"),
        .init(id: "chrome", label: "Google Chrome", appName: "Google Chrome"),
        .init(id: "arc", label: "Arc", appName: "Arc"),
        .init(id: "dia", label: "Dia", appName: "Dia"),
        .init(id: "firefox", label: "Firefox", appName: "Firefox"),
        .init(id: "brave", label: "Brave", appName: "Brave Browser"),
        .init(id: "edge", label: "Microsoft Edge", appName: "Microsoft Edge"),
    ]

    public static let systemSounds = ["None", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    public var editorOption: EditorOption? { Self.editors.first { $0.id == editor && $0.id != "none" } }
    public var gitGuiOption: AppOption? { Self.gitGuis.first { $0.id == gitGui && $0.id != "none" } }
    public var browserOption: AppOption? { Self.browsers.first { $0.id == browser && $0.id != "default" } }

    // Decode tolerantly: unknown/missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
        codeDirectories = d(.codeDirectories, codeDirectories)
        editor = d(.editor, editor)
        gitGui = d(.gitGui, gitGui)
        browser = d(.browser, browser)
        terminalApp = d(.terminalApp, terminalApp)
        terminalOpenIn = d(.terminalOpenIn, terminalOpenIn)
        terminalUseTmux = d(.terminalUseTmux, terminalUseTmux)
        terminalTmuxMode = d(.terminalTmuxMode, terminalTmuxMode)
        initialCommand = d(.initialCommand, initialCommand)
        initialPrompt = d(.initialPrompt, initialPrompt)
        createPrPrompt = d(.createPrPrompt, createPrPrompt)
        defaultBaseBranch = d(.defaultBaseBranch, defaultBaseBranch)
        staleThresholdMinutes = d(.staleThresholdMinutes, staleThresholdMinutes)
        cleanupCloseTabs = d(.cleanupCloseTabs, cleanupCloseTabs)
        notifications = d(.notifications, notifications)
        notificationSound = d(.notificationSound, notificationSound)
        alwaysNotify = d(.alwaysNotify, alwaysNotify)
        soundWaiting = d(.soundWaiting, soundWaiting)
        soundFinished = d(.soundFinished, soundFinished)
        soundError = d(.soundError, soundError)
        soundVolume = d(.soundVolume, soundVolume)
        autoExpandOnWaiting = d(.autoExpandOnWaiting, autoExpandOnWaiting)
        hoverDelayMs = d(.hoverDelayMs, hoverDelayMs)
        collapseDelayMs = d(.collapseDelayMs, collapseDelayMs)
        expandedWidth = d(.expandedWidth, expandedWidth)
        maxExpandedHeight = d(.maxExpandedHeight, maxExpandedHeight)
        displayID = d(.displayID, displayID)
        showOnNonNotchDisplays = d(.showOnNonNotchDisplays, showOnNonNotchDisplays)
        hideInFullscreen = d(.hideInFullscreen, hideInFullscreen)
        showFinishedSessions = d(.showFinishedSessions, showFinishedSessions)
        showKeyboardHints = d(.showKeyboardHints, showKeyboardHints)
        groupByRepo = d(.groupByRepo, groupByRepo)
        theme = d(.theme, theme)
        uiScale = min(max(d(.uiScale, uiScale), 0.8), 1.6)
        showLimits = d(.showLimits, showLimits)
        resumeStrategy = d(.resumeStrategy, resumeStrategy)
        launchAtLogin = d(.launchAtLogin, launchAtLogin)
        hotkeyToggle = d(.hotkeyToggle, hotkeyToggle)
        hotkeyApproveDeny = d(.hotkeyApproveDeny, hotkeyApproveDeny)
        hotkeyToggleKey = d(.hotkeyToggleKey, hotkeyToggleKey)
        hotkeyApproveKey = d(.hotkeyApproveKey, hotkeyApproveKey)
        hotkeyDenyKey = d(.hotkeyDenyKey, hotkeyDenyKey)
        forge = d(.forge, forge)
        createMrPrompt = d(.createMrPrompt, createMrPrompt)
    }

    public static func load() -> AppConfig {
        guard let data = FileManager.default.contents(atPath: Paths.configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return config
    }

    public func save() throws {
        Paths.ensureDirectory(Paths.appDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
    }
}

/// User overrides for session titles/descriptions (`~/.qodenotch/session-meta.json`).
public enum SessionMetaStore {
    public struct Overrides: Codable, Equatable, Sendable {
        public var title: String?
        public var description: String?
    }

    public static func load() -> [String: Overrides] {
        guard let data = FileManager.default.contents(atPath: Paths.sessionMetaFile),
              let store = try? JSONDecoder().decode([String: Overrides].self, from: data) else { return [:] }
        return store
    }

    public static func save(sessionId: String, title: String?, description: String?) throws {
        var store = load()
        var entry = store[sessionId] ?? Overrides()
        entry.title = (title?.isEmpty ?? true) ? nil : title
        entry.description = (description?.isEmpty ?? true) ? nil : description
        store[sessionId] = (entry.title == nil && entry.description == nil) ? nil : entry
        Paths.ensureDirectory(Paths.appDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(store).write(to: URL(fileURLWithPath: Paths.sessionMetaFile), options: .atomic)
    }

    public static func apply(_ store: [String: Overrides], to sessions: inout [ClaudeSession]) {
        for i in sessions.indices {
            guard let o = store[sessions[i].id] else { continue }
            var summary = sessions[i].taskSummary ?? TaskSummary(title: "", description: nil, source: .user)
            if let t = o.title { summary.title = t; summary.source = .user }
            if let d = o.description { summary.description = d }
            sessions[i].taskSummary = summary
        }
    }
}
