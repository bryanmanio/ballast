import AppKit
import Carbon.HIToolbox

/// Registers the one system-wide shortcut Ballast listens for.
///
/// Carbon's hot key API is the only route to a global shortcut that doesn't
/// ask for Accessibility access: `NSEvent`'s global monitor sees every
/// keystroke in every app, so macOS gates it behind a permission prompt that
/// would be wildly out of proportion to opening a menu.
@MainActor
@Observable
final class GlobalHotkeyCenter {
    static let shared = GlobalHotkeyCenter()

    /// What the shortcut does. Set by the app, which is the only place that
    /// can reach the menu bar item.
    @ObservationIgnored var action: () -> Void = {}

    /// Set when the system refused the combination — nearly always because
    /// another app registered it first. Shown next to the shortcut field,
    /// since otherwise the key would just quietly do nothing.
    private(set) var isUnavailable = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var binding: HotkeyBinding?
    /// Held down while the recorder is open, so pressing the current
    /// shortcut to replace it opens the menu instead of being recorded.
    private var isSuspended = false

    private init() {}

    /// Makes `binding` the live shortcut, replacing whatever was registered
    /// before. `nil` leaves Ballast listening for nothing.
    func apply(_ binding: HotkeyBinding?) {
        self.binding = binding
        reregister()
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregister()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        reregister()
    }

    // MARK: Registration

    private func reregister() {
        unregister()
        isUnavailable = false
        guard !isSuspended, let binding, binding.isValid else { return }

        installHandler()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            Self.carbonModifiers(binding.modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotKeyRef = ref
        } else {
            isUnavailable = true
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    /// One handler for the lifetime of the app; only the registration behind
    /// it changes as the shortcut does.
    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ in
                // Carbon dispatches hot keys on the main thread, which is
                // the thread this class is isolated to.
                MainActor.assumeIsolated { GlobalHotkeyCenter.shared.action() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handlerRef
        )
    }

    /// Carbon predates `NSEvent.ModifierFlags` and uses its own bits.
    private static func carbonModifiers(_ modifiers: HotkeyBinding.Modifiers) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Four-character code identifying our hot keys to the system: 'BLST'.
    private static let signature: OSType = 0x424C_5354
}
