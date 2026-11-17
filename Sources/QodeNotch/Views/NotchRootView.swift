import QodeNotchCore
import SwiftUI

struct NotchRootView: View {
    let controller: NotchPanelController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout
    /// Follows the system appearance (the panel itself has no fixed appearance).
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        VStack(spacing: 0) {
            container
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Color scheme of the expanded panel. The collapsed notch always stays
    /// dark so it blends into the hardware notch.
    private var expandedScheme: ColorScheme {
        switch store.config.theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return systemScheme
        }
    }

    @ViewBuilder
    private var container: some View {
        let expanded = store.isExpanded
        let collapsed = layout.collapsedSize(hasSessions: !store.liveSessions.isEmpty)
        let hoverGrow: CGFloat = (!expanded && layout.isHovering) ? 8 : 0
        let light = expanded && expandedScheme == .light

        ZStack(alignment: .top) {
            if expanded {
                ExpandedView(controller: controller)
                    .environment(\.colorScheme, expandedScheme)
                    .environment(\.notchScale, store.config.scale)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                CollapsedView()
                    .environment(\.colorScheme, .dark)
                    // The collapsed bar is as tall as the notch: grow its text only a little.
                    .environment(\.notchScale, min(store.config.scale, 1.15))
                    .frame(width: collapsed.width + hoverGrow, height: collapsed.height)
                    .transition(.opacity)
            }
        }
        .frame(width: expanded ? store.config.scaledExpandedWidth : collapsed.width + hoverGrow)
        .background(
            NotchShape(topRadius: expanded ? 10 : 6, bottomRadius: expanded ? 22 : 10)
                .fill(light ? Color(white: 0.965) : Color.black)
        )
        .overlay(
            NotchShape(topRadius: 10, bottomRadius: 22)
                .stroke(Color.black.opacity(light ? 0.12 : 0), lineWidth: 1)
        )
        .clipShape(NotchShape(topRadius: expanded ? 10 : 6, bottomRadius: expanded ? 22 : 10))
        .measureHeight { h in
            if expanded, abs(layout.expandedContentHeight - h) > 0.5 { layout.expandedContentHeight = h }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: expanded)
        .animation(.easeInOut(duration: 0.25), value: expandedScheme)
        .animation(.easeOut(duration: 0.15), value: layout.isHovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.liveSessions.isEmpty)
    }
}

// MARK: - Collapsed

/// Compact state: status orb on the left wing, counters on the right wing.
struct CollapsedView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout

    var body: some View {
        let live = store.liveSessions
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if !live.isEmpty || !layout.geometry.hasNotch {
                    StatusOrb(status: store.aggregateStatus, size: 9)
                    if let s = live.first(where: { $0.status == .waiting }) ?? live.first {
                        Text(s.repoName)
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(Color.primary.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.leading, 14)
            .frame(width: NotchLayout.wingWidth + 10, alignment: .leading)

            Spacer(minLength: layout.geometry.notchWidth - 20)

            HStack(spacing: 5) {
                if store.waitingCount > 0 {
                    Image(systemName: "hand.raised.fill").scaledFont(size: 9)
                    Text("\(store.waitingCount)").scaledFont(size: 11, weight: .bold, design: .rounded)
                } else if store.workingCount > 0 {
                    ProgressView().controlSize(.mini).tint(SessionStatus.working.color).scaleEffect(0.7)
                    Text("\(store.workingCount)").scaledFont(size: 11, weight: .bold, design: .rounded)
                } else if !live.isEmpty {
                    Text("\(live.count)").scaledFont(size: 11, weight: .bold, design: .rounded)
                }
            }
            .foregroundStyle(store.waitingCount > 0 ? SessionStatus.waiting.color : Color.primary.opacity(0.8))
            .padding(.trailing, 14)
            .frame(width: NotchLayout.wingWidth + 10, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    let controller: NotchPanelController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var layout: NotchLayout

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: max(layout.geometry.notchHeight, 28))
            Group {
                switch store.route {
                case .list:
                    SessionListView()
                case let .detail(id):
                    if let s = store.session(id) {
                        SessionDetailView(session: s)
                    } else {
                        SessionListView()
                    }
                case .newSession:
                    NewSessionView()
                case .history:
                    HistoryView()
                case .usage:
                    UsageView()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if let toast = store.toast {
                Text(toast.text)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(toast.isError ? Color.red : Color.primary.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background((toast.isError ? Color.red : Color.primary).opacity(0.12), in: Capsule())
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .animation(.easeInOut(duration: 0.2), value: store.route)
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                StatusOrb(status: store.aggregateStatus, size: 8)
                Text("QodeNotch").scaledFont(size: 12, weight: .bold)
                Text(summary).scaledFont(size: 10).foregroundStyle(Color.primary.opacity(0.5)).lineLimit(1)
            }
            .padding(.leading, 8)
            Spacer(minLength: layout.geometry.hasNotch ? layout.geometry.notchWidth : 12)
            HStack(spacing: 4) {
                LimitBadge()
                IconButton(symbol: "chart.bar", help: "Limits & Nutzung", shortcut: "U") { store.route = .usage }
                IconButton(symbol: "plus", help: "Neue Session", shortcut: "N") { store.route = .newSession }
                IconButton(symbol: "clock.arrow.circlepath", help: "Alle Sessions", shortcut: "H") { store.route = .history }
                IconButton(symbol: "arrow.clockwise", help: "Aktualisieren", shortcut: "R") { store.refreshNow() }
                IconButton(symbol: store.isPinned ? "pin.fill" : "pin", help: "Angeheftet lassen",
                           tint: store.isPinned ? SessionStatus.waiting.color : Color.primary) { store.isPinned.toggle() }
                IconButton(symbol: "gearshape", help: "Einstellungen") { AppDelegate.shared?.openSettings() }
            }
            .padding(.trailing, 4)
        }
        .foregroundStyle(Color.primary)
    }

    private var summary: String {
        let live = store.liveSessions
        if live.isEmpty { return "keine Sessions" }
        var parts = ["\(live.count) Session\(live.count == 1 ? "" : "s")"]
        if store.waitingCount > 0 { parts.append("\(store.waitingCount) wartend") }
        if store.workingCount > 0 { parts.append("\(store.workingCount) aktiv") }
        return parts.joined(separator: " · ")
    }
}
