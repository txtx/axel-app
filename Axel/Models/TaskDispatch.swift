import Foundation
import SwiftData

@Model
final class TaskDispatch {
    @Attribute(.unique) var id: UUID
    var status: String // 'running', 'completed', 'failed'
    var dispatchedAt: Date
    var completedAt: Date?

    // Relationships
    var task: WorkTask?
    var terminal: Terminal?

    // Sync
    var syncId: UUID?

    init() {
        self.id = UUID()
        self.status = "running"
        self.dispatchedAt = Date()
    }
}
