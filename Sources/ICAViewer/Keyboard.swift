import AppKit
import Carbon.HIToolbox
import ICAKit

/// Turns AppKit key events into ICA keyboard input: scancodes for mapped keys (the server's German
/// layout applies), Unicode for characters without a mapping and for Option-composed characters
/// (the macOS layout's Option characters differ from the Windows AltGr ones). Cmd+key becomes Ctrl+key.
final class KeyboardTranslator {
    weak var controller: SessionController?
    /// Scancodes currently down on the server, to release on focus loss.
    private var down: Set<KeyMap.Code> = []
    /// Option is held but Alt has not been sent yet (it might compose a character).
    private var pendingAlt: KeyMap.Code?
    private var altUsed = false

    private func send(_ code: KeyMap.Code, up: Bool) {
        if up { down.remove(code) } else { down.insert(code) }
        controller?.session.send { wd, _ in
            if code.extended { wd.keyScancodes([0xE0, code.code], up: up) } else { wd.keyScancode(code.code, up: up) }
        }
    }

    private func sendText(_ text: String) {
        controller?.session.send { wd, _ in
            for unit in text.utf16 {
                if wd.unicodeInsertMode { wd.keyUnicode(unit, flags: .insert) }
                else { wd.keyUnicode(unit, flags: []); wd.keyUnicode(unit, flags: .up) }
            }
        }
    }

    private func flushPendingAlt() {
        if let alt = pendingAlt { send(alt, up: false); pendingAlt = nil }
    }

    func keyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = KeyMap.scancode(event.keyCode)
        if flags.contains(.command) {
            // Cmd shortcuts not taken by our menu: Ctrl+key on the server (copy, paste, …).
            guard let code else { return }
            send(KeyMap.leftControl, up: false)
            send(code, up: false)
            send(code, up: true)
            send(KeyMap.leftControl, up: true)
            return
        }
        if flags.contains(.option), !flags.contains(.control), let chars = event.characters, !chars.isEmpty,
           chars != event.charactersIgnoringModifiers, chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
           chars.unicodeScalars.first.map({ $0.value < 0xF700 || $0.value > 0xF8FF }) ?? false {
            // Option-composed character (e.g. @ € | on a German Mac layout): send it as text, without Alt.
            sendText(chars)
            return
        }
        if let code {
            if pendingAlt != nil { flushPendingAlt(); altUsed = true }
            send(code, up: false)    // repeats send another make code, as on a PC
        } else if let chars = event.characters, !chars.isEmpty {
            sendText(chars)
        }
    }

    func keyUp(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        guard let code = KeyMap.scancode(event.keyCode), down.contains(code) else { return }
        send(code, up: true)
    }

    func flagsChanged(_ event: NSEvent) {
        let keyCode = Int(event.keyCode)
        guard let code = KeyMap.scancode(event.keyCode) else { return }
        let flags = event.modifierFlags
        if keyCode == kVK_CapsLock {
            // One flagsChanged per toggle: tap Caps Lock on the server.
            send(code, up: false)
            send(code, up: true)
            return
        }
        let isDown: Bool
        switch keyCode {
        case kVK_Shift, kVK_RightShift: isDown = flags.contains(.shift) && !down.contains(code)
        case kVK_Control, kVK_RightControl: isDown = flags.contains(.control) && !down.contains(code)
        case kVK_Option, kVK_RightOption: isDown = flags.contains(.option) && !(down.contains(code) || pendingAlt == code)
        default: return
        }
        if keyCode == kVK_Option || keyCode == kVK_RightOption {
            if isDown {
                pendingAlt = code
                altUsed = false
            } else if pendingAlt == code {
                // Lone Option tap: an Alt tap on the server (menu activation).
                pendingAlt = nil
                send(code, up: false)
                send(code, up: true)
            } else if down.contains(code) {
                send(code, up: true)
            }
            return
        }
        if isDown { send(code, up: false) } else if down.contains(code) { send(code, up: true) }
    }

    /// Releases every key the server thinks is down (focus left our windows).
    func releaseAll() {
        pendingAlt = nil
        for code in down { send(code, up: true) }
        down.removeAll()
    }

}
