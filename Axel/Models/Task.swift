import AutomergeWrapper
import Foundation
import SwiftData

enum TaskStatus: String, Codable, CaseIterable {
    case queued = "queued"
    case running = "running"
    case completed = "completed"
    case inReview = "in_review"
    case aborted = "aborted"

    var displayName: String {
        switch self {
        case .queued: return "QUEUED"
        case .running: return "RUNNING"
        case .completed: return "COMPLETED"
        case .inReview: return "IN REVIEW"
        case .aborted: return "ABORTED"
        }
    }

    var menuLabel: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .completed: return "Completed"
        case .inReview: return "In Review"
        case .aborted: return "Aborted"
        }
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

    // Sync
    var syncId: UUID?

    var taskStatus: TaskStatus {
        get { TaskStatus(rawValue: status) ?? .queued }
        set { status = newValue.rawValue }
    }

    /// Convenience accessor for assigned profiles
    var assignees: [Profile] {
        taskAssignees.compactMap { $0.profile }
    }

    var isCompleted: Bool {
        get { taskStatus == .completed }
        set {
            if newValue {
                taskStatus = .completed
                completedAt = Date()
            } else {
                taskStatus = .queued
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
        self.status = TaskStatus.queued.rawValue
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
    @MainActor
    func updateStatus(_ newStatus: TaskStatus) {
        self.status = newStatus.rawValue
        self.updatedAt = Date()
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
        self.status = TaskStatus.queued.rawValue
        self.completedAt = nil
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTaskStatus(TaskStatus.queued.rawValue)
        try? doc.updateTaskCompletedAt(nil)
        SyncScheduler.shared.scheduleSync()
    }
}
