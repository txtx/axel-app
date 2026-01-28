import SwiftUI
import SwiftData

#if os(visionOS)

/// Ultra-wide command center surface with Tasks, Skills, and Inbox side by side
/// This is a simplified version used for windowed display (non-immersive)
struct CommandCenterView: View {
    @Query(sort: \WorkTask.priority) private var tasks: [WorkTask]
    @Query(sort: \Skill.updatedAt, order: .reverse) private var skills: [Skill]
    @Query(sort: \InboxEvent.timestamp, order: .reverse) private var events: [InboxEvent]

    private var runningTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .running }
    }

    private var queuedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .queued }.sorted { $0.priority < $1.priority }
    }

    private var pendingEvents: [InboxEvent] {
        events.filter { !$0.isResolved }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Tasks Panel
            TasksPanelView(
                runningTasks: runningTasks,
                queuedTasks: queuedTasks
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.2))

            // Skills/Agents Panel
            AgentsPanelView(skills: skills)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.2))

            // Inbox Panel
            InboxPanelView(events: pendingEvents)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Panel Views

struct TasksPanelView: View {
    let runningTasks: [WorkTask]
    let queuedTasks: [WorkTask]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: "TASKS",
                icon: "rectangle.stack",
                color: .blue,
                count: runningTasks.count + queuedTasks.count
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !runningTasks.isEmpty {
                        ForEach(runningTasks) { task in
                            TaskPanelRow(task: task, isRunning: true)
                        }
                    }

                    if !queuedTasks.isEmpty {
                        ForEach(Array(queuedTasks.prefix(5).enumerated()), id: \.element.id) { index, task in
                            TaskPanelRow(task: task, position: index + 1)
                        }
                    }

                    if runningTasks.isEmpty && queuedTasks.isEmpty {
                        EmptyPanelState(icon: "checkmark.circle", message: "All clear")
                    }
                }
                .padding(16)
            }
        }
    }
}

struct TaskPanelRow: View {
    let task: WorkTask
    var isRunning: Bool = false
    var position: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else if let position {
                Text("\(position)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }

            Text(task.title)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isRunning ? Color.green.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AgentsPanelView: View {
    let skills: [Skill]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: "SKILLS",
                icon: "hammer.fill",
                color: .orange,
                count: skills.count
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if skills.isEmpty {
                        EmptyPanelState(icon: "sparkles", message: "No skills")
                    } else {
                        ForEach(skills.prefix(6)) { skill in
                            SkillPanelRow(skill: skill)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

struct SkillPanelRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)

            Text(skill.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

struct InboxPanelView: View {
    let events: [InboxEvent]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: "INBOX",
                icon: "tray.fill",
                color: .pink,
                count: events.count
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if events.isEmpty {
                        EmptyPanelState(icon: "tray", message: "Inbox clear")
                    } else {
                        ForEach(events.prefix(6)) { event in
                            InboxPanelRow(event: event)
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

struct InboxPanelRow: View {
    let event: InboxEvent

    private var icon: String {
        switch event.eventType {
        case .permission: return "lock.shield"
        case .hint: return "questionmark.bubble"
        default: return "bell"
        }
    }

    private var color: Color {
        switch event.eventType {
        case .permission: return .orange
        case .hint: return .purple
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)

            Text(event.title ?? event.eventType.rawValue)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if !event.isResolved {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

// MARK: - Shared Components

struct PanelHeader: View {
    let title: String
    let icon: String
    let color: Color
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)

            Text(title)
                .font(.headline)
                .tracking(0.5)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
    }
}

struct EmptyPanelState: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

#endif
