#if os(macOS)
import Foundation
import SwiftData

/// Result of a task assignment operation
enum TaskAssignmentResult: Equatable {
    case queued(paneId: String)
    case running(paneId: String)
    case noSessionFound
    case taskNotFound
    case alreadyRunning
}

/// Result of consuming a queued task
enum TaskConsumptionResult: Equatable {
    case consumed(taskId: UUID)
    case queueEmpty
    case sessionNotFound
    case taskDeleted
    case idempotencyGuard
}

/// Coordinates task assignment, queuing, and execution on terminal sessions.
/// This class extracts business logic from views for testability.
@MainActor
final class TaskAssignmentCoordinator {

    // MARK: - Dependencies

    private let taskQueue: TaskQueueing
    private let sessionManager: TerminalSessionManaging
    private let taskFetcher: TaskFetching

    // MARK: - Callbacks

    /// Called when a task should be sent to a terminal
    var onSendTaskPrompt: ((WorkTask, TerminalSession) -> Void)?

    /// Called when terminal model needs to be updated
    var onUpdateTerminalTask: ((String, WorkTask?) -> Void)?

    /// Called after task state changes
    var onTaskStateChanged: (() -> Void)?

    // MARK: - Initialization

    init(
        taskQueue: TaskQueueing,
        sessionManager: TerminalSessionManaging,
        taskFetcher: TaskFetching
    ) {
        self.taskQueue = taskQueue
        self.sessionManager = sessionManager
        self.taskFetcher = taskFetcher
    }

    /// Convenience initializer using shared instances
    convenience init() {
        self.init(
            taskQueue: TaskQueueService.shared,
            sessionManager: TerminalSessionManager.shared,
            taskFetcher: SwiftDataTaskFetcher.shared
        )
    }

    // MARK: - Task Assignment

    /// Assign a task to a worker session.
    /// If the worker is busy, the task is queued. Otherwise, it runs immediately.
    /// - Parameters:
    ///   - task: The task to assign
    ///   - worker: The terminal session to assign to
    /// - Returns: The result of the assignment
    @discardableResult
    func assignTask(_ task: WorkTask, to worker: TerminalSession) -> TaskAssignmentResult {
        guard let paneId = worker.paneId else {
            return .noSessionFound
        }

        if worker.hasTask {
            // Terminal is busy - queue the task
            return queueTask(task, on: worker)
        } else {
            // Terminal is idle - run immediately
            return runTask(task, on: worker)
        }
    }

    /// Queue a task to run after the current task on a worker completes.
    /// - Parameters:
    ///   - task: The task to queue
    ///   - worker: The terminal session to queue on
    /// - Returns: The result of the queuing
    @discardableResult
    func queueTask(_ task: WorkTask, on worker: TerminalSession) -> TaskAssignmentResult {
        guard let paneId = worker.paneId else {
            return .noSessionFound
        }

        // Update task status to queued
        task.updateStatus(.queued)

        // Add to the queue
        taskQueue.enqueue(taskId: task.id, onTerminal: paneId)

        onTaskStateChanged?()

        return .queued(paneId: paneId)
    }

    /// Run a task immediately on a worker.
    /// - Parameters:
    ///   - task: The task to run
    ///   - worker: The terminal session to run on
    /// - Returns: The result of running
    @discardableResult
    func runTask(_ task: WorkTask, on worker: TerminalSession) -> TaskAssignmentResult {
        guard let paneId = worker.paneId else {
            return .noSessionFound
        }

        // Update task status to running
        task.updateStatus(.running)

        // Update worker session with new task
        worker.assignTask(task)

        // Update terminal model
        onUpdateTerminalTask?(paneId, task)

        // Send the task prompt to the terminal
        onSendTaskPrompt?(task, worker)

        onTaskStateChanged?()

        return .running(paneId: paneId)
    }

    // MARK: - Queue Consumption

