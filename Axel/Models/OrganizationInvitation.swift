import Foundation
import SwiftData

@Model
final class OrganizationInvitation {
    @Attribute(.unique) var id: UUID
    var email: String
    var role: String // 'admin', 'member'
    var status: String // 'pending', 'accepted', 'declined', 'expired'
    var createdAt: Date
    var expiresAt: Date

    // Relationships
    var organization: Organization?
    var invitedBy: Profile?

    // Sync
    var syncId: UUID?

    init(
        email: String,
        role: String = "member",
        status: String = "pending",
        expiresAt: Date? = nil
    ) {
        self.id = UUID()
        self.email = email
        self.role = role
        self.status = status
        self.createdAt = Date()
        self.expiresAt = expiresAt ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())!
    }

    var isExpired: Bool {
        Date() > expiresAt
    }

    var isPending: Bool {
        status == "pending" && !isExpired
    }
}
