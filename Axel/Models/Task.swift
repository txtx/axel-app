import AutomergeWrapper
import Foundation
import SwiftData

enum TaskStatus: String, Codable, CaseIterable {
    /// Task is in the general backlog, not assigned to any terminal
    case backlog = "backlog"
    /// Task is assigned to a specific terminal's queue, waiting for its turn
    case queued = "queued"
    case running = "running"
    case completed = "completed"
    case inReview = "in_review"
    case aborted = "aborted"

    var displayName: String {
        switch self {
        case .backlog: return "BACKLOG"
        case .queued: return "QUEUED"
        case .running: return "RUNNING"
        case .completed: return "COMPLETED"
        case .inReview: return "IN REVIEW"
        case .aborted: return "ABORTED"
        }
    }

    var menuLabel: String {
        switch self {
        case .backlog: return "Backlog"
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .inReview: return "In Review"
        case .aborted: return "Aborted"
        }
    }

    /// Whether this status represents a task waiting to be run (backlog or queued)
    var isPending: Bool {
        self == .backlog || self == .queued
    }
}

@Model
final class WorkTask {
    @Attribute(.unique) var id: UUID
    var title: String
    var taskDescription: String?
    var status: String // TaskStatus raw value
    /// Queue position: lower values = higher in queue (executed first).
    /// When sorting, use ascending order (.forward / <) so priority 0 appears before priority 100.
    var priority: Int
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    // Relationships
    var workspace: Workspace?
    var createdBy: Profile?

