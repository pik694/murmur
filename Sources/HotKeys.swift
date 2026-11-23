import Carbon

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// This is deliberate: registered hotkeys are delivered by the system only for the exact
/// key combos we ask for, so Murmur never sees any other keystroke and needs no
/// Input Monitoring permission (unlike apps that install a keyboard event tap).
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns an id for `unregister`, or nil if the combo is taken by another app.
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers,
                                         EventHotKeyID(signature: OSType(0x4D52_4D52), id: id), // "MRMR"
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id else { return }
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}

struct KeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let returnKey = KeyCombo(keyCode: UInt32(kVK_Return), modifiers: 0, label: "⏎")
    static let shiftReturn = KeyCombo(keyCode: UInt32(kVK_Return), modifiers: UInt32(shiftKey), label: "⇧⏎")
    static let escape = KeyCombo(keyCode: UInt32(kVK_Escape), modifiers: 0, label: "⎋")

    /// Choices offered in the menu for starting/stopping dictation.
    static let startChoices: [KeyCombo] = [
        KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), label: "⌥ Space"),
        KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥ Space"),
        KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘ D"),
        KeyCombo(keyCode: UInt32(kVK_F5), modifiers: 0, label: "F5"),
    ]
}
