import Foundation
import SwiftData

@Model
final class TaskAttachment {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var fileUrl: String
    var fileType: String? // 'image', 'file'
    var fileSize: Int?
    var createdAt: Date

    // Relationships
    var task: WorkTask?
    var user: Profile?

    // Sync
    var syncId: UUID?

    init(fileName: String, fileUrl: String, fileType: String? = nil) {
        self.id = UUID()
        self.fileName = fileName
        self.fileUrl = fileUrl
        self.fileType = fileType
        self.createdAt = Date()
    }
}
