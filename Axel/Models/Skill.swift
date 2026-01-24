import AutomergeWrapper
import Foundation
import SwiftData

@Model
final class Skill {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    // Relationships
    var workspace: Workspace?
    var terminals: [Terminal] = []

    // Sync
    var syncId: UUID?

    init(name: String, content: String = "") {
        self.id = UUID()
        self.name = name
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func updateContent(_ newContent: String) {
        content = newContent
        updatedAt = Date()
    }

    func updateName(_ newName: String) {
        name = newName
        updatedAt = Date()
    }

    // MARK: - Automerge-Aware Updates

    /// Update content and sync to Automerge document
    @MainActor
    func updateContentWithSync(_ newContent: String) {
        self.content = newContent
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateSkillContent(newContent)
    }

    /// Update name and sync to Automerge document
    @MainActor
    func updateNameWithSync(_ newName: String) {
        self.name = newName
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateSkillName(newName)
    }
}
