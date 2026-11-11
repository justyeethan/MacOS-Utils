import Carbon.HIToolbox
import CoreGraphics

/// A key plus an exact set of modifiers, e.g. `alt-shift-h`.
nonisolated struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    nonisolated struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let cmd   = Modifiers(rawValue: 1 << 0)
        static let alt   = Modifiers(rawValue: 1 << 1)
        static let ctrl  = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)

        init(rawValue: UInt8) { self.rawValue = rawValue }

        init(cgFlags: CGEventFlags) {
            var m: Modifiers = []
            if cgFlags.contains(.maskCommand)   { m.insert(.cmd) }
            if cgFlags.contains(.maskAlternate) { m.insert(.alt) }
            if cgFlags.contains(.maskControl)   { m.insert(.ctrl) }
            if cgFlags.contains(.maskShift)     { m.insert(.shift) }
            self = m
        }
    }

    let keyCode: UInt16
    let modifiers: Modifiers
    /// Original text from the config, for display and error messages.
    let text: String

    init(keyCode: UInt16, modifiers: Modifiers, text: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.text = text
    }

    // Identity is key + modifiers only.
    static func == (a: KeyChord, b: KeyChord) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    func hash(into h: inout Hasher) { h.combine(keyCode); h.combine(modifiers) }

    var description: String { text }

    /// Parses AeroSpace notation: `alt-shift-h`, `alt-shift-semicolon`, `esc`, `shift-down`.
    /// Key names follow AeroSpace's list; only the qwerty preset is supported.
    static func parse(_ text: String) -> KeyChord? {
        let parts = text.split(separator: "-").map(String.init)
        guard let keyName = parts.last else { return nil }
        var mods: Modifiers = []
        for m in parts.dropLast() {
            switch m.lowercased() {
            case "cmd":   mods.insert(.cmd)
            case "alt":   mods.insert(.alt)
            case "ctrl":  mods.insert(.ctrl)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        guard let code = keyCodes[keyName] ?? keyCodes[keyName.lowercased()] else { return nil }
        return KeyChord(keyCode: UInt16(code), modifiers: mods, text: text)
    }

    /// Builds AeroSpace notation from a recorded key press: `alt-shift-h`. Nil for keys AeroSpace
    /// can't bind.
    static func text(keyCode: UInt16, modifiers: Modifiers) -> String? {
        guard let name = canonicalKeyNames[Int(keyCode)] else { return nil }
        var parts: [String] = []
        if modifiers.contains(.cmd)   { parts.append("cmd") }
        if modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if modifiers.contains(.alt)   { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(name)
        return parts.joined(separator: "-")
    }

    /// Key code → the spelling AeroSpace's docs use (`leftSquareBracket`, `keypadEnter`, …).
    static let canonicalKeyNames: [Int: String] = {
        var names: [Int: String] = [:]
        for (name, code) in keyCodes { names[code] = name }
        let camelCase = ["leftSquareBracket", "rightSquareBracket", "keypadClear", "keypadDecimalMark",
                         "keypadDivide", "keypadEnter", "keypadEqual", "keypadMinus", "keypadMultiply",
                         "keypadPlus"]
        for name in camelCase {
            if let code = keyCodes[name.lowercased()] { names[code] = name }
        }
        return names
    }()

    /// Sort order for listing bindings: fewer modifiers first, grouped by modifier set, letters
    /// and arrows before numbers, numbers numerically. Puts alt-h…l together and alt-1…9 together.
    static func displayOrder(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> (Int, String, Int, Int, String) {
            let parts = s.split(separator: "-").map { String($0).lowercased() }
            let name = parts.last ?? ""
            let rank = ["cmd": 0, "ctrl": 1, "alt": 2, "shift": 3]
            let mods = parts.dropLast().sorted { (rank[$0] ?? 9) < (rank[$1] ?? 9) }
            let number = Int(name)
            return (mods.count, mods.joined(separator: "-"), number == nil ? 0 : 1, number ?? 0, name)
        }
        return key(a) < key(b)
    }

    /// AeroSpace key names → macOS virtual key codes (ANSI / qwerty positions).
    static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "period": kVK_ANSI_Period,
            "comma": kVK_ANSI_Comma, "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash,
            "quote": kVK_ANSI_Quote, "semicolon": kVK_ANSI_Semicolon, "backtick": kVK_ANSI_Grave,
            "leftsquarebracket": kVK_ANSI_LeftBracket, "rightsquarebracket": kVK_ANSI_RightBracket,
            "space": kVK_Space, "enter": kVK_Return, "esc": kVK_Escape, "backspace": kVK_Delete,
            "tab": kVK_Tab,
            "left": kVK_LeftArrow, "down": kVK_DownArrow, "up": kVK_UpArrow, "right": kVK_RightArrow,
            "keypad0": kVK_ANSI_Keypad0, "keypad1": kVK_ANSI_Keypad1, "keypad2": kVK_ANSI_Keypad2,
            "keypad3": kVK_ANSI_Keypad3, "keypad4": kVK_ANSI_Keypad4, "keypad5": kVK_ANSI_Keypad5,
            "keypad6": kVK_ANSI_Keypad6, "keypad7": kVK_ANSI_Keypad7, "keypad8": kVK_ANSI_Keypad8,
            "keypad9": kVK_ANSI_Keypad9,
            "keypadclear": kVK_ANSI_KeypadClear, "keypaddecimalmark": kVK_ANSI_KeypadDecimal,
            "keypaddivide": kVK_ANSI_KeypadDivide, "keypadenter": kVK_ANSI_KeypadEnter,
            "keypadequal": kVK_ANSI_KeypadEquals, "keypadminus": kVK_ANSI_KeypadMinus,
            "keypadmultiply": kVK_ANSI_KeypadMultiply, "keypadplus": kVK_ANSI_KeypadPlus,
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (n, code) in fKeys.enumerated() { m["f\(n + 1)"] = code }
        return m
    }()
}
