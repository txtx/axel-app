import SwiftUI
import SwiftData

#if os(visionOS)

// MARK: - Window Identifiers

enum CommandWindow: String, CaseIterable {
    case tasks = "TasksPanel"
    case agents = "AgentsPanel"
    case inbox = "InboxPanel"

    var title: String {
        switch self {
        case .tasks: return "TASKS"
        case .agents: return "AGENTS"
        case .inbox: return "INBOX"
        }
    }

    var icon: String {
        switch self {
        case .tasks: return "checklist"
        case .agents: return "cpu"
        case .inbox: return "tray.full"
        }
    }

    var accentColor: Color {
        switch self {
        case .tasks: return .cyan
        case .agents: return .accentPurple
        case .inbox: return .orange
        }
    }
}

// MARK: - Tasks Panel

struct TasksPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.createdAt, order: .reverse) private var tasks: [WorkTask]
    @State private var selectedFilter: TaskFilter = .all

    enum TaskFilter: String, CaseIterable {
        case all = "All"
        case running = "Running"
        case backlog = "Backlog"
        case completed = "Done"
    }

    var filteredTasks: [WorkTask] {
        switch selectedFilter {
        case .all: return tasks
        case .running: return tasks.filter { $0.status == "running" }
        case .backlog: return tasks.filter { $0.status == "backlog" || $0.status == "queued" }
        case .completed: return tasks.filter { $0.status == "completed" }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            CommandPanelHeader(
                title: "TASKS",
                icon: "checklist",
                accentColor: .cyan,
                count: filteredTasks.count
            )

            // Filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TaskFilter.allCases, id: \.self) { filter in
                        FilterPill(
                            title: filter.rawValue,
                            isSelected: selectedFilter == filter,
                            accentColor: .cyan
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedFilter = filter
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()
                .background(Color.cyan.opacity(0.3))

            // Task list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredTasks) { task in
                        TaskRow(task: task)
                    }

                    if filteredTasks.isEmpty {
                        EmptyStateView(
                            icon: "checkmark.circle",
                            message: "No tasks",
                            accentColor: .cyan
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(16)
            }
        }
        .background(PanelBackground())
    }
}

struct TaskRow: View {
    let task: WorkTask

    var statusColor: Color {
        switch task.status {
        case "running": return .green
        case "completed": return .gray
        case "failed": return .red
        default: return .yellow
        }
    }

    var statusIcon: String {
        switch task.status {
        case "running": return "play.circle.fill"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        default: return "clock.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Image(systemName: statusIcon)
                .font(.system(size: 20))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let desc = task.taskDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Progress or time
            if task.status == "running" {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(task.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Agents Panel

struct AgentsPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.name) private var skills: [Skill]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            CommandPanelHeader(
                title: "SKILLS",
                icon: "cpu",
                accentColor: .accentPurple,
                count: skills.count
            )

            // Status overview
            HStack(spacing: 16) {
                AgentStatusBadge(label: "Total", count: skills.count, color: .accentPurple)
                AgentStatusBadge(label: "Ready", count: skills.count, color: .green)
            }
            .padding(16)

            Divider()
                .background(Color.accentPurple.opacity(0.3))

            // Agent list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(skills) { skill in
                        AgentRow(skill: skill)
                    }

                    if skills.isEmpty {
                        EmptyStateView(
                            icon: "cpu",
                            message: "No skills configured",
                            accentColor: .accentPurple
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(16)
            }
        }
        .background(PanelBackground())
    }
}

struct AgentStatusBadge: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.1))
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

struct AgentRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)
                .shadow(color: .green.opacity(0.5), radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("Updated \(skill.updatedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Ready indicator
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.accentPurple.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Inbox Panel

struct InboxPanelView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hint.createdAt, order: .reverse) private var allHints: [Hint]

    var pendingHints: [Hint] {
        allHints.filter { $0.status == "pending" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with urgent indicator
            CommandPanelHeader(
                title: "INBOX",
                icon: "tray.full",
                accentColor: .orange,
                count: pendingHints.count,
                isUrgent: !pendingHints.isEmpty
            )

            Divider()
                .background(Color.orange.opacity(0.3))

            // Message list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(pendingHints) { hint in
                        InboxRow(hint: hint)
                    }

                    if pendingHints.isEmpty {
                        EmptyStateView(
                            icon: "tray",
                            message: "All clear",
                            accentColor: .orange
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(16)
            }
        }
        .background(PanelBackground())
    }
}

struct InboxRow: View {
    let hint: Hint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)

                Text(hint.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Priority indicator
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
            }

            Text(hint.title)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(3)

            if let description = hint.hintDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Quick action buttons
            HStack(spacing: 8) {
                QuickActionButton(title: "Respond", color: .orange)
                QuickActionButton(title: "Dismiss", color: .gray)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}

struct QuickActionButton: View {
    let title: String
    let color: Color

    var body: some View {
        Button(action: {}) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(color.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Components

struct CommandPanelHeader: View {
    let title: String
    let icon: String
    let accentColor: Color
    let count: Int
    var isUrgent: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(accentColor)

            Text(title)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            // Count badge
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(isUrgent ? .white : accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isUrgent ? accentColor : accentColor.opacity(0.2))
                )

            if isUrgent {
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                    .modifier(PulseAnimation())
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [accentColor.opacity(0.15), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? accentColor : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    let icon: String
    let message: String
    let accentColor: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(accentColor.opacity(0.5))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PanelBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(
                LinearGradient(
                    colors: [
                        Color(white: 0.12),
                        Color(white: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

struct PulseAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                Animation.easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

#endif
