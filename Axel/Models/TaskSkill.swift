import Foundation
import SwiftData

/// Junction model linking tasks to skills (local-only, not synced remotely)
@Model
final class TaskSkill {
    @Attribute(.unique) var id: UUID
    var task: WorkTask?
    var skill: Skill?
    var attachedAt: Date

    init(task: WorkTask, skill: Skill) {
        self.id = UUID()
        self.task = task
        self.skill = skill
        self.attachedAt = Date()
    }
}
