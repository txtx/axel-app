import SwiftUI

enum SidebarSection: Hashable {
    case inbox(HintFilter)
    case queue(TaskFilter)
    case skills
    case context
    case team
    case terminals
}

enum HintFilter: String, CaseIterable, Identifiable {
    case pending = "Pending"
    case answered = "Resolved"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pending: "questionmark.circle"
        case .answered: "checkmark.circle"
        case .all: "tray.full"
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case queued = "Queued"
    case running = "Running"
    case completed = "Completed"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "play.circle"
        case .completed: "checkmark.circle"
        case .all: "square.stack"
        }
    }
}