    @Relationship(deleteRule: .cascade, inverse: \TaskAssignee.task)
    var taskAssignees: [TaskAssignee] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskComment.task)
    var comments: [TaskComment] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskAttachment.task)
    var attachments: [TaskAttachment] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskDispatch.task)
    var dispatches: [TaskDispatch] = []

    @Relationship(deleteRule: .cascade, inverse: \Hint.task)
    var hints: [Hint] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskSkill.task)
    var taskSkills: [TaskSkill] = []

    // Sync
    var syncId: UUID?

    var taskStatus: TaskStatus {
        get { TaskStatus(rawValue: status) ?? .backlog }
        set { status = newValue.rawValue }
    }

    /// Composite ID that includes status, used for ForEach identity.
    /// This forces SwiftUI to create a fresh view when a task moves between sections.
    var compositeId: String {
        "\(status)-\(id.uuidString)"
    }

    /// Convenience accessor for assigned profiles
    var assignees: [Profile] {
        taskAssignees.compactMap { $0.profile }
    }

    /// Convenience accessor for attached skills
    var skills: [Skill] {
        taskSkills.compactMap { $0.skill }
    }

    var isCompleted: Bool {
        get { taskStatus == .completed }
        set {
            if newValue {
                taskStatus = .completed
                completedAt = Date()
            } else {
                taskStatus = .backlog
                completedAt = nil
            }
            updatedAt = Date()
        }
    }

    func toggleComplete() {
        isCompleted.toggle()
    }

    init(title: String, description: String? = nil) {
        self.id = UUID()
        self.title = title
        self.taskDescription = description
        self.status = TaskStatus.backlog.rawValue
        self.priority = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Automerge-Aware Updates

    /// Update title and sync to Automerge document
    @MainActor
    func updateTitle(_ newTitle: String) {
        self.title = newTitle
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskTitle(newTitle)
    }

    /// Update description and sync to Automerge document
    @MainActor
    func updateDescription(_ newDescription: String?) {
        self.taskDescription = newDescription
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskDescription(newDescription)
    }

    /// Update status and sync to Automerge document
    /// Also handles TaskQueueService cleanup when leaving queued status
    @MainActor
    func updateStatus(_ newStatus: TaskStatus) {
        let oldStatus = self.taskStatus
        self.status = newStatus.rawValue
        self.updatedAt = Date()

        // Clean up TaskQueueService when leaving queued status
        if oldStatus == .queued && newStatus != .queued {
            TaskQueueService.shared.removeFromAnyTerminal(taskId: self.id)
        }

        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskStatus(newStatus.rawValue)
        // Trigger sync for status changes (important for cross-device sync)
        SyncScheduler.shared.scheduleSync()
    }

    /// Update priority and sync to Automerge document
    @MainActor
    func updatePriority(_ newPriority: Int) {
        self.priority = newPriority
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskPriority(newPriority)
    }

    /// Mark task as completed and sync to Automerge document
    @MainActor
    func markCompleted() {
        self.status = TaskStatus.completed.rawValue
        self.completedAt = Date()
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskStatus(TaskStatus.completed.rawValue)
        try? doc.updateTaskCompletedAt(self.completedAt)
        SyncScheduler.shared.scheduleSync()
    }

    /// Reopen task and sync to Automerge document
    @MainActor
    func reopen() {
        self.status = TaskStatus.backlog.rawValue
        self.completedAt = nil
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskStatus(TaskStatus.backlog.rawValue)
        try? doc.updateTaskCompletedAt(nil)
        SyncScheduler.shared.scheduleSync()
    }

    // MARK: - Undo-Aware Updates

    /// Update status with undo support
    @MainActor
    func updateStatusWithUndo(_ newStatus: TaskStatus) {
        let previousStatus = self.taskStatus
        let previousCompletedAt = self.completedAt
        let taskId = self.id
        // Capture queue state for undo - if leaving queued, remember which terminal
        let previousTerminal = previousStatus == .queued
            ? TaskQueueService.shared.terminalForTask(taskId: taskId)
            : nil

        TaskUndoManager.shared.recordAction(TaskUndoAction(
            taskId: taskId,
            actionDescription: "Change Status to \(newStatus.menuLabel)",
            undo: { [weak self] in
                guard let self else { return }
                self.status = previousStatus.rawValue
                self.completedAt = previousCompletedAt
                self.updatedAt = Date()
                // Restore queue state if was previously queued
                if previousStatus == .queued, let terminal = previousTerminal {
                    TaskQueueService.shared.enqueue(taskId: self.id, onTerminal: terminal)
                } else if previousStatus != .queued {
                    // Was not queued before, ensure removed from any queue
                    TaskQueueService.shared.removeFromAnyTerminal(taskId: self.id)
                }
                let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
                try? doc.updateTaskStatus(previousStatus.rawValue)
                try? doc.updateTaskCompletedAt(previousCompletedAt)
                SyncScheduler.shared.scheduleSync()
            },
            redo: { [weak self] in
                guard let self else { return }
                self.updateStatus(newStatus)
            }
        ))

        updateStatus(newStatus)
    }

    /// Mark completed with undo support
    @MainActor
    func markCompletedWithUndo() {
        let previousStatus = self.taskStatus
        let previousCompletedAt = self.completedAt
        let taskId = self.id

        TaskUndoManager.shared.recordAction(TaskUndoAction(
            taskId: taskId,
            actionDescription: "Mark as Completed",
            undo: { [weak self] in
                guard let self else { return }
                self.status = previousStatus.rawValue
                self.completedAt = previousCompletedAt
                self.updatedAt = Date()
                let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
                try? doc.updateTaskStatus(previousStatus.rawValue)
                try? doc.updateTaskCompletedAt(previousCompletedAt)
                SyncScheduler.shared.scheduleSync()
            },
            redo: { [weak self] in
                guard let self else { return }
                self.markCompleted()
            }
        ))

        markCompleted()
    }

    /// Reopen task with undo support
    @MainActor
    func reopenWithUndo() {
        let previousStatus = self.taskStatus
        let previousCompletedAt = self.completedAt
        let taskId = self.id

        TaskUndoManager.shared.recordAction(TaskUndoAction(
            taskId: taskId,
            actionDescription: "Reopen Task",
            undo: { [weak self] in
                guard let self else { return }
                self.status = previousStatus.rawValue
                self.completedAt = previousCompletedAt
                self.updatedAt = Date()
                let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
                try? doc.updateTaskStatus(previousStatus.rawValue)
                try? doc.updateTaskCompletedAt(previousCompletedAt)
                SyncScheduler.shared.scheduleSync()
            },
            redo: { [weak self] in
                guard let self else { return }
                self.reopen()
            }
        ))

        reopen()
    }

    /// Toggle complete with undo support
    @MainActor
    func toggleCompleteWithUndo() {
        if isCompleted {
            reopenWithUndo()
        } else {
            markCompletedWithUndo()
        }
    }

    /// Prepare task for deletion by cleaning up any associated state
    /// Call this before deleting the task from SwiftData
    @MainActor
    func prepareForDeletion() {
        // Remove from any terminal queue
        TaskQueueService.shared.removeFromAnyTerminal(taskId: self.id)
    }
}
