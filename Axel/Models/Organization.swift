import AutomergeWrapper
import Foundation
import SwiftData

@Model
final class Organization {
    @Attribute(.unique) var id: UUID
    var name: String
    var slug: String
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \OrganizationMember.organization)
    var members: [OrganizationMember] = []

    @Relationship(deleteRule: .cascade, inverse: \Workspace.organization)
    var workspaces: [Workspace] = []

    @Relationship(deleteRule: .cascade, inverse: \OrganizationInvitation.organization)
    var invitations: [OrganizationInvitation] = []

    // Sync
    var syncId: UUID?

    init(name: String, slug: String) {
        self.id = UUID()
        self.name = name
        self.slug = slug
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Automerge-Aware Updates

    /// Update name and sync to Automerge document
    @MainActor
    func updateName(_ newName: String) {
        self.name = newName
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateOrganizationName(newName)
    }

    /// Update slug and sync to Automerge document
    @MainActor
    func updateSlug(_ newSlug: String) {
        self.slug = newSlug
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateOrganizationSlug(newSlug)
    }

    /// Update avatar URL and sync to Automerge document
    @MainActor
    func updateAvatarUrl(_ newAvatarUrl: String?) {
        self.avatarUrl = newAvatarUrl
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateOrganizationAvatarUrl(newAvatarUrl)
    }
}
