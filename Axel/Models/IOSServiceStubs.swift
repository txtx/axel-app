import Foundation
import SwiftData

#if os(iOS) || os(visionOS)

// MARK: - iOS Service Stubs

// Simple stub implementations to satisfy iOS compilation requirements

extension TaskStatus {
    var isPending: Bool {
        switch self {
        case .backlog, .queued:
            return true
        case .running, .completed, .aborted, .inReview:
            return false
        }
    }
}

// Stub for SyncScheduler if not available on iOS
struct SyncSchedulerStub {
    static let shared = SyncSchedulerStub()
    
    func scheduleSync() {
        // No-op on iOS for now
    }
}

// Stub for TaskQueueService if not available on iOS  
struct TaskQueueServiceStub {
    static let shared = TaskQueueServiceStub()
    
    func removeFromAnyTerminal(taskId: UUID) {
        // No-op on iOS for now
    }
    
    func terminalForTask(taskId: UUID) -> String? {
        return nil
    }
    
    func enqueue(taskId: UUID, onTerminal: String) {
        // No-op on iOS for now
    }
}

// Stub for TaskUndoAction
struct TaskUndoAction {
    let taskId: UUID
    let actionDescription: String
    let undo: () -> Void
    let redo: () -> Void
}

// Stub for TaskUndoManager
struct TaskUndoManagerStub {
    static let shared = TaskUndoManagerStub()
    
    func recordAction(_ action: TaskUndoAction) {
        // No-op on iOS for now
    }
}

// Make sure these exist on iOS
#if !os(macOS)
typealias SyncScheduler = SyncSchedulerStub
typealias TaskQueueService = TaskQueueServiceStub
typealias TaskUndoManager = TaskUndoManagerStub
#endif

#endif