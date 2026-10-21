import Foundation

/// A key plus the modifiers held with it — what the shortcut field in
/// Settings records, and what the menu bar answers to system-wide.
///
/// Deliberately free of AppKit and Carbon. This is the part that has to be
/// stored, compared and printed, so keeping it to plain numbers means it can
/// be tested without a key window or an event loop; `GlobalHotkeyCenter`
/// owns the translation into the registration these numbers describe.
struct HotkeyBinding: Equatable, Sendable {
    /// Virtual key code — the hardware-position code AppKit and Carbon share,
    /// so it survives a change of keyboard layout the way a character
    /// wouldn't.
    let keyCode: UInt16
    /// Narrowed to the four modifiers a shortcut may use. Raw values match
    /// `NSEvent.ModifierFlags`, which is where they come from.
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.all)
    }

    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: UInt
        init(rawValue: UInt) { self.rawValue = rawValue }

        static let shift = Modifiers(rawValue: 1 << 17)
        static let control = Modifiers(rawValue: 1 << 18)
        static let option = Modifiers(rawValue: 1 << 19)
        static let command = Modifiers(rawValue: 1 << 20)

        static let all: Modifiers = [.shift, .control, .option, .command]

        /// In the order the system prints them on a menu item.
        var symbols: [String] {
            var symbols: [String] = []
            if contains(.control) { symbols.append("⌃") }
            if contains(.option) { symbols.append("⌥") }
            if contains(.shift) { symbols.append("⇧") }
            if contains(.command) { symbols.append("⌘") }
            return symbols
        }
    }

    /// A shortcut the whole system listens for has to be one the system
    /// can't mistake for typing, so a bare key — or one held with shift
    /// alone — isn't offered.
    var isValid: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command])
            && !Self.isModifierKey(keyCode)
    }

    /// The pieces the recorder draws as separate key caps.
    var symbols: [String] { modifiers.symbols + [Self.label(for: keyCode)] }

    /// One string, the way a menu item would show it.
    var displayString: String { symbols.joined() }

    // MARK: Storage

    /// Stored as one string so a binding is a single defaults key that can be
    /// read, and removed, atomically.
    var storageValue: String { "\(modifiers.rawValue):\(keyCode)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2,
              let modifiers = UInt(parts[0]),
              let keyCode = UInt16(parts[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: Modifiers(rawValue: modifiers))
    }

    // MARK: Key names

    /// True for the keys that only ever qualify another key, which can't be
    /// a shortcut on their own.
    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    /// What to print on the key cap. Unknown codes fall back to the number so
    /// a shortcut is never drawn as an empty box.
    static func label(for keyCode: UInt16) -> String {
        keyLabels[keyCode] ?? "#\(keyCode)"
    }

    private static let keyLabels: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        65: ".", 67: "*", 69: "+", 71: "⌧", 75: "/", 76: "↩", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "?⃝", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
