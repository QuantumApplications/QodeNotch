import AppKit
import Carbon.HIToolbox
import Combine
import QodeNotchCore
import ServiceManagement
import SwiftUI

@main
enum QodeNotchMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private let store = SessionStore.shared
    private var panelController: NotchPanelController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.setup()
        store.start()

        let controller = NotchPanelController(store: store)
        controller.show()
        panelController = controller

        setupStatusItem()
        registerHotKeys()
        applyLaunchAtLogin(store.config.launchAtLogin)

        store.configDidChange
            .removeDuplicates {
                $0.hotkeyToggle == $1.hotkeyToggle && $0.hotkeyApproveDeny == $1.hotkeyApproveDeny && $0.launchAtLogin == $1.launchAtLogin
                    && $0.hotkeyToggleKey == $1.hotkeyToggleKey && $0.hotkeyApproveKey == $1.hotkeyApproveKey && $0.hotkeyDenyKey == $1.hotkeyDenyKey
            }
            .sink { [weak self] cfg in
                self?.registerHotKeys()
                self?.applyLaunchAtLogin(cfg.launchAtLogin)
            }
            .store(in: &cancellables)

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.expand(makeKey: true)
        return false
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        // Paused while the settings window records a new shortcut.
        guard !HotKeyCenter.shared.isSuspended else { return }
        let cfg = store.config
        if cfg.hotkeyToggle {
            HotKeyCenter.shared.register(cfg.hotkeyToggleKey) { [weak self] in self?.panelController?.toggle() }
        }
        if cfg.hotkeyApproveDeny {
            HotKeyCenter.shared.register(cfg.hotkeyApproveKey) { [weak self] in
                guard let self, let s = self.store.firstWaiting else { return }
                self.store.approve(s)
            }
            HotKeyCenter.shared.register(cfg.hotkeyDenyKey) { [weak self] in
                guard let self, let s = self.store.firstWaiting else { return }
                self.store.reject(s)
            }
        }
    }

    /// Re-register after the recorder finished (or the config changed).
    func reloadHotKeys() { registerHotKeys() }

    // MARK: Launch at login

    private func applyLaunchAtLogin(_ enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        do {
            if enabled && service.status != .enabled { try service.register() }
            if !enabled && service.status == .enabled { try service.unregister() }
        } catch {
            NSLog("QodeNotch: launch at login failed: \(error)")
        }
    }

    // MARK: Menu bar item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "QodeNotch")
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let item = statusItem else { return }
        let waiting = store.waitingCount
        item.button?.title = waiting > 0 ? " \(waiting)" : ""

        let menu = NSMenu()
        let header = NSMenuItem(title: "\(store.liveSessions.count) Claude-Session(s)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for s in store.liveSessions.prefix(12) {
            let mi = NSMenuItem(title: "\(s.status.label) · \(s.displayTitle)", action: #selector(focusSession(_:)), keyEquivalent: "")
            mi.representedObject = s.id
            mi.target = self
            mi.image = NSImage(systemSymbolName: s.status.symbol, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Notch öffnen", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Neue Session …", action: #selector(newSession), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Alle Sessions …", action: #selector(showHistory), keyEquivalent: "h").target = self
        menu.addItem(withTitle: "Einstellungen …", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "QodeNotch beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let s = store.session(id) else { return }
        store.focus(s)
    }

    @objc private func openNotch() {
        panelController?.expand(makeKey: true)
    }

    @objc private func newSession() {
        store.route = .newSession
        panelController?.expand(makeKey: true)
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func showHistory() {
        store.route = .history
        panelController?.expand(makeKey: true)
    }

    // MARK: Settings window

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "QodeNotch – Einstellungen"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView().environmentObject(store))
            window.center()
            settingsWindow = window
        }
        panelController?.collapse(force: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
