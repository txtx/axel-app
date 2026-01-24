import Foundation
import SwiftData

@Model
final class TaskComment {
    @Attribute(.unique) var id: UUID
    var content: String
    var createdAt: Date
    var updatedAt: Date

    // Relationships
    var task: WorkTask?
    var user: Profile?

    // Sync
    var syncId: UUID?

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
