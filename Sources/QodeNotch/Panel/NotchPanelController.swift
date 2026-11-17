import AppKit
import Combine
import QodeNotchCore
import SwiftUI

/// Borderless panel that sits on top of the menu bar around the notch.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// AppKit would otherwise push a borderless window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Makes the first click act immediately instead of only focusing the panel.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

/// Geometry + interaction state shared with the SwiftUI views.
@MainActor
final class NotchLayout: ObservableObject {
    @Published var geometry = NotchGeometry(screenFrame: .zero, notchWidth: 200, notchHeight: 32, hasNotch: false)
    @Published var expandedContentHeight: CGFloat = 200
    @Published var isHovering = false
    @Published var isEditing = false

    static let wingWidth: CGFloat = 64
    static let shadowPadding: CGFloat = 24

    func collapsedSize(hasSessions: Bool) -> CGSize {
        let wings = hasSessions || !geometry.hasNotch ? Self.wingWidth * 2 : 0
        return CGSize(width: geometry.notchWidth + wings, height: geometry.notchHeight)
    }
}

@MainActor
final class NotchPanelController: NSObject {
    private let store: SessionStore
    let layout = NotchLayout()
    private var panel: NotchPanel?
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var autoCollapseWork: DispatchWorkItem?
    private var screen: NSScreen?
    private var hiddenForFullscreen = false

    init(store: SessionStore) {
        self.store = store
        super.init()
    }

    // MARK: Setup

    func show() {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let root = NotchRootView(controller: self)
            .environmentObject(store)
            .environmentObject(layout)
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel

        reposition()
        panel.orderFrontRegardless()
        installMonitors()
        observe()
    }

