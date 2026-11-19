import QodeNotchCore
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout

    var body: some View {
        VStack(spacing: 8) {
            if store.hookState != .installed {
                HookWarning()
            }
            if store.sessions.isEmpty {
                EmptyState()
            } else {
                FittingScrollView(maxHeight: maxListHeight) {
                    LazyVStack(spacing: 6) {
                        if store.config.groupByRepo {
                            ForEach(SessionGrouping.group(store.sessions)) { group in
                                if SessionGrouping.group(store.sessions).count > 1 {
                                    GroupHeader(group: group)
                                }
                                ForEach(group.sessions) { s in card(s) }
                            }
                        } else {
                            ForEach(store.sessions) { s in card(s) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if store.config.showKeyboardHints && store.isPanelKey && !store.sessions.isEmpty {
                KeyboardHints()
            }
        }
    }

    private var maxListHeight: CGFloat {
        store.config.scaledMaxHeight - max(layout.geometry.notchHeight, 28) - 92 * store.config.scale
    }

    private func card(_ s: ClaudeSession) -> some View {
        SessionCardView(session: s, index: store.sessions.firstIndex(of: s).map { $0 + 1 }, isSelected: store.selectedSession?.id == s.id)
            .id(s.id)
    }
}

private struct GroupHeader: View {
    var group: SessionGroup

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder").scaledFont(size: 9)
            Text(group.repoName).scaledFont(size: 10, weight: .semibold)
            Text(Paths.abbreviateHome(group.repoPath)).scaledFont(size: 9).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Color.primary.opacity(0.3))
            Spacer()
        }
        .foregroundStyle(Color.primary.opacity(0.5))
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }
}

private struct EmptyState: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal").scaledFont(size: 22).foregroundStyle(Color.primary.opacity(0.35))
            Text("Keine laufenden Claude-Sessions").scaledFont(size: 12, weight: .semibold).foregroundStyle(Color.primary.opacity(0.7))
            Text("Starte `claude` in einem Terminal oder lege hier eine neue Session an.")
                .scaledFont(size: 11).foregroundStyle(Color.primary.opacity(0.45)).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                PillButton(title: "Neue Session", symbol: "plus", color: SessionStatus.working.color) { store.route = .newSession }
                PillButton(title: "Alle Sessions", symbol: "clock.arrow.circlepath", color: SessionStatus.working.color, filled: false) { store.route = .history }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private struct HookWarning: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude-Code-Hooks nicht vollständig installiert").scaledFont(size: 11, weight: .semibold)
                Text(detail).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(2)
            }
            Spacer()
            PillButton(title: "Installieren", color: .yellow) { store.reinstallHooks() }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detail: String {
        if case let .error(msg) = store.hookState { return msg }
        return "Status wird bis dahin heuristisch erkannt (CPU + Transcript)."
    }
}

struct KeyboardHints: View {
    var body: some View {
        HStack(spacing: 10) {
            hint("1–9", "wählen")
            hint("⇥", "nächste")
            hint("A/X", "erlauben/ablehnen")
            hint("↩", "Terminal")
            hint("E G F P", "Editor/Git/Finder/PR")
            hint("D", "Details")
            hint("H", "alle Sessions")
            hint("M", "PRs/MRs")
            hint("U", "Limits")
            hint("esc", "schließen")
        }
        .scaledFont(size: 9)
        .foregroundStyle(Color.primary.opacity(0.4))
        .frame(maxWidth: .infinity)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).scaledFont(size: 9, weight: .bold, design: .monospaced)
                .padding(.horizontal, 3)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}
