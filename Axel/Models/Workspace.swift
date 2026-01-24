import AutomergeWrapper
import Foundation
import SwiftData

@Model
final class Workspace {
    @Attribute(.unique) var id: UUID
    var name: String
    var slug: String
    var path: String?  // Directory path for the workspace
    var createdAt: Date
    var updatedAt: Date

    // Relationships - personal OR org workspace
    var owner: Profile?
    var organization: Organization?

    @Relationship(deleteRule: .cascade, inverse: \WorkTask.workspace)
    var tasks: [WorkTask] = []

    @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
    var skills: [Skill] = []

    @Relationship(deleteRule: .cascade, inverse: \Context.workspace)
    var contexts: [Context] = []

    @Relationship(deleteRule: .cascade, inverse: \Terminal.workspace)
    var terminals: [Terminal] = []

    // Sync
    var syncId: UUID?

    var isPersonal: Bool {
        owner != nil && organization == nil
    }

    init(name: String, slug: String, path: String? = nil) {
        self.id = UUID()
        self.name = name
        self.slug = slug
        self.path = path
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
        try? doc.updateWorkspaceName(newName)
    }

    /// Update slug and sync to Automerge document
    @MainActor
    func updateSlug(_ newSlug: String) {
        self.slug = newSlug
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateWorkspaceSlug(newSlug)
    }

    /// Update path and sync to Automerge document
    @MainActor
    func updatePath(_ newPath: String?) {
        self.path = newPath
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateWorkspacePath(newPath)
    }
}
