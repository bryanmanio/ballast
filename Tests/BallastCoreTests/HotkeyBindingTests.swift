import Foundation
import Testing
@testable import BallastCore

@Suite("Hotkey bindings")
struct HotkeyBindingTests {

    @Test("Modifiers outside the four a shortcut may use are dropped")
    func narrowsModifiers() {
        // Caps lock (1 << 16) and function (1 << 23) come along on a real
        // NSEvent and would make an otherwise equal binding compare unequal.
        let binding = HotkeyBinding(
            keyCode: 11,
            modifiers: HotkeyBinding.Modifiers(rawValue: (1 << 16) | (1 << 20) | (1 << 23))
        )
        #expect(binding.modifiers == .command)
        #expect(binding == HotkeyBinding(keyCode: 11, modifiers: .command))
    }

    @Test("A shortcut needs a modifier the system can't mistake for typing")
    func validity() {
        #expect(HotkeyBinding(keyCode: 11, modifiers: [.option, .command]).isValid)
        #expect(HotkeyBinding(keyCode: 11, modifiers: .control).isValid)
        // Shift alone is just a capital letter.
        #expect(!HotkeyBinding(keyCode: 11, modifiers: .shift).isValid)
        #expect(!HotkeyBinding(keyCode: 11, modifiers: []).isValid)
        // A modifier key on its own can't be the key either.
        #expect(!HotkeyBinding(keyCode: 55, modifiers: [.option, .command]).isValid)
    }

    @Test("Printed in the order a menu item would print them")
    func symbols() {
        let binding = HotkeyBinding(keyCode: 11, modifiers: [.command, .shift, .option, .control])
        #expect(binding.symbols == ["⌃", "⌥", "⇧", "⌘", "B"])
        #expect(binding.displayString == "⌃⌥⇧⌘B")
    }

    @Test("Unknown key codes still print as something")
    func unknownKey() {
        #expect(HotkeyBinding.label(for: 200) == "#200")
    }

    @Test("Survives a round trip through defaults")
    func storage() {
        let binding = HotkeyBinding(keyCode: 49, modifiers: [.control, .option])
        #expect(HotkeyBinding(storageValue: binding.storageValue) == binding)
    }

    @Test("Storage that isn't a binding is refused rather than guessed at")
    func rejectsJunk() {
        #expect(HotkeyBinding(storageValue: "") == nil)
        #expect(HotkeyBinding(storageValue: "1048576") == nil)
        #expect(HotkeyBinding(storageValue: "nope:11") == nil)
    }
}
