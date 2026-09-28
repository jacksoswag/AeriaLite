import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts for the transport, read from config.json's `keybinds`. Carbon hot keys
/// rather than an event tap: they need no Accessibility grant, and only a matching chord is taken
/// from the focused app, so everything else keeps its keyboard.
@MainActor final class Hotkeys {
    private static let signature: OSType = 0x4165_724C          // 'AerL'
    /// Tighter than the system double-click interval, which runs to half a second and would make
    /// two deliberate presses of the backdrop key read as a quit.
    private static let doubleTap: TimeInterval = 0.35

    /// Everything one chord does. `quit` rides on a chord that may already have a single-press
    /// action, since Carbon registers each chord once.
    private struct Binding {
        var name: String
        var press: (() -> Void)?
        var toggles = false             // a second press undoes the first
        var quits = false
        var last: TimeInterval = 0
    }

    private var registered: [EventHotKeyRef] = []
    private var bindings: [UInt32: Binding] = [:]
    private var handler: EventHandlerRef?
    private var bound: Settings.Keybinds?

    /// Replaces whatever was registered. Called on launch and again each time the panel reloads
    /// the config, so an edit takes effect the next time the panel opens, like every other key.
    func bind(_ keys: Settings.Keybinds, to state: AppState) {
        guard keys != bound else { return }
        bound = keys
        installHandler()
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        bindings.removeAll()

        let table: [(name: String, spec: String, press: (() -> Void)?, toggles: Bool)] = [
            ("next", keys.next, { state.next() }, false),
            ("previous", keys.previous, { state.previous() }, false),
            ("playPause", keys.playPause, { state.paused.toggle() }, true),
            ("backdrop", keys.backdrop, { state.toggleBackdrop() }, true),
            ("quit", keys.quit, nil, false),
        ]
        var byChord: [Chord: UInt32] = [:]
        for entry in table where !entry.spec.isEmpty {
            guard let chord = Chord(entry.spec) else {
                warn("keybinds.\(entry.name): cannot read \"\(entry.spec)\"")
                continue
            }
            if let id = byChord[chord] {
                // only quit may share, because it is the double tap and the others are single
                if entry.press == nil { bindings[id]?.quits = true }
                else if bindings[id]?.press == nil {
                    bindings[id]?.name = entry.name
                    bindings[id]?.press = entry.press
                    bindings[id]?.toggles = entry.toggles
                } else {
                    warn("keybinds.\(entry.name): \"\(entry.spec)\" is already bound to \(bindings[id]!.name)")
                }
                continue
            }
            let id = EventHotKeyID(signature: Hotkeys.signature, id: UInt32(byChord.count + 1))
            var ref: EventHotKeyRef?
            // eventHotKeyExistsErr when another app already holds it
            guard RegisterEventHotKey(chord.code, chord.modifiers, id, GetApplicationEventTarget(),
                                      0, &ref) == noErr, let ref else {
                warn("keybinds.\(entry.name): \"\(entry.spec)\" is already taken")
                continue
            }
            registered.append(ref)
            byChord[chord] = id.id
            bindings[id.id] = Binding(name: entry.name, press: entry.press, toggles: entry.toggles,
                                      quits: entry.press == nil)
        }
    }

    /// The first press always acts at once, so a single tap never waits to find out whether a
    /// second is coming. A quick second press then undoes a toggle before quitting, which leaves
    /// playback and the backdrop as they were rather than flipped on the way out.
    private func pressed(_ id: UInt32) {
        guard var binding = bindings[id] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if binding.quits, now - binding.last < Hotkeys.doubleTap {
            if binding.toggles { binding.press?() }
            NSApplication.shared.terminate(nil)
            return
        }
        binding.last = now
        bindings[id] = binding
        binding.press?()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        // Hot key events are delivered on the main thread, through the app's own event target.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID), nil,
                                         MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == Hotkeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let me = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.pressed(id.id) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("aerialite: \(message)\n".utf8))
    }
}

/// One key plus modifiers, spelled the way people write shortcuts: `f9`, `cmd+shift+space`,
/// `ctrl+opt+right`. Case and spaces around the `+` do not matter.
struct Chord: Hashable {
    let code: UInt32
    let modifiers: UInt32

    init(rawCode: UInt32, modifiers: UInt32) {
        self.code = rawCode
        self.modifiers = modifiers
    }

    init?(_ spec: String) {
        let parts = spec.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = parts.last, let code = Chord.keys[key] else { return nil }
        var modifiers: UInt32 = 0
        for name in parts.dropLast() {
            guard let flag = Chord.modifierNames[name] else { return nil }
            modifiers |= flag
        }
        self.code = UInt32(code)
        self.modifiers = modifiers
    }

    private static let modifierNames: [String: UInt32] = [
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
        "opt": UInt32(optionKey), "option": UInt32(optionKey), "alt": UInt32(optionKey),
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
    ]

    /// ANSI positions, which is what Carbon's virtual key codes name.
    private static let keys: [String: Int] = {
        var table: [String: Int] = [
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11,
            "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16,
            "f17": kVK_F17, "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete,
            "forwarddelete": kVK_ForwardDelete, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            "`": kVK_ANSI_Grave,
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
                       kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
                       kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
                       kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        for (offset, code) in letters.enumerated() {
            table[String(UnicodeScalar(UInt8(ascii: "a") + UInt8(offset)))] = code
        }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { table[String(digit)] = code }
        return table
    }()
}
