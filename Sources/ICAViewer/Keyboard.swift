import AppKit
import Carbon.HIToolbox
import ICAKit

/// The parts of a key event the translator reads: from an NSEvent of this process, or from one a helper
/// app forwarded (docs/99 §12 phase 1). `characters` are never read from a flagsChanged event (AppKit
/// raises for them).
struct KeyInput {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    var characters: String?
    var charactersIgnoringModifiers: String?
    var isARepeat: Bool

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, characters: String? = nil,
         charactersIgnoringModifiers: String? = nil, isARepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.isARepeat = isARepeat
    }

    init(_ event: NSEvent) {
        let keyEvent = event.type == .keyDown || event.type == .keyUp
        self.init(keyCode: event.keyCode, modifierFlags: event.modifierFlags,
                  characters: keyEvent ? event.characters : nil,
                  charactersIgnoringModifiers: keyEvent ? event.charactersIgnoringModifiers : nil,
                  isARepeat: event.type == .keyDown && event.isARepeat)
    }
}

/// Turns AppKit key events into ICA keyboard input through ICAKit's `KeyTranslator` (docs/30 §14.1a): scancodes for
/// keys, Unicode for Option-composed characters and, after a layout switch, for printable keys; Cmd+key becomes Ctrl+key.
final class KeyboardTranslator {
    weak var controller: SessionController?
    private let core = KeyTranslator()
    private var composer = DeadKeyComposer()
    /// The Mac's input source differs from the layout announced at logon (D141): printable characters go as Unicode
    /// text, as the stock client always does, so they stay right after a mid-session switch. Set by the controller.
    var textForPrintables: Bool {
        get { core.textForPrintables }
        set { core.textForPrintables = newValue }
    }
    /// The KLID announced at logon (shortcut letters in text mode follow it).
    var sessionLayout: UInt32 {
        get { core.sessionLayout }
        set { core.sessionLayout = newValue }
    }

    /// Keys go through the controller's input path, which may briefly hold them (and the mouse) behind
    /// a clipboard announce; keys are queued while suspended, never dropped.
    private func emit(_ outputs: [KeyOutput]) {
        guard !outputs.isEmpty else { return }
        controller?.noteActivity()
        controller?.sendInput(dropWhileSuspended: false) { wd in wd.send(outputs) }
    }

    /// Cmd-V or Ctrl-V, by character as the Edit menu matches it (so Dvorak's V counts too).
    private func syncClipboardIfPaste(_ event: KeyInput, _ flags: NSEvent.ModifierFlags) {
        guard flags.contains(.command) || flags.contains(.control) else { return }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Copy, cut and print shortcuts: a refused redirection gets its one-time notice (D118).
        if let key, ["c", "x", "p"].contains(key) { controller?.shortcutAttempt(key) }
        guard key == "v" || (key == nil && event.keyCode == UInt16(kVK_ANSI_V)) else { return }
        controller?.clipboardBeforePaste()
    }

    private func stroke(_ event: KeyInput) -> KeyStroke {
        let flags = event.modifierFlags
        var m: KeyStroke.Modifiers = []
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        // A shortcut on a punctuation key in text mode is placed by the key's characters (D167).
        let levels = core.textForPrintables && (m.contains(.command) || m.contains(.control)) ? KeyMap.characters(keyCode: event.keyCode) : []
        return KeyStroke(keyCode: event.keyCode, modifiers: m, characters: event.characters,
                         charactersIgnoringModifiers: event.charactersIgnoringModifiers, isARepeat: event.isARepeat,
                         keyCharacters: levels)
    }

    func keyDown(_ event: NSEvent) { keyDown(KeyInput(event)) }
    func keyUp(_ event: NSEvent) { keyUp(KeyInput(event)) }
    func flagsChanged(_ event: NSEvent) { flagsChanged(KeyInput(event)) }

    func keyDown(_ event: KeyInput) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // The pasteboard goes to the host before the paste key does (docs/70 §5.4).
        if !event.isARepeat { syncClipboardIfPaste(event, flags) }
        var key = stroke(event)
        if flags.contains(.command) || flags.contains(.control) {
            composer.reset()
        } else if composer.isComposing || (event.characters ?? "").isEmpty && KeyMap.isCharacterKey(event.keyCode) {
            // AppKit does not compose dead keys for us (no input context): the layout's composition (D167).
            let afterDeadKey = composer.isComposing
            if let composed = composer.characters(keyCode: event.keyCode, shift: flags.contains(.shift),
                                                  option: flags.contains(.option), capsLock: flags.contains(.capsLock)) {
                key.characters = composed
                key.composed = afterDeadKey && !composed.isEmpty
            }
        }
        emit(core.keyDown(key))
    }

    func keyUp(_ event: KeyInput) { emit(core.keyUp(stroke(event))) }

    func flagsChanged(_ event: KeyInput) { emit(core.flagsChanged(stroke(event))) }

    /// An Edit menu item a helper app's menu bar sent (docs/99 §12 phase 2): the same path as its Cmd
    /// shortcut, so Ctrl+letter on the server and, for Paste, the clipboard sync first.
    func menuShortcut(_ letter: String) {
        guard let keyCode = KeyMap.keyCode(typing: letter) else { return }
        let input = KeyInput(keyCode: keyCode, modifierFlags: .command, characters: letter, charactersIgnoringModifiers: letter)
        keyDown(input)
        keyUp(input)
    }

    /// Text the macOS text input system inserted (Emoji & Symbols; D167), from our view or a helper app's.
    func insertText(_ text: String) {
        let out = core.insertText(text)
        if !out.isEmpty { vlog("keyboard: inserted \(text.unicodeScalars.count) character(s) from the text input system") }
        emit(out)
    }

    /// Releases every key the server thinks is down (focus left our windows).
    func releaseAll() {
        composer.reset()
        emit(core.releaseAll())
    }
}
