import SwiftUI

/// The menu bar item itself.
///
/// The system renders this as a template image, which strips colour, so
/// status is carried by the glyph plus a count of what's wrong — which also
/// means it reads at a glance without opening anything.
struct MenuBarLabel: View {
    let status: ServiceStatus
    let problemCount: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: status.menuBarSymbolName)
            if problemCount > 0 {
                Text("\(problemCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch problemCount {
        case 0: "Ballast — all services \(status.label.lowercased())"
        case 1: "Ballast — 1 service needs attention"
        default: "Ballast — \(problemCount) services need attention"
        }
    }
}
