import AppKit
import QodeNotchCore
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon (no accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextId: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Register ⌘⇧+key. Returns an id for unregistering.
    @discardableResult
    func register(keyCode: Int, modifiers: Int = cmdKey | shiftKey, handler: @escaping () -> Void) -> UInt32 {
        let id = nextId
        nextId += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x514E_4F54), id: id) // 'QNOT'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        }
        return id
    }

    /// True while a shortcut is being recorded – global hotkeys must not fire then.
    private(set) var isSuspended = false

    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended { unregisterAll() }
    }

    @discardableResult
    func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> UInt32 {
        register(keyCode: spec.keyCode, modifiers: spec.modifiers, handler: handler)
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }
}
