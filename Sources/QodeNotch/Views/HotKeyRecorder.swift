import AppKit
import Carbon.HIToolbox
import QodeNotchCore
import SwiftUI

/// Button that records a new global shortcut: click, press the keys, done.
/// Escape cancels; at least one of ⌘ ⌃ ⌥ is required so plain typing can't be stolen.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec
    var defaultSpec: HotKeySpec

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(recording ? "Tasten drücken …" : spec.display)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if spec != defaultSpec && !recording {
                Button("Standard") { spec = defaultSpec }
                    .buttonStyle(.borderless)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        hint = nil
        recording = true
        HotKeyCenter.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKeyCenter.shared.setSuspended(false)
            AppDelegate.shared?.reloadHotKeys()
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stop()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            hint = "Bitte mit ⌘, ⌃ oder ⌥ kombinieren"
            return
        }
        var mods = 0
        if flags.contains(.command) { mods |= HotKeySpec.cmd }
        if flags.contains(.shift) { mods |= HotKeySpec.shift }
        if flags.contains(.option) { mods |= HotKeySpec.option }
        if flags.contains(.control) { mods |= HotKeySpec.control }
        spec = HotKeySpec(keyCode: Int(event.keyCode), modifiers: mods, key: Self.keyName(event))
        hint = nil
        stop()
    }

    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let chars = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            return chars.isEmpty ? "?" : chars
        }
    }
}
