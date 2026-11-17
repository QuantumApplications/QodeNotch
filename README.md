# QodeNotch

Native macOS-App (Swift, AppKit + SwiftUI), die alle laufenden **Claude Code**-, **OpenAI Codex**- und **GitHub Copilot CLI**-Sessions direkt in der **Notch** deines MacBooks zeigt und steuert – mit dem Funktionsumfang von [claude-control](https://github.com/sverrirsig/claude-control), aber als Notch-Insel im Stil von [CodeIsland](https://github.com/wxtsky/CodeIsland).

- **Eingeklappt:** Ein schwarzer „Flügel“ links und rechts der Notch – farbiger Status-Punkt (pulsiert bei *arbeitet*, hüpft bei *wartet*), Repo-Name der wichtigsten Session und Zähler für wartende/aktive Sessions.
- **Aufgeklappt** (Hover, Klick, ⌘⇧I oder automatisch bei Freigabe-Anfragen): Liste aller Sessions mit Status, Task, Branch, Git-Diff, PR-Status und letzter Nachricht, Freigabe-Buttons, Antwortfeld, Schnellzugriffe und Detailansicht.
- Auf Bildschirmen ohne Notch wird eine Notch in der Menüleiste simuliert.

## Funktionen

| Bereich | Was QodeNotch kann |
| --- | --- |
| **Agents** | Claude Code (Anthropic), Codex CLI (OpenAI) und GitHub Copilot CLI: Erkennung, Status per Hooks (`~/.claude/settings.json`, `~/.codex/hooks.json` + `features.hooks`, `~/.codex/config.toml`, `~/.copilot/hooks/qodenotch.json`), Verlauf, Modell, Tokens, Freigaben, neue Sessions und Fortsetzen (`claude --resume`, `codex resume`, `copilot --resume`). Codex-Rate-Limits aus den Codex-Verläufen. |
| **Erkennung** | Findet alle `claude`-Prozesse (`ps`, `lsof`), ordnet ihnen per Hook-Ereignis exakt das richtige JSONL-Transcript zu (Fallback: neuestes Transcript im Projektordner). |
| **Status** | *Arbeitet*, *Wartet* (Tool-Freigabe oder Rückfrage), *Bereit*, *Fehler*, *Beendet* – in Echtzeit über Claude-Code-Hooks, ergänzt um CPU- und Transcript-Heuristiken. |
| **Kontext** | Task-Titel (erster Prompt oder Linear-Ticket aus MCP-Ergebnissen), letzte Nachricht, aktuelles Tool samt Eingabe, Warnungen bei riskanten Bash-Befehlen (`sudo`, `rm -rf`, `--force`, `eval`, Pipe in Shell …). |
| **Git & PRs/MRs** | Branch, geänderte Dateien, +/- Zeilen, Worktree-Erkennung. GitHub-PRs über `gh`, GitLab-Merge-Requests (auch self-hosted) über `glab`, Forgejo/Codeberg-PRs über die Forgejo-API mit dem Login der Forgejo-CLI `fj` – automatisch nach Git-Remote erkannt: CI-Checks bzw. Pipeline, Review/Approvals, offene Threads, Merge-Konflikte, merged/closed. |
| **Aktionen** | Erlauben / Immer erlauben / Ablehnen, Antwort senden, zum Terminal-Tab springen, Editor, Git-Client, Finder, PR öffnen oder „PR erstellen“-Prompt senden, Session beenden, Titel/Beschreibung überschreiben. |
| **Neue Sessions** | Repo aus Code-Verzeichnissen wählen (oder Ordner), optional neuen Git-Worktree `<repo>-<branch>` von einem Basisbranch anlegen, Start-Prompt, optional in tmux. |
| **Alle Sessions** | Verlauf aller in `~/.claude/projects` gespeicherten Sessions (Titel, Repo, Pfad, Branch, Zeit), durchsuchbar, Öffnen per Klick/Doppelklick oder `H`. Normal per `claude --resume <id>`; mit airlock wird in den Ordner gewechselt und `claude` gestartet – airlock setzt die letzte Session automatisch fort. Laufende Sessions werden stattdessen im Terminal fokussiert. |
| **Limits & Nutzung** | Abo-Limits (5-Stunden-Fenster, Woche, Woche je Modell) mit Reset-Zeit – dieselben Werte wie `/usage`, abgefragt mit dem Login von Claude Code. Dazu Token-Verbrauch dieses Macs (heute, 7 Tage, je Modell) aus den lokalen Transcripts. Badge im Notch-Kopf, Ansicht per `U`. |
| **Claude Desktop** | Sessions aus dem Code-Tab von Claude Desktop werden erkannt und per Klick direkt in Claude Desktop geöffnet. Web-Sessions (claude.ai/code) haben keine öffentliche Schnittstelle – dafür gibt es einen Link. |
| **Erscheinungsbild** | Dunkles oder helles Theme oder wie das System (die eingeklappte Notch bleibt schwarz); Schrift- und Elementgröße 80–160 %. |
| **Aufräumen** | Worktree-Session beenden, Worktree entfernen, lokalen Branch löschen, optional zugehörige Terminal-/Git-Client-/Browser-Tabs schließen (zweistufige Bestätigung). |
| **Benachrichtigungen** | Mitteilungen und Töne pro Ereignis (wartet / fertig / Fehler), Klick springt ins Terminal. |
| **Verwaist** | Sessions, deren Terminal geschlossen wurde oder deren tmux-Session getrennt ist, werden markiert; tmux-Sessions lassen sich wieder anhängen. |

### Claude im Container (airlock & Co.)

Läuft Claude Code in einem Container – z. B. mit [airlock](https://github.com/sundance2000/airlock) (Podman) oder per `docker run … claude` –, gibt es auf dem Mac keinen `claude`-Prozess. QodeNotch erkennt dann den `podman`/`docker`-Client, der im Terminal-Tab hängt (`podman run … --name airlock-…` bzw. `podman start --attach airlock-…`), und nutzt ihn für Terminal-Fokus und Freigaben. Weil airlock `~/.claude` in den Container mountet, liegen Hook-Skript und Ereignisse unter `~/.claude/qodenotch/`; im Container geschriebene Ereignisse werden über das Arbeitsverzeichnis der Session zugeordnet. „Session beenden“ stoppt den Container (`podman stop`). Da die CPU-Last im Container nicht sichtbar ist, stützt sich der Status dort ganz auf Hooks und Transcript.

### Unterstützte Terminals

| Terminal | Tab-Fokus | Text/Tasten senden | Neue Session |
| --- | --- | --- | --- |
| Terminal.app | ✓ (TTY-genau) | ✓ | ✓ |
| iTerm2 | ✓ (TTY-genau) | ✓ ohne Fokuswechsel | ✓ |
| kitty | ✓ (Remote Control*) | ✓ | ✓ |
| WezTerm | ✓ (`wezterm cli`) | ✓ ohne Fokuswechsel | ✓ |
| cmux | ✓ | ✓ | ✓ |
| Ghostty, Warp, Alacritty | App-Ebene | via System Events | ✓ |
| **tmux** (in jedem Terminal) | Fenster + Pane | ✓ `send-keys`, ohne Fokus | ✓ |
| IDE-Terminals (PyCharm & JetBrains, VS Code, Cursor …) | Projektfenster | via System Events, nur wenn das Terminal (nicht der Editor) fokussiert ist | – |

\* kitty: `allow_remote_control yes` und `listen_on unix:/tmp/kitty` in `kitty.conf`.

### Tastenkürzel

Global (in den Einstellungen frei belegbar): **⌘⇧I** Notch öffnen/schließen, optional **⌘⇧A / ⌘⇧D** erste wartende Session erlauben/ablehnen.

In der geöffneten Notch (nach Klick hinein bzw. via ⌘⇧I): `1–9` wählen · `⇥`/`↑↓` wechseln · `A`/`X` erlauben/ablehnen · `↩` Terminal · `E` Editor · `G` Git-Client · `F` Finder · `P` PR · `D`/`→` Details · `N` neue Session · `H` alle Sessions · `U` Limits & Nutzung · `R` aktualisieren · `esc` zurück/schließen.

## Installation

Voraussetzungen: macOS 14+, Xcode 15+ bzw. Swift 5.9+ (Command Line Tools reichen).

```bash
git clone https://github.com/QuantumApplications/QodeNotch.git
cd QodeNotch
./scripts/build-app.sh --install   # baut build/QodeNotch.app und kopiert sie nach /Applications
open /Applications/QodeNotch.app
```

Zum Entwickeln: `swift run QodeNotch` (ohne App-Bundle funktionieren Mitteilungen und Login-Objekt nicht) und `swift test`.

Fertige Builds liegen außerdem als Artefakt `QodeNotch.zip` an jedem Lauf der GitHub-Action **Build**. Die App ist nur ad-hoc signiert (nicht notarisiert). Heruntergeladene Builds blockiert Gatekeeper daher mit „Apple konnte nicht überprüfen …“. Abhilfe:

```bash
xattr -dr com.apple.quarantine /Applications/QodeNotch.app
```

oder nach dem ersten Startversuch unter *Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen*. Lokal mit `build-app.sh` gebaute Apps sind nicht betroffen.

### Berechtigungen

- **Automation** (Abfrage beim ersten Mal): zum Steuern von Terminal, iTerm2, cmux, System Events.
- **Bedienungshilfen**: nur für Terminals ohne Skript-Schnittstelle (Terminal.app-Tastatureingaben, Ghostty, Warp, Alacritty) und zum Schließen von Git-Client-Tabs.
- **Mitteilungen**: für Desktop-Hinweise.

Optional: `gh` bzw. `glab` (eingeloggt) für PR-/MR-Status, `tmux` für Steuerung ohne Fokuswechsel.

## Wie es funktioniert

Beim Start installiert QodeNotch ein kleines Shell-Skript (`~/.claude/qodenotch/status-hook.sh`) als Hook in `~/.claude/settings.json` (bestehende Hooks bleiben erhalten, einmaliges Backup als `settings.json.qodenotch-backup`). Bei jedem Ereignis (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, `SessionEnd`, …) schreibt es den Hook-Payload nach `~/.claude/qodenotch/events/<claude-pid>.json` (in Containern `c-<session-id>.json`). Die App fragt jede Sekunde Prozesse, Hook-Dateien und die Enden der JSONL-Transcripts ab – es gibt keine Datenbank, alles wird jedes Mal neu berechnet. Freigaben werden als Tastendruck (↩ / Esc / „2“) an das jeweilige Terminal bzw. die tmux-Pane geschickt.

Konfiguration: `~/.qodenotch/config.json` (oder über die Einstellungen). Hooks lassen sich unter *Einstellungen → Hooks* wieder entfernen.

## Projektstruktur

```
Package.swift
Sources/QodeNotchCore/   plattformneutrale Logik (Prozesse, Hooks, Transcripts, Status, Git/PR, Terminals, Worktrees)
Sources/QodeNotch/       macOS-App: Notch-Panel, SwiftUI-Views, Einstellungen, Hotkeys, Mitteilungen
Tests/QodeNotchCoreTests Unit-Tests (laufen auch unter Linux)
scripts/build-app.sh     baut und signiert QodeNotch.app
```

## Lizenz

MIT
