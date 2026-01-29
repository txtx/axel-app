import Foundation
import SwiftUI

/// Represents an undoable action on a task
struct TaskUndoAction {
    let taskId: UUID
    let actionDescription: String
    let undo: @MainActor () -> Void
    let redo: @MainActor () -> Void
}

/// Manages undo/redo history for task actions
@MainActor
@Observable
final class TaskUndoManager {
    static let shared = TaskUndoManager()

    private(set) var undoStack: [TaskUndoAction] = []
    private(set) var redoStack: [TaskUndoAction] = []

    /// Maximum number of actions to keep in history
    private let maxHistorySize = 50

    private init() {}

    /// Whether there's an action available to undo
    var canUndo: Bool {
        !undoStack.isEmpty
    }

    /// Whether there's an action available to redo
    var canRedo: Bool {
        !redoStack.isEmpty
    }

    /// Description of the next action to undo
    var undoActionName: String? {
        undoStack.last?.actionDescription
    }

    /// Description of the next action to redo
    var redoActionName: String? {
        redoStack.last?.actionDescription
    }

    /// Record an undoable action
    func recordAction(_ action: TaskUndoAction) {
        undoStack.append(action)
        redoStack.removeAll() // Clear redo stack when new action is performed

        // Trim history if needed
        if undoStack.count > maxHistorySize {
            undoStack.removeFirst()
        }
    }

    /// Undo the last action
    func undo() {
        guard let action = undoStack.popLast() else { return }
        action.undo()
        redoStack.append(action)
    }

    /// Redo the last undone action
    func redo() {
        guard let action = redoStack.popLast() else { return }
        action.redo()
        undoStack.append(action)
    }

    /// Clear all undo/redo history
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Remove all actions for a specific task (e.g., when task is deleted)
    func removeActions(for taskId: UUID) {
        undoStack.removeAll { $0.taskId == taskId }
        redoStack.removeAll { $0.taskId == taskId }
    }
}
