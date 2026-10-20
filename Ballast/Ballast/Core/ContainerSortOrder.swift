import Foundation

enum ContainerSortOrder: String, CaseIterable, Sendable, Identifiable {
    /// Anything needing attention first, alphabetical within each status.
    case status
    case name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: "Status"
        case .name: "Name"
        }
    }
}