    private func observe() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)

        store.configDidChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)

        store.attentionRequested
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.handleAttention(id) }
            .store(in: &cancellables)

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.publisher(for: name)
                .delay(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.updateFullscreenVisibility() }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: panel)
            .sink { [weak self] _ in self?.store.isPanelKey = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in self?.store.isPanelKey = false }
            .store(in: &cancellables)
    }

    /// Place the panel at the top center of the chosen screen.
    func reposition() {
        guard let panel else { return }
        guard let screen = ScreenGeometry.chosenScreen(setting: store.config.displayID, allowNonNotch: store.config.showOnNonNotchDisplays) else {
            panel.orderOut(nil)
            return
        }
        self.screen = screen
        layout.geometry = ScreenGeometry.geometry(for: screen)
        let pad = NotchLayout.shadowPadding
        let width = max(store.config.scaledExpandedWidth, layout.geometry.notchWidth + NotchLayout.wingWidth * 2) + pad * 2
        let height = store.config.scaledMaxHeight + layout.geometry.notchHeight + pad
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        panel.setFrame(frame, display: true)
        if !hiddenForFullscreen { panel.orderFrontRegardless() }
        updateFullscreenVisibility()
    }

    private func updateFullscreenVisibility() {
        guard let panel, let screen else { return }
        let hide = store.config.hideInFullscreen && ScreenGeometry.isFullscreenActive(on: screen) && !store.isExpanded
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: Hit areas

    /// The area that currently reacts to the mouse, in screen coordinates.
    private func activeRect() -> CGRect {
        let g = layout.geometry
        if store.isExpanded {
            let w = store.config.scaledExpandedWidth
            let h = min(layout.expandedContentHeight, store.config.scaledMaxHeight)
            return CGRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h).insetBy(dx: -6, dy: -6)
        }
        let size = layout.collapsedSize(hasSessions: !store.liveSessions.isEmpty)
        return CGRect(x: g.screenFrame.midX - size.width / 2, y: g.screenFrame.maxY - size.height - 4, width: size.width, height: size.height + 4)
    }

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(m) }
        // Clicking anywhere else collapses the notch.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(m) }
        // Clicks on the transparent part of our own panel also count as "outside".
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                if e.window === self?.panel { self?.clickedOutside() }
            }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let handled = MainActor.assumeIsolated { self?.handleKey(e) ?? false }
            return handled ? nil : e
        }) { monitors.append(m) }
    }

    private func mouseMoved() {
        guard let panel else { return }
        let inside = activeRect().contains(NSEvent.mouseLocation)
        if layout.isHovering != inside { layout.isHovering = inside }
        panel.ignoresMouseEvents = !inside && !store.isExpanded

        if inside {
            collapseWork?.cancel()
            autoCollapseWork?.cancel()
            if !store.isExpanded && expandWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.expandWork = nil
                    if self.activeRect().contains(NSEvent.mouseLocation) { self.expand() }
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(store.config.hoverDelayMs), execute: work)
            }
        } else {
            expandWork?.cancel()
            expandWork = nil
            if store.isExpanded { scheduleCollapse(after: store.config.collapseDelayMs) }
        }
    }

    private func clickedOutside() {
        guard store.isExpanded, !activeRect().contains(NSEvent.mouseLocation) else { return }
        collapse(force: true)
    }

    private func scheduleCollapse(after ms: Int) {
        guard collapseWork == nil || collapseWork!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            if !self.activeRect().contains(NSEvent.mouseLocation) { self.collapse(force: false) }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    // MARK: Expand / collapse

    func expand(makeKey: Bool = false) {
        guard let panel else { return }
        if hiddenForFullscreen {
            hiddenForFullscreen = false
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = false
        if store.selectedId == nil { store.selectedId = store.sessions.first?.id }
        store.refreshLimits()
        store.refreshUsage()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { store.isExpanded = true }
        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func collapse(force: Bool) {
        guard let panel, store.isExpanded else { return }
        if !force && (store.isPinned || layout.isEditing || store.route == .newSession) { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            store.isExpanded = false
            store.route = .list
        }
        layout.isEditing = false
        if panel.isKeyWindow { panel.resignKey() }
        panel.ignoresMouseEvents = true
        updateFullscreenVisibility()
    }

    func toggle() {
        if store.isExpanded { collapse(force: true) } else { expand(makeKey: true) }
    }

    private func handleAttention(_ id: String) {
        guard store.config.autoExpandOnWaiting else { return }
        let wasExpanded = store.isExpanded
        store.selectedId = id
        if !wasExpanded {
            expand()
            // Collapse again if the user does not engage.
            autoCollapseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.activeRect().contains(NSEvent.mouseLocation) else { return }
                self.collapse(force: false)
            }
            autoCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    // MARK: Keyboard

    /// Keyboard shortcuts while the panel is key (ignored while typing in a text field).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isKeyWindow, store.isExpanded else { return false }
        if panel.firstResponder is NSTextView { return false }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return false }

        let selected = store.selectedSession
        switch event.keyCode {
        case 53: // Escape
            if store.route != .list { store.route = .list } else { collapse(force: true) }
            return true
        case 48: // Tab
            store.cycleSelection(forward: !event.modifierFlags.contains(.shift))
            return true
        case 36, 76: // Return
            if let s = selected { store.focus(s) }
            return true
        case 125: store.cycleSelection(forward: true); return true   // ↓
        case 126: store.cycleSelection(forward: false); return true  // ↑
        case 124: if let s = selected { store.openDetail(s.id) }; return true // →
        case 123: store.route = .list; return true                    // ←
        default: break
        }

        guard let ch = event.charactersIgnoringModifiers?.lowercased(), let c = ch.first else { return false }
        if let digit = c.wholeNumberValue, (1...9).contains(digit) {
            store.select(index: digit - 1)
            return true
        }
        if c == "h" { store.route = .history; return true }
        if c == "u" { store.route = .usage; return true }
        guard let s = selected else {
            if c == "n" { store.route = .newSession; return true }
            return false
        }
        switch c {
        case "a": if s.status == .waiting { store.approve(s) }
        case "x": if s.status == .waiting { store.reject(s) }
        case "e": store.openEditor(s)
        case "g": store.openGitGui(s)
        case "f": store.openFinder(s)
        case "p": store.createPR(s)
        case "d": store.openDetail(s.id)
        case "n": store.route = .newSession
        case "r": store.refreshNow()
        default: return false
        }
        return true
    }
}
