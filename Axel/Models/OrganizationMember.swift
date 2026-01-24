import Foundation
import SwiftData

@Model
final class OrganizationMember {
    @Attribute(.unique) var id: UUID
    var role: String // 'owner', 'admin', 'member'
    var createdAt: Date

    // Relationships
    var organization: Organization?
    var user: Profile?

    // Sync
    var syncId: UUID?

    init(role: String = "member") {
        self.id = UUID()
        self.role = role
        self.createdAt = Date()
    }
}
