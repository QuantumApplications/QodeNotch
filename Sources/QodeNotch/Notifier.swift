import AppKit
import QodeNotchCore
import UserNotifications

/// Desktop notifications + sounds for session state changes.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Kind {
        case waiting, finished, errored
    }

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the binary is not inside an app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(session: ClaudeSession, kind: Kind, config: AppConfig, suppress: Bool) {
        if config.notificationSound {
            let name: String
            switch kind {
            case .waiting: name = config.soundWaiting
            case .finished: name = config.soundFinished
            case .errored: name = config.soundError
            }
            playSound(name, volume: config.soundVolume)
        }
        guard config.notifications, !suppress, let center else { return }

        let content = UNMutableNotificationContent()
        switch kind {
        case .waiting:
            content.title = "\(session.repoName) wartet auf dich"
            if let tool = session.preview.lastTools.first {
                content.body = "\(tool.name): \(tool.input ?? tool.description ?? "Freigabe benötigt")"
            } else {
                content.body = session.preview.lastAssistantText ?? "Claude braucht eine Eingabe."
            }
        case .finished:
            content.title = "\(session.repoName) ist fertig"
            content.body = session.preview.lastAssistantText ?? session.displayTitle
        case .errored:
            content.title = "\(session.repoName): Fehler"
            content.body = session.preview.lastAssistantText ?? "Die Session meldet einen Fehler."
        }
        content.userInfo = ["sessionId": session.id]
        let request = UNNotificationRequest(identifier: "\(session.id)-\(kind)", content: content, trigger: nil)
        center.add(request)
    }

    func playSound(_ name: String, volume: Double) {
        guard name != "None", let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = Float(volume)
        sound.play()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionId"] as? String
        Task { @MainActor in
            let store = SessionStore.shared
            if let id, let session = store.session(id) {
                store.focus(session)
            }
            completionHandler()
        }
    }
}
