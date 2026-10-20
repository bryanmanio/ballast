import AppKit
import SwiftUI

/// The shortcut field: the current combination drawn as key caps, which
/// becomes a recorder when clicked.
///
/// Recording is done with a local event monitor rather than a focusable
/// `NSView`, because the thing being captured is exactly what the
/// responder chain would otherwise act on — ⌘W would close the window
/// instead of being recorded.
struct HotkeyField: View {
    @Binding var binding: HotkeyBinding?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// Set when a key is pressed without a qualifying modifier, so the
    /// requirement is explained at the moment it's broken.
    @State private var needsModifier = false

    private let hotkeys = GlobalHotkeyCenter.shared

    var body: some View {
        HStack(spacing: 6) {
            Button { isRecording ? stop() : start() } label: {
                content
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(minHeight: 24)
                    .background(background)
                    .contentShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Press the keys you want to use" : "Click to record a new shortcut")
            // The key caps are drawn, so VoiceOver would otherwise read the
            // combination out one glyph at a time, or not at all.
            .accessibilityLabel("Keyboard shortcut")
            .accessibilityValue(accessibilityValue)

            if binding != nil && !isRecording {
                Button { clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the shortcut")
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isRecording)
        .onDisappear(perform: stop)
    }

    @ViewBuilder
    private var content: some View {
        if isRecording {
            Text(needsModifier ? "Add ⌘, ⌃ or ⌥" : "Type a shortcut")
                .font(.system(size: 11))
                .foregroundStyle(needsModifier ? Color.orange : Color.secondary)
                .frame(minWidth: 96)
        } else if let binding {
            HStack(spacing: 3) {
                ForEach(Array(binding.symbols.enumerated()), id: \.offset) { _, symbol in
                    KeyCap(symbol: symbol)
                }
            }
        } else {
            Text("Record Shortcut")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: 96)
        }
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(isRecording ? 0.10 : 0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.08),
                                  lineWidth: isRecording ? 1.5 : 1)
            }
    }

    private var accessibilityValue: String {
        if isRecording { return "Recording — press the keys you want to use" }
        return binding?.displayString ?? "None"
    }

    // MARK: Recording

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        needsModifier = false
        // Otherwise the shortcut being replaced would fire while we wait
        // for the user to press it.
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            // Swallowed: an unhandled key event in a window with no text
            // field to take it just beeps.
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
        needsModifier = false
        hotkeys.resume()
    }

    private func clear() {
        binding = nil
        stop()
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotkeyBinding.Modifiers(rawValue: event.modifierFlags.rawValue)

        // Escape and delete are how the field is dismissed and emptied, so
        // they're only recordable with a modifier held.
        if modifiers.isDisjoint(with: [.command, .control, .option]) {
            switch event.keyCode {
            case 53: stop(); return
            case 51, 117: clear(); return
            default: break
            }
        }

        guard !HotkeyBinding.isModifierKey(event.keyCode) else { return }

        let candidate = HotkeyBinding(keyCode: event.keyCode, modifiers: modifiers)
        guard candidate.isValid else {
            needsModifier = true
            return
        }

        binding = candidate
        stop()
    }
}

/// One key of a shortcut, drawn the way the keyboard itself labels it.
private struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium))
            .frame(minWidth: 20)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}
