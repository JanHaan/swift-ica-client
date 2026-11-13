import AppHostKit
import Carbon.HIToolbox
import ICAKit

/// The launcher's global shortcut (docs/99 §12.13; ⌃⌥⌘L by default, approved by the user, D64): a Carbon hot
/// key, so no Accessibility permission is needed and no key event is read. Registered exclusively: if another
/// app already holds the combination, ours stays unregistered (logged, and Settings says so) instead of
/// stealing it. The key is the one that types the letter in the keyboard layout at registration (as the Edit
/// items, `KeyMap.keyCode(typing:)`). Off in Settings = nothing registered. Main thread only.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    enum State: Equatable { case off, registered, taken, failed(OSStatus) }

    private(set) var state = State.off
    private(set) var current = LauncherHotKey.off
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static let signature: OSType = 0x4943_4176      // 'ICAv'

    /// The stored choice (Settings), default ⌃⌥⌘L.
    static var stored: LauncherHotKey {
        get { LauncherHotKey.stored(UserDefaults.standard.string(forKey: LauncherHotKey.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.raw, forKey: LauncherHotKey.defaultsKey) }
    }

    /// (Re-)registers `hotKey`; `action` runs on main when it is pressed.
    func apply(_ hotKey: LauncherHotKey, action: @escaping () -> Void) {
        self.action = action
        unregister()
        current = hotKey
        guard let shortcut = hotKey.shortcut else {
            state = .off
            return vlog("launcher shortcut: off")
        }
        guard installHandler(), let code = KeyMap.keyCode(typing: shortcut.key) else {
            state = .failed(OSStatus(eventNotHandledErr))
            return vlog("launcher shortcut \(shortcut): no event handler or key; not registered")
        }
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), hotKey.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        switch status {
        case noErr:
            ref = hotKeyRef
            state = .registered
            vlog("launcher shortcut \(shortcut): registered")
        case OSStatus(eventHotKeyExistsErr):
            state = .taken
            vlog("launcher shortcut \(shortcut): already taken by another app; not registered")
        default:
            state = .failed(status)
            vlog("launcher shortcut \(shortcut): RegisterEventHotKey failed (\(status))")
        }
    }

    /// Settings saved another choice: stored, and registered with the same action.
    func change(to hotKey: LauncherHotKey) {
        Self.stored = hotKey
        if HelperManager.enabled { HelperManager.shared.launcherShortcutChanged() }
        guard let action, hotKey != current || state != .registered else { return }
        apply(hotKey, action: action)
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon calls this on the main thread, from the event loop (not inside a dispatch block).
            GlobalHotKey.shared.pressed()
            return noErr
        }, 1, &spec, nil, &handler)
        return status == noErr
    }

    private func pressed() {
        vlog("launcher shortcut pressed")
        action?()
    }
}
