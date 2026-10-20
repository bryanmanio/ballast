import SwiftUI

/// Visual vocabulary for the four statuses.
///
/// Each status differs in shape as well as colour, so the list is readable
/// without colour vision — the thing a row of green and red dots fails at.
extension ServiceStatus {
    var symbolName: String {
        switch self {
        case .healthy: "circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .down: "xmark.circle.fill"
        case .unknown: "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .degraded: .orange
        case .down: .red
        case .unknown: .secondary
        }
    }

    /// Symbol for the menu bar itself, where only a template image survives.
    var menuBarSymbolName: String {
        switch self {
        case .healthy: "circle.circle"
        case .degraded: "exclamationmark.circle.fill"
        case .down: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .down: "Down"
        case .unknown: "Unknown"
        }
    }
}

struct StatusIndicator: View {
    let status: ServiceStatus
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: size))
            .foregroundStyle(status.tint)
            // Fixed width keeps names aligned no matter which glyph is used.
            .frame(width: 14)
            .accessibilityLabel(status.label)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(ServiceStatus.allCases, id: \.self) { status in
            HStack {
                StatusIndicator(status: status)
                Text(status.label)
            }
        }
    }
    .padding()
}
