import Foundation

public struct EditorOption: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var command: String
    public var appName: String
}

public struct AppOption: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var appName: String
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
    public var launchAtLogin: Bool = false

    // Global hotkeys
    public var hotkeyToggle: Bool = true
    public var hotkeyApproveDeny: Bool = false

    public init() {}

    public static let defaultInitialPrompt =
        "Implement the feature or fix referenced in the branch name. Think step-by-step: first understand the codebase and requirements, then plan your approach, then implement with tests."

    public static let defaultCreatePrPrompt =
        "Please commit all your changes with a descriptive commit message, push the branch to origin, and create a pull request. Include a clear title and description of what changed and why."

    public static let editors: [EditorOption] = [
        .init(id: "none", label: "Keiner", command: "", appName: ""),
        .init(id: "vscode", label: "VS Code", command: "code", appName: "Visual Studio Code"),
        .init(id: "cursor", label: "Cursor", command: "cursor", appName: "Cursor"),
        .init(id: "zed", label: "Zed", command: "zed", appName: "Zed"),
        .init(id: "xcode", label: "Xcode", command: "xed", appName: "Xcode"),
        .init(id: "sublime", label: "Sublime Text", command: "subl", appName: "Sublime Text"),
        .init(id: "webstorm", label: "WebStorm", command: "webstorm", appName: "WebStorm"),
        .init(id: "intellij", label: "IntelliJ IDEA", command: "idea", appName: "IntelliJ IDEA"),
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
        launchAtLogin = d(.launchAtLogin, launchAtLogin)
        hotkeyToggle = d(.hotkeyToggle, hotkeyToggle)
        hotkeyApproveDeny = d(.hotkeyApproveDeny, hotkeyApproveDeny)
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
