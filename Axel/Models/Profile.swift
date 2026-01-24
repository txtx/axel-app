import Foundation
import SwiftData

@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var email: String?
    var fullName: String?
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date

    // Sync
    var syncId: UUID?

    init(id: UUID = UUID(), email: String? = nil, fullName: String? = nil) {
        self.id = id
        self.email = email
        self.fullName = fullName
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
