import Foundation
import SwiftData

// MARK: - Task Queuing Protocol

/// Protocol for task queue management, enabling dependency injection and testing
@MainActor
protocol TaskQueueing: AnyObject {
    /// The current state of terminal queues (for observation/testing)
    var terminalQueues: [String: [UUID]] { get }

    /// Add a task to a terminal's queue
    func enqueue(taskId: UUID, onTerminal paneId: String)

    /// Remove and return the next task from a terminal's queue (FIFO)
    func dequeue(fromTerminal paneId: String) -> UUID?

    /// View the next task without removing it
    func peek(terminal paneId: String) -> UUID?

    /// Get all tasks queued on a terminal
    func tasksQueued(onTerminal paneId: String) -> [UUID]

    /// Find which terminal has a specific task in its queue
    func terminalForTask(taskId: UUID) -> String?

    /// Get the number of tasks queued on a terminal
    func queueCount(forTerminal paneId: String) -> Int

    /// Reorder a task within its terminal's queue
    func reorder(taskId: UUID, toIndex newIndex: Int, inTerminal paneId: String)

    /// Remove a specific task from a terminal's queue
    @discardableResult
    func remove(taskId: UUID, fromTerminal paneId: String) -> Bool

    /// Remove a task from any terminal's queue
    @discardableResult
    func removeFromAnyTerminal(taskId: UUID) -> String?

    /// Clear all tasks from a terminal's queue
    @discardableResult
    func clearQueue(forTerminal paneId: String) -> [UUID]

    /// Clear all queues across all terminals
    func clearAllQueues()
}

// MARK: - Task Queue Service

/// Singleton service that manages per-terminal task queues.
/// Tracks which tasks are queued on which terminals (FIFO order).
@MainActor
@Observable
final class TaskQueueService: TaskQueueing {
    static let shared = TaskQueueService()

    /// Terminal queues: paneId -> ordered list of task IDs (FIFO)
    private(set) var terminalQueues: [String: [UUID]] = [:]

    /// Internal initializer for singleton
    private init() {}

    /// Initializer for testing with pre-populated queues
    init(queues: [String: [UUID]]) {
        self.terminalQueues = queues
    }

    // MARK: - Queue Operations

    /// Add a task to a terminal's queue
    func enqueue(taskId: UUID, onTerminal paneId: String) {
        if terminalQueues[paneId] == nil {
            terminalQueues[paneId] = []
        }
        // Avoid duplicates
        if !terminalQueues[paneId]!.contains(taskId) {
            terminalQueues[paneId]!.append(taskId)
        }
    }

    /// Remove and return the next task from a terminal's queue (FIFO)
    func dequeue(fromTerminal paneId: String) -> UUID? {
        guard var queue = terminalQueues[paneId], !queue.isEmpty else {
            return nil
        }
        let taskId = queue.removeFirst()
        terminalQueues[paneId] = queue
        return taskId
    }

    /// Peek at the next task in a terminal's queue without removing it
    func peek(terminal paneId: String) -> UUID? {
        terminalQueues[paneId]?.first
    }

    /// Get all tasks queued on a terminal
    func tasksQueued(onTerminal paneId: String) -> [UUID] {
        terminalQueues[paneId] ?? []
    }

    /// Find which terminal (if any) has a task in its queue
    func terminalForTask(taskId: UUID) -> String? {
        for (paneId, queue) in terminalQueues {
            if queue.contains(taskId) {
                return paneId
            }
        }
        return nil
    }

    /// Get number of tasks queued on a terminal
    func queueCount(forTerminal paneId: String) -> Int {
        terminalQueues[paneId]?.count ?? 0
    }

    /// Remove a specific task from a terminal's queue (e.g., if task is deleted or manually dequeued)
    @discardableResult
    func remove(taskId: UUID, fromTerminal paneId: String) -> Bool {
        guard var queue = terminalQueues[paneId],
              let index = queue.firstIndex(of: taskId) else {
            return false
        }
        queue.remove(at: index)
        terminalQueues[paneId] = queue
        return true
    }

    /// Remove a task from any terminal's queue
    @discardableResult
    func removeFromAnyTerminal(taskId: UUID) -> String? {
        for (paneId, var queue) in terminalQueues {
            if let index = queue.firstIndex(of: taskId) {
                queue.remove(at: index)
                terminalQueues[paneId] = queue
                return paneId
            }
        }
        return nil
    }

    /// Clear all tasks from a terminal's queue (e.g., when terminal is closed)
    func clearQueue(forTerminal paneId: String) -> [UUID] {
        let tasks = terminalQueues[paneId] ?? []
        terminalQueues[paneId] = nil
        return tasks
    }

    /// Clear all queues (e.g., on app reset)
    func clearAllQueues() {
        terminalQueues.removeAll()
    }

    /// Reorder a task within a terminal's queue
    func reorder(taskId: UUID, toIndex newIndex: Int, inTerminal paneId: String) {
        guard var queue = terminalQueues[paneId],
              let currentIndex = queue.firstIndex(of: taskId),
              newIndex >= 0 && newIndex < queue.count else {
            return
        }
        queue.remove(at: currentIndex)
        queue.insert(taskId, at: newIndex)
        terminalQueues[paneId] = queue
    }

    // MARK: - Convenience

    /// Check if a task is queued on any terminal
    func isQueued(taskId: UUID) -> Bool {
        terminalForTask(taskId: taskId) != nil
    }

    /// Get total number of queued tasks across all terminals
    var totalQueuedCount: Int {
        terminalQueues.values.reduce(0) { $0 + $1.count }
    }
}
