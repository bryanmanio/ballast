import SwiftUI

/// Plain, with a press that registers under the finger.
///
/// `.plain` gives no pressed state at all on macOS, so every control in the
/// menu felt the same whether or not the click landed. The dip is small
/// enough to read as physical rather than as an animation.
struct PressableButtonStyle: ButtonStyle {
    /// Below about 0.95 the dip reads as a bounce rather than a press.
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            // Scoped to the press alone: anything else the label animates —
            // a glyph swap, a hover reveal — keeps its own timing, and a
            // release part-way through the dip interrupts it cleanly.
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Secondary at rest, primary under the pointer: enough to say "this is the
/// one you're on" without the menu lighting up as the cursor crosses it.
private struct HoverHighlight: ViewModifier {
    var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            // A disabled control that brightened would promise a click it
            // won't take.
            .foregroundStyle(isOn || (isHovering && isEnabled) ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    /// For quiet controls drawn in `secondary`. Replaces their
    /// `foregroundStyle`, so it has to be the only one setting it. A control
    /// that `isOn` — a selected segment, a toggled button — stays lit.
    func hoverHighlight(isOn: Bool = false) -> some View {
        modifier(HoverHighlight(isOn: isOn))
    }
}
