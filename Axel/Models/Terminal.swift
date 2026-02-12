import AutomergeWrapper
import Foundation
import SwiftData

enum TerminalStatus: String, Codable, CaseIterable {
    case running = "running"
    case paused = "paused"
    case completed = "completed"
    case failed = "failed"
}

@Model
final class Terminal {
    @Attribute(.unique) var id: UUID
    var name: String?
    var status: String // TerminalStatus raw value
    var startedAt: Date
    var endedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    /// Pane ID (UUID string) used to identify this terminal in hook events.
    /// This is the ID passed to `axel <provider> --pane-id=<uuid>`.
    var paneId: String?

    /// Server port for this terminal's event server.
    /// Each terminal gets its own embedded server on a unique port.
    var serverPort: Int?

    /// Git worktree branch this terminal is operating in.
    /// nil means the terminal is in the main workspace (no worktree).
    var worktreeBranch: String?

    /// Whether this terminal is running in an isolated worktree.
    var isIsolated: Bool = false

    /// The parent worktree branch to merge back to (when isIsolated is true).
    var parentWorktreeBranch: String?

    /// AI provider for this terminal session (claude or codex).
    var providerRaw: String = AIProvider.claude.rawValue

    var provider: AIProvider {
        get { AIProvider(rawValue: providerRaw) ?? .claude }
        set { providerRaw = newValue.rawValue }
    }

    /// Display name for the worktree (returns "main" if no worktree)
    var worktreeDisplayName: String {
        worktreeBranch ?? "main"
    }

    // Relationships
    var workspace: Workspace?
    var task: WorkTask?

    @Relationship(deleteRule: .cascade, inverse: \TaskDispatch.terminal)
    var dispatches: [TaskDispatch] = []

    @Relationship(deleteRule: .cascade, inverse: \Hint.terminal)
    var hints: [Hint] = []

    // Many-to-many with skills and contexts
    var skills: [Skill] = []
    var contexts: [Context] = []

    // Sync
    var syncId: UUID?

    var terminalStatus: TerminalStatus {
        get { TerminalStatus(rawValue: status) ?? .running }
        set { status = newValue.rawValue }
    }

    init(name: String? = nil) {
        self.id = UUID()
        self.name = name
        self.status = TerminalStatus.running.rawValue
        self.startedAt = Date()
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - Automerge-Aware Updates

    /// Update name and sync to Automerge document
    @MainActor
    func updateName(_ newName: String?) {
        self.name = newName
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTerminalName(newName)
    }

    /// Update status and sync to Automerge document
    @MainActor
    func updateStatus(_ newStatus: TerminalStatus) {
        self.status = newStatus.rawValue
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTerminalStatus(newStatus.rawValue)
    }

    /// Mark terminal as ended and sync to Automerge document
    @MainActor
    func markEnded() {
        self.endedAt = Date()
        self.status = TerminalStatus.completed.rawValue
        self.updatedAt = Date()
        let doc = AutomergeStore.shared.document(for: self.syncId ?? self.id)
        try? doc.updateTerminalEndedAt(self.endedAt)
        try? doc.updateTerminalStatus(TerminalStatus.completed.rawValue)
    }
}
