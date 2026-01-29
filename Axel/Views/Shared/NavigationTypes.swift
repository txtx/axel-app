import SwiftUI

enum SidebarSection: Hashable {
    case inbox(HintFilter)
    case queue(TaskFilter)
    case optimizations(OptimizationsFilter)
    case team
    case terminals
}

enum OptimizationsFilter: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case skills = "Skills"
    case context = "Context"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .skills: "hammer.fill"
        case .context: "briefcase.fill"
        }
    }
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
    /// Shows tasks with .backlog status (unassigned, general pool)
    case backlog = "Backlog"
    /// Shows tasks with .queued status (assigned to a terminal's queue)
    case upNext = "Up Next"
    case running = "Running"
    case completed = "Completed"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .backlog: "tray"
        case .upNext: "clock"
        case .running: "play.circle"
        case .completed: "checkmark.circle"
        case .all: "square.stack"
        }
    }
}
