import AppKit
import QodeNotchCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
            WorkflowSettings().tabItem { Label("Workflow", systemImage: "terminal") }
            AppsSettings().tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            NotificationSettings().tabItem { Label("Hinweise", systemImage: "bell") }
            ShortcutSettings().tabItem { Label("Tasten", systemImage: "keyboard") }
            HookSettings().tabItem { Label("Agents", systemImage: "link") }
        }
        .padding(16)
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Anzeige") {
                Picker("Erscheinungsbild", selection: $store.config.theme) {
                    ForEach(Theme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Bildschirm", selection: $store.config.displayID) {
                    Text("Automatisch (Notch-Display bevorzugt)").tag("auto")
                    Text("Hauptbildschirm").tag("main")
                    ForEach(NSScreen.screens, id: \.localizedName) { s in
                        Text(s.localizedName + (ScreenGeometry.hasNotch(s) ? " (Notch)" : "")).tag(s.localizedName)
                    }
                }
                Toggle("Auch auf Bildschirmen ohne Notch anzeigen", isOn: $store.config.showOnNonNotchDisplays)
                Toggle("Im Vollbildmodus ausblenden", isOn: $store.config.hideInFullscreen)
                Toggle("Beim Starten anmelden (Login-Objekt)", isOn: $store.config.launchAtLogin)
            }
            Section("Verhalten") {
                Toggle("Automatisch aufklappen, wenn eine Session wartet", isOn: $store.config.autoExpandOnWaiting)
                Stepper("Hover-Verzögerung: \(store.config.hoverDelayMs) ms", value: $store.config.hoverDelayMs, in: 0...1500, step: 50)
                Stepper("Einklapp-Verzögerung: \(store.config.collapseDelayMs) ms", value: $store.config.collapseDelayMs, in: 0...3000, step: 50)
            }
            Section("Größe & Inhalt") {
                HStack {
                    Text("Schrift & Elemente")
                    Slider(value: $store.config.uiScale, in: 0.8...1.6, step: 0.05)
                    Text("\(Int((store.config.uiScale * 100).rounded())) %").monospacedDigit().frame(width: 60)
                }
                HStack {
                    Text("Breite")
                    Slider(value: $store.config.expandedWidth, in: 420...900, step: 10)
                    Text("\(Int(store.config.expandedWidth)) pt").monospacedDigit().frame(width: 60)
                }
                HStack {
                    Text("Max. Höhe")
                    Slider(value: $store.config.maxExpandedHeight, in: 300...900, step: 10)
                    Text("\(Int(store.config.maxExpandedHeight)) pt").monospacedDigit().frame(width: 60)
                }
                Toggle("Sessions nach Repository gruppieren", isOn: $store.config.groupByRepo)
                Toggle("Abo-Limits abfragen (5 h / Woche)", isOn: $store.config.showLimits)
                Text("Nutzt den Login von Claude Code (Keychain bzw. ~/.claude/.credentials.json) und fragt dieselben Werte wie /usage bei Anthropic ab. Beim ersten Mal fragt macOS nach Zugriff auf den Schlüsselbund.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Beendete Sessions weiter anzeigen", isOn: $store.config.showFinishedSessions)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WorkflowSettings: View {
    @EnvironmentObject private var store: SessionStore
    @State private var newDir = ""

    var body: some View {
        Form {
            Section("Code-Verzeichnisse (für „Neue Session“, 2 Ebenen tief)") {
                ForEach(store.config.codeDirectories, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder")
                        Text(dir)
                        Spacer()
                        Button(role: .destructive) {
                            store.config.codeDirectories.removeAll { $0 == dir }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("~/code", text: $newDir).onSubmit(addDir)
                    Button("Hinzufügen", action: addDir).disabled(newDir.isEmpty)
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            newDir = Paths.abbreviateHome(url.path)
                            addDir()
                        }
                    }
                }
            }
            Section("Terminal") {
                Picker("Terminal-App", selection: $store.config.terminalApp) {
                    ForEach(TerminalApp.selectable) { t in
                        Text(t.displayName + (t.hasFullSupport ? "" : " (eingeschränkt)")).tag(t)
                    }
                }
                Picker("Neue Sessions öffnen in", selection: $store.config.terminalOpenIn) {
                    Text("Neuem Tab").tag(OpenIn.tab)
                    Text("Neuem Fenster").tag(OpenIn.window)
                }
                Toggle("Sessions in tmux starten", isOn: $store.config.terminalUseTmux)
                if store.config.terminalUseTmux {
                    Picker("tmux-Modus", selection: $store.config.terminalTmuxMode) {
                        Text("Eine Session pro Projekt").tag(TmuxMode.perProject)
                        Text("Beim Erstellen wählen").tag(TmuxMode.choose)
                    }
                }
                TextField("Startbefehl", text: $store.config.initialCommand)
            }
            Section("Sessions fortsetzen") {
                Picker("Öffnen über", selection: $store.config.resumeStrategy) {
                    ForEach(ResumeStrategy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(SessionResumer.isAirlockInstalled
                     ? "airlock ist installiert: „Automatisch“ öffnet den Ordner und startet claude – airlock setzt die letzte Session dieses Ordners fort."
                     : "airlock wurde nicht gefunden: „Automatisch“ verwendet claude --resume <session-id>.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Prompts & Git") {
                TextField("Standard-Basisbranch", text: $store.config.defaultBaseBranch)
                VStack(alignment: .leading) {
                    Text("Start-Prompt für neue Worktrees")
                    TextEditor(text: $store.config.initialPrompt).frame(height: 60).font(.system(size: 11))
                }
                Picker("Pull/Merge Requests", selection: $store.config.forge) {
                    ForEach(ForgePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Prompt für „PR erstellen“ (P) – GitHub")
                    TextEditor(text: $store.config.createPrPrompt).frame(height: 60).font(.system(size: 11))
                }
                VStack(alignment: .leading) {
                    Text("Prompt für „MR erstellen“ (P) – GitLab")
                    TextEditor(text: $store.config.createMrPrompt).frame(height: 60).font(.system(size: 11))
                }
                VStack(alignment: .leading) {
                    Text("Prompt für „PR erstellen“ (P) – Forgejo/Codeberg")
                    TextEditor(text: $store.config.createForgejoPrompt).frame(height: 60).font(.system(size: 11))
                }
                Stepper("Als veraltet markieren nach \(store.config.staleThresholdMinutes) min", value: $store.config.staleThresholdMinutes, in: 10...1440, step: 10)
                Toggle("Beim Aufräumen Terminal-, Git-Client- und Browser-Tabs schließen", isOn: $store.config.cleanupCloseTabs)
            }
        }
        .formStyle(.grouped)
    }

    private func addDir() {
        let d = newDir.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !store.config.codeDirectories.contains(d) else { return }
        store.config.codeDirectories.append(d)
        newDir = ""
    }
}

private struct AppsSettings: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Schnellzugriffe") {
                Picker("Editor (E)", selection: $store.config.editor) {
                    ForEach(AppConfig.editors) { Text($0.label).tag($0.id) }
                }
                Picker("Git-Client (G)", selection: $store.config.gitGui) {
                    ForEach(AppConfig.gitGuis) { Text($0.label).tag($0.id) }
                }
                Picker("Browser (P)", selection: $store.config.browser) {
                    ForEach(AppConfig.browsers) { Text($0.label).tag($0.id) }
                }
            }
            Section("Voraussetzungen") {
                requirement("git", "Branch-, Diff- und Worktree-Infos")
                requirement("gh", "Pull-Request-Status (gh auth login)")
                requirement("glab", "Merge-Request-Status (glab auth login)")
                requirement("fj", "Forgejo/Codeberg-PRs (fj auth login – QodeNotch nutzt dessen Login)")
                requirement("tmux", "Steuerung ohne Fokuswechsel")
                Text("Für Terminal.app, Ghostty, Warp und Alacritty benötigt QodeNotch die Bedienungshilfen-Berechtigung (Tastatureingaben) und die Automation-Freigabe.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Bedienungshilfen-Einstellungen öffnen") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func requirement(_ tool: String, _ purpose: String) -> some View {
        let found = Shell.which(tool)
        return HStack {
            Image(systemName: found != nil ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(found != nil ? .green : .orange)
            Text(tool).font(.system(.body, design: .monospaced))
            Text(purpose).foregroundStyle(.secondary)
            Spacer()
            Text(found ?? "nicht gefunden").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NotificationSettings: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Mitteilungen") {
                Toggle("Desktop-Mitteilungen", isOn: $store.config.notifications)
                Toggle("Auch anzeigen, wenn die Notch geöffnet ist", isOn: $store.config.alwaysNotify)
            }
            Section("Töne") {
                Toggle("Töne abspielen", isOn: $store.config.notificationSound)
                soundPicker("Wartet auf Freigabe", $store.config.soundWaiting)
                soundPicker("Fertig", $store.config.soundFinished)
                soundPicker("Fehler", $store.config.soundError)
                HStack {
                    Text("Lautstärke")
                    Slider(value: $store.config.soundVolume, in: 0...1)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func soundPicker(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Picker(label, selection: binding) {
                ForEach(AppConfig.systemSounds, id: \.self) { Text($0 == "None" ? "Kein Ton" : $0).tag($0) }
            }
            Button {
                Notifier.shared.playSound(binding.wrappedValue, volume: store.config.soundVolume)
            } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
        }
    }
}

private struct ShortcutSettings: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Globale Kurzbefehle") {
                Toggle("Notch öffnen/schließen", isOn: $store.config.hotkeyToggle)
                if store.config.hotkeyToggle {
                    LabeledContent("Tastenkürzel") {
                        HotKeyRecorder(spec: $store.config.hotkeyToggleKey, defaultSpec: .defaultToggle)
                    }
                }
                Toggle("Erste wartende Session erlauben/ablehnen", isOn: $store.config.hotkeyApproveDeny)
                if store.config.hotkeyApproveDeny {
                    LabeledContent("Erlauben") {
                        HotKeyRecorder(spec: $store.config.hotkeyApproveKey, defaultSpec: .defaultApprove)
                    }
                    LabeledContent("Ablehnen") {
                        HotKeyRecorder(spec: $store.config.hotkeyDenyKey, defaultSpec: .defaultDeny)
                    }
                }
                Text("Zum Ändern auf das Kürzel klicken und die neue Kombination drücken (mit ⌘, ⌃ oder ⌥). Esc bricht ab. Kürzel, die schon eine andere App belegt, funktionieren eventuell nicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("In der geöffneten Notch") {
                Toggle("Tastenhinweise anzeigen", isOn: $store.config.showKeyboardHints)
                shortcut("1 – 9", "Session auswählen")
                shortcut("⇥ / ⇧⇥, ↑ / ↓", "Nächste / vorherige Session")
                shortcut("A / X", "Tool-Anfrage erlauben / ablehnen")
                shortcut("↩", "Zum Terminal-Tab springen")
                shortcut("E / G / F", "Editor / Git-Client / Finder")
                shortcut("P", "PR öffnen bzw. erstellen lassen")
                shortcut("D, →", "Details")
                shortcut("N", "Neue Session")
                shortcut("H", "Alle Sessions (Verlauf)")
                shortcut("U", "Limits & Nutzung")
                shortcut("R", "Aktualisieren")
                shortcut("esc, ←", "Zurück / schließen")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack {
            Text(keys).font(.system(.body, design: .monospaced)).frame(width: 150, alignment: .leading)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

private struct HookSettings: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Form {
            Section("Agents") {
                agentRow(.claude, state: store.hookState, present: true, enabled: .constant(true))
                agentRow(.codex, state: store.codexHookState, present: AgentHooks.isCodexPresent, enabled: $store.config.enableCodex)
                agentRow(.copilot, state: store.copilotHookState, present: AgentHooks.isCopilotPresent, enabled: $store.config.enableCopilot)
                LabeledContent("Startbefehl Codex") { TextField("codex", text: $store.config.codexCommand).frame(width: 180) }
                LabeledContent("Startbefehl Copilot") { TextField("copilot", text: $store.config.copilotCommand).frame(width: 180) }
                Text("Codex: Hooks in ~/.codex/hooks.json, dazu `features.hooks = true` in ~/.codex/config.toml (Backup wird angelegt). Copilot CLI: eigene Datei ~/.copilot/hooks/qodenotch.json. Copilot meldet Freigabe-Anfragen nicht direkt – sie werden erkannt, wenn ein Tool angekündigt ist und nicht startet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude-Code-Hooks") {
                HStack {
                    Image(systemName: icon.0).foregroundStyle(icon.1)
                    Text(stateText)
                }
                Text("QodeNotch trägt ein kleines Shell-Skript als Hook in ~/.claude/settings.json ein. Es liegt in ~/.claude/qodenotch und schreibt bei jedem Ereignis (Prompt, Tool, Freigabe, Stop …) eine Datei nach ~/.claude/qodenotch/events – das funktioniert auch, wenn Claude in einem Container wie airlock läuft. Bestehende Hooks bleiben erhalten; vor der ersten Änderung wird ein Backup angelegt.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Neu installieren") { store.reinstallHooks() }
                    Button("Entfernen", role: .destructive) { store.uninstallHooks() }
                    Spacer()
                    Button("settings.json zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.claudeSettingsFile)])
                    }
                }
            }
            Section("Dateien") {
                LabeledContent("Konfiguration", value: Paths.abbreviateHome(Paths.configFile))
                LabeledContent("Hook-Skript", value: Paths.abbreviateHome(Paths.hookScript))
                LabeledContent("Ereignisse", value: Paths.abbreviateHome(Paths.eventsDir))
            }
        }
        .formStyle(.grouped)
    }

    private func agentRow(_ agent: Agent, state: HookManager.InstallState, present: Bool, enabled: Binding<Bool>) -> some View {
        HStack {
            Image(systemName: agent.symbol).foregroundStyle(agent.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(agent.label) (\(agent.vendor))")
                Text(agentStateText(state, present: present, enabled: enabled.wrappedValue)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if agent != .claude {
                Toggle("", isOn: enabled).labelsHidden().toggleStyle(.switch).disabled(!present)
            }
        }
    }

    private func agentStateText(_ state: HookManager.InstallState, present: Bool, enabled: Bool) -> String {
        if !present { return "Nicht gefunden (Konfigurationsordner fehlt)" }
        if !enabled { return "Ausgeschaltet – nur Prozess- und Verlaufserkennung" }
        switch state {
        case .installed: return "Hooks aktiv – Status in Echtzeit"
        case .partial: return "Hooks teilweise installiert"
        case .notInstalled: return "Hooks nicht installiert"
        case let .error(msg): return msg
        }
    }

    private var stateText: String {
        switch store.hookState {
        case .installed: return "Installiert – Status kommt in Echtzeit."
        case .partial: return "Teilweise installiert."
        case .notInstalled: return "Nicht installiert – Status wird heuristisch erkannt."
        case let .error(msg): return msg
        }
    }

    private var icon: (String, Color) {
        switch store.hookState {
        case .installed: return ("checkmark.circle.fill", .green)
        case .partial: return ("exclamationmark.circle", .yellow)
        case .notInstalled: return ("circle", .secondary)
        case .error: return ("xmark.octagon.fill", .red)
        }
    }
}