    /// Consume the next queued task on a terminal after current task completes.
    /// - Parameters:
    ///   - paneId: The terminal's pane ID
    ///   - workspaceId: The workspace ID to search sessions in
    /// - Returns: The result of consumption
    @discardableResult
    func consumeNextQueuedTask(forPaneId paneId: String, workspaceId: UUID) -> TaskConsumptionResult {
        // Find the session for this pane
        guard let session = sessionManager.sessions.first(where: { $0.paneId == paneId }) else {
            return .sessionNotFound
        }

        // Idempotency guard: if session already has a running task that's not completed,
        // skip this call (prevents race condition between dual notifications)
        if let currentTaskId = session.taskId,
           let currentTask = taskFetcher.fetchTask(byPersistentId: currentTaskId),
           currentTask.taskStatus == .running {
            return .idempotencyGuard
        }

        // Pop the next task from the queue
        guard let nextTaskId = taskQueue.dequeue(fromTerminal: paneId) else {
            // No more tasks in queue - clear the current task reference
            session.taskId = nil
            session.taskTitle = "Terminal"
            onUpdateTerminalTask?(paneId, nil)
            return .queueEmpty
        }

        // Find the task by ID
        guard let task = taskFetcher.fetchTask(byId: nextTaskId) else {
            // Task was deleted - try next one recursively
            return consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
        }

        // Run the task
        _ = runTask(task, on: session)

        return .consumed(taskId: nextTaskId)
    }

    // MARK: - Notification Handling

    /// Handle the taskNoLongerRunning notification.
    /// Finds the terminal for the task and consumes the next queued task.
    /// - Parameters:
    ///   - taskId: The task UUID that's no longer running
    ///   - workspaceId: The workspace ID
    ///   - terminals: The workspace's terminals (for lookup)
    /// - Returns: The paneId that was processed, or nil if not found
    @discardableResult
    func handleTaskNoLongerRunning(
        taskId: UUID,
        workspaceId: UUID,
        terminals: [Terminal]
    ) -> String? {
        // Try to find paneId via Terminal model first
        if let terminal = terminals.first(where: { $0.task?.id == taskId }),
           let paneId = terminal.paneId {
            _ = consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
            return paneId
        }

        // Fallback: Try to find paneId via TerminalSession
        if let task = taskFetcher.fetchTask(byId: taskId) {
            let persistentId = task.persistentModelID
            if let session = sessionManager.sessions(for: workspaceId).first(where: { $0.taskId == persistentId }),
               let paneId = session.paneId {
                _ = consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
                return paneId
            }
        }

        return nil
    }

    // MARK: - Query Methods

    /// Get the queue count for a terminal
    /// - Parameter paneId: The terminal's pane ID
    /// - Returns: Number of tasks in queue
    func queueCount(forTerminal paneId: String) -> Int {
        taskQueue.queueCount(forTerminal: paneId)
    }

    /// Get the terminal that has a task in its queue
    /// - Parameter taskId: The task UUID
    /// - Returns: The pane ID, or nil if not queued
    func terminalForTask(_ taskId: UUID) -> String? {
        taskQueue.terminalForTask(taskId: taskId)
    }
}

// MARK: - Task Fetching Protocol

/// Protocol for fetching tasks, enabling dependency injection for testing
@MainActor
protocol TaskFetching {
    /// Fetch a task by its UUID
    func fetchTask(byId id: UUID) -> WorkTask?

    /// Fetch a task by its persistent model ID
    func fetchTask(byPersistentId id: PersistentIdentifier) -> WorkTask?
}

/// Default implementation using SwiftData
@MainActor
final class SwiftDataTaskFetcher: TaskFetching {
    static let shared = SwiftDataTaskFetcher()

    private var modelContext: ModelContext?

    private init() {}

    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchTask(byId id: UUID) -> WorkTask? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    func fetchTask(byPersistentId id: PersistentIdentifier) -> WorkTask? {
        guard let modelContext else { return nil }
        return modelContext.model(for: id) as? WorkTask
    }
}
#endif
