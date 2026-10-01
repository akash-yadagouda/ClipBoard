import Carbon.HIToolbox

/// System-wide ⌘⇧V hotkey via Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission.
enum HotKey {
    private static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    /// Returns false if the shortcut could not be registered.
    static func register(_ action: @escaping () -> Void) -> Bool {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x434C_4950) /* 'CLIP' */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }
}
