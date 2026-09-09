import AppKit
import Carbon.HIToolbox
import MycoEngine

/// Registers one global shortcut per profile and switches to the profile when it is pressed.
/// A shortcut works whichever app is frontmost and needs no permission from the user.
@MainActor
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var profiles: [UInt32: UUID] = [:]
    private var registered: [(UUID, Hotkey?)] = []
    private var model: AppModel?
    private var handler: EventHandlerRef?

    /// Follows the profiles in the model and keeps the registered shortcuts equal to theirs.
    func watch(_ model: AppModel) {
        self.model = model
        if handler == nil { installHandler() }
        observe()
    }

    private func observe() {
        withObservationTracking {
            guard let model else { return }
            let wanted = model.settings.profiles.map { ($0.id, $0.hotkey) }
            if !wanted.elementsEqual(registered, by: { $0 == $1 }) { register(wanted) }
        } onChange: {
            Task { @MainActor in self.observe() }
        }
    }

    private func register(_ wanted: [(UUID, Hotkey?)]) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
        profiles = [:]
        for (index, (id, hotkey)) in wanted.enumerated() {
            guard let hotkey else { continue }
            let number = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4D79_636F), id: number)
            let status = RegisterEventHotKey(
                UInt32(hotkey.keyCode), hotkey.carbonModifiers, hotKeyID,
                GetEventDispatcherTarget(), 0, &ref)
            guard status == noErr, let ref else { continue }
            refs.append(ref)
            profiles[number] = id
        }
        registered = wanted
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                MainActor.assumeIsolated { Hotkeys.shared.pressed(hotKeyID.id) }
                return noErr
            },
            1, &spec, nil, &handler)
    }

    private func pressed(_ number: UInt32) {
        guard let id = profiles[number], let model,
              model.settings.profiles.contains(where: { $0.id == id }) else { return }
        model.settings.activeProfileID = id
    }
}

extension Hotkey {
    /// The four modifier bits a shortcut can carry.
    static let modifierMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    /// The shortcut as the menu bar would print it, for example ⌃⌥⇧⌘G.
    var display: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// Builds a shortcut from a key press, or nil when the press carries no modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Hotkey.modifierMask)
        guard !flags.isEmpty else { return nil }
        let names: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 123: "←", 124: "→", 125: "↑", 126: "↓",
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        ]
        let key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !key.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, key: key)
    }
}
