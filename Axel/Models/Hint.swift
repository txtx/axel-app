import AutomergeWrapper
import Foundation
import SwiftData

enum HintType: String, Codable, CaseIterable {
    case exclusiveChoice = "exclusive_choice"
    case multipleChoice = "multiple_choice"
    case textInput = "text_input"
}

enum HintStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case answered = "answered"
    case cancelled = "cancelled"
}

struct HintOption: Codable, Hashable {
    var label: String
    var value: String
}

@Model
final class Hint {
    @Attribute(.unique) var id: UUID
    var type: String // HintType raw value
    var title: String
    var hintDescription: String?
    var optionsData: Data? // JSON encoded [HintOption]
    var responseData: Data? // JSON encoded response
    var status: String // HintStatus raw value
    var createdAt: Date
    var answeredAt: Date?

    // Relationships
    var terminal: Terminal?
    var task: WorkTask?

    // Sync
    var syncId: UUID?

    var hintType: HintType {
        get { HintType(rawValue: type) ?? .exclusiveChoice }
        set { type = newValue.rawValue }
    }

    var hintStatus: HintStatus {
        get { HintStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    var options: [HintOption]? {
        get {
            guard let data = optionsData else { return nil }
            return try? JSONDecoder().decode([HintOption].self, from: data)
        }
        set {
            optionsData = try? JSONEncoder().encode(newValue)
        }
    }

    init(type: HintType, title: String, description: String? = nil) {
        self.id = UUID()
        self.type = type.rawValue
        self.title = title
        self.hintDescription = description
        self.status = HintStatus.pending.rawValue
        self.createdAt = Date()
    }

    // MARK: - Automerge-Aware Updates

    /// Update status and sync to Automerge document
    @MainActor
    func updateStatus(_ newStatus: HintStatus) {
        self.status = newStatus.rawValue
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateHintStatus(newStatus.rawValue)
    }

    /// Mark hint as answered and sync to Automerge document
    @MainActor
    func markAnswered() {
        self.status = HintStatus.answered.rawValue
        self.answeredAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateHintStatus(HintStatus.answered.rawValue)
        try? doc.updateHintAnsweredAt(self.answeredAt)
    }

    /// Cancel hint and sync to Automerge document
    @MainActor
    func cancel() {
        self.status = HintStatus.cancelled.rawValue
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateHintStatus(HintStatus.cancelled.rawValue)
    }
}
