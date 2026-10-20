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
