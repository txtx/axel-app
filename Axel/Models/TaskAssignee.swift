import Foundation
import SwiftData

@Model
final class TaskAssignee {
    @Attribute(.unique) var id: UUID
    var task: WorkTask?
    var profile: Profile?
    var assignedAt: Date
    var assignedBy: Profile?

    // Sync
    var syncId: UUID?

    init(task: WorkTask, profile: Profile, assignedBy: Profile? = nil) {
        self.id = UUID()
        self.task = task
        self.profile = profile
        self.assignedAt = Date()
        self.assignedBy = assignedBy
    }
}
