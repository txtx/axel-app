import AutomergeWrapper
import Foundation

// MARK: - Schema Key Definitions

/// Schema keys for Task documents
enum TaskSchema {
    static let title = "title"
    static let description = "description"
    static let status = "status"
    static let priority = "priority"
    static let completedAt = "completedAt"
}

/// Schema keys for Workspace documents
enum WorkspaceSchema {
    static let name = "name"
    static let slug = "slug"
    static let path = "path"
}

/// Schema keys for Skill documents
enum SkillSchema {
    static let name = "name"
    static let content = "content"
}

/// Schema keys for Context documents
enum ContextSchema {
    static let name = "name"
    static let content = "content"
}

/// Schema keys for Terminal documents
enum TerminalSchema {
    static let name = "name"
    static let status = "status"
    static let startedAt = "startedAt"
    static let endedAt = "endedAt"
    static let paneId = "paneId"
}

/// Schema keys for Hint documents
enum HintSchema {
    static let type = "type"
    static let title = "title"
    static let description = "description"
    static let status = "status"
    static let answeredAt = "answeredAt"
}

/// Schema keys for Organization documents
enum OrganizationSchema {
    static let name = "name"
    static let slug = "slug"
    static let avatarUrl = "avatarUrl"
}

// MARK: - Document Extensions for Task

extension Document {
    /// Initialize document with task data
    func initializeTask(_ task: WorkTask) throws {
        try put(obj: .ROOT, key: TaskSchema.title, value: .String(task.title))
        try put(obj: .ROOT, key: TaskSchema.description, value: .String(task.taskDescription ?? ""))
        try put(obj: .ROOT, key: TaskSchema.status, value: .String(task.status))
        try put(obj: .ROOT, key: TaskSchema.priority, value: .Int(Int64(task.priority)))
        if let completedAt = task.completedAt {
            try put(obj: .ROOT, key: TaskSchema.completedAt, value: .Timestamp(completedAt))
        }
    }

    /// Apply document state to task
    func applyToTask(_ task: WorkTask) throws {
        if case .Scalar(.String(let title)) = try? get(obj: .ROOT, key: TaskSchema.title) {
            task.title = title
        }
        if case .Scalar(.String(let desc)) = try? get(obj: .ROOT, key: TaskSchema.description) {
            task.taskDescription = desc.isEmpty ? nil : desc
        }
        if case .Scalar(.String(let status)) = try? get(obj: .ROOT, key: TaskSchema.status) {
            task.status = status
        }
        if case .Scalar(.Int(let priority)) = try? get(obj: .ROOT, key: TaskSchema.priority) {
            task.priority = Int(priority)
        }
        if case .Scalar(.Timestamp(let completedAt)) = try? get(obj: .ROOT, key: TaskSchema.completedAt) {
            task.completedAt = completedAt
        }
    }

    /// Update a single field in a task document
    func updateTaskTitle(_ title: String) throws {
        try put(obj: .ROOT, key: TaskSchema.title, value: .String(title))
    }

    func updateTaskDescription(_ description: String?) throws {
        try put(obj: .ROOT, key: TaskSchema.description, value: .String(description ?? ""))
    }

    func updateTaskStatus(_ status: String) throws {
        try put(obj: .ROOT, key: TaskSchema.status, value: .String(status))
    }

    func updateTaskPriority(_ priority: Int) throws {
        try put(obj: .ROOT, key: TaskSchema.priority, value: .Int(Int64(priority)))
    }

    func updateTaskCompletedAt(_ completedAt: Date?) throws {
        if let completedAt {
            try put(obj: .ROOT, key: TaskSchema.completedAt, value: .Timestamp(completedAt))
        } else {
            try delete(obj: .ROOT, key: TaskSchema.completedAt)
        }
    }
}

// MARK: - Document Extensions for Workspace

extension Document {
    /// Initialize document with workspace data
    func initializeWorkspace(_ workspace: Workspace) throws {
        try put(obj: .ROOT, key: WorkspaceSchema.name, value: .String(workspace.name))
        try put(obj: .ROOT, key: WorkspaceSchema.slug, value: .String(workspace.slug))
        if let path = workspace.path {
            try put(obj: .ROOT, key: WorkspaceSchema.path, value: .String(path))
        }
    }

    /// Apply document state to workspace
    func applyToWorkspace(_ workspace: Workspace) throws {
        if case .Scalar(.String(let name)) = try? get(obj: .ROOT, key: WorkspaceSchema.name) {
            workspace.name = name
        }
        if case .Scalar(.String(let slug)) = try? get(obj: .ROOT, key: WorkspaceSchema.slug) {
            workspace.slug = slug
        }
        if case .Scalar(.String(let path)) = try? get(obj: .ROOT, key: WorkspaceSchema.path) {
            workspace.path = path.isEmpty ? nil : path
        }
    }

    /// Update workspace fields
    func updateWorkspaceName(_ name: String) throws {
        try put(obj: .ROOT, key: WorkspaceSchema.name, value: .String(name))
    }

    func updateWorkspaceSlug(_ slug: String) throws {
        try put(obj: .ROOT, key: WorkspaceSchema.slug, value: .String(slug))
    }

    func updateWorkspacePath(_ path: String?) throws {
        if let path {
            try put(obj: .ROOT, key: WorkspaceSchema.path, value: .String(path))
        } else {
            try delete(obj: .ROOT, key: WorkspaceSchema.path)
        }
    }
}

// MARK: - Document Extensions for Skill

extension Document {
    /// Initialize document with skill data
    func initializeSkill(_ skill: Skill) throws {
        try put(obj: .ROOT, key: SkillSchema.name, value: .String(skill.name))
        try put(obj: .ROOT, key: SkillSchema.content, value: .String(skill.content))
    }

    /// Apply document state to skill
    func applyToSkill(_ skill: Skill) throws {
        if case .Scalar(.String(let name)) = try? get(obj: .ROOT, key: SkillSchema.name) {
            skill.name = name
        }
        if case .Scalar(.String(let content)) = try? get(obj: .ROOT, key: SkillSchema.content) {
            skill.content = content
        }
    }

    /// Update skill fields
    func updateSkillName(_ name: String) throws {
        try put(obj: .ROOT, key: SkillSchema.name, value: .String(name))
    }

    func updateSkillContent(_ content: String) throws {
        try put(obj: .ROOT, key: SkillSchema.content, value: .String(content))
    }
}

// MARK: - Document Extensions for Context

extension Document {
    /// Initialize document with context data
    func initializeContext(_ context: Context) throws {
        try put(obj: .ROOT, key: ContextSchema.name, value: .String(context.name))
        try put(obj: .ROOT, key: ContextSchema.content, value: .String(context.content))
    }

    /// Apply document state to context
    func applyToContext(_ context: Context) throws {
        if case .Scalar(.String(let name)) = try? get(obj: .ROOT, key: ContextSchema.name) {
            context.name = name
        }
        if case .Scalar(.String(let content)) = try? get(obj: .ROOT, key: ContextSchema.content) {
            context.content = content
        }
    }

    /// Update context fields
    func updateContextName(_ name: String) throws {
        try put(obj: .ROOT, key: ContextSchema.name, value: .String(name))
    }

    func updateContextContent(_ content: String) throws {
        try put(obj: .ROOT, key: ContextSchema.content, value: .String(content))
    }
}

// MARK: - Document Extensions for Terminal

extension Document {
    /// Initialize document with terminal data
    func initializeTerminal(_ terminal: Terminal) throws {
        if let name = terminal.name {
            try put(obj: .ROOT, key: TerminalSchema.name, value: .String(name))
        }
        try put(obj: .ROOT, key: TerminalSchema.status, value: .String(terminal.status))
        try put(obj: .ROOT, key: TerminalSchema.startedAt, value: .Timestamp(terminal.startedAt))
        if let endedAt = terminal.endedAt {
            try put(obj: .ROOT, key: TerminalSchema.endedAt, value: .Timestamp(endedAt))
        }
        if let paneId = terminal.paneId {
            try put(obj: .ROOT, key: TerminalSchema.paneId, value: .String(paneId))
        }
    }

    /// Apply document state to terminal
    func applyToTerminal(_ terminal: Terminal) throws {
        if case .Scalar(.String(let name)) = try? get(obj: .ROOT, key: TerminalSchema.name) {
            terminal.name = name.isEmpty ? nil : name
        }
        if case .Scalar(.String(let status)) = try? get(obj: .ROOT, key: TerminalSchema.status) {
            terminal.status = status
        }
        if case .Scalar(.Timestamp(let startedAt)) = try? get(obj: .ROOT, key: TerminalSchema.startedAt) {
            terminal.startedAt = startedAt
        }
        if case .Scalar(.Timestamp(let endedAt)) = try? get(obj: .ROOT, key: TerminalSchema.endedAt) {
            terminal.endedAt = endedAt
        }
        if case .Scalar(.String(let paneId)) = try? get(obj: .ROOT, key: TerminalSchema.paneId) {
            terminal.paneId = paneId.isEmpty ? nil : paneId
        }
    }

    /// Update terminal fields
    func updateTerminalName(_ name: String?) throws {
        if let name {
            try put(obj: .ROOT, key: TerminalSchema.name, value: .String(name))
        } else {
            try delete(obj: .ROOT, key: TerminalSchema.name)
        }
    }

    func updateTerminalStatus(_ status: String) throws {
        try put(obj: .ROOT, key: TerminalSchema.status, value: .String(status))
    }

    func updateTerminalEndedAt(_ endedAt: Date?) throws {
        if let endedAt {
            try put(obj: .ROOT, key: TerminalSchema.endedAt, value: .Timestamp(endedAt))
        } else {
            try delete(obj: .ROOT, key: TerminalSchema.endedAt)
        }
    }
}

// MARK: - Document Extensions for Hint

extension Document {
    /// Initialize document with hint data
    func initializeHint(_ hint: Hint) throws {
        try put(obj: .ROOT, key: HintSchema.type, value: .String(hint.type))
        try put(obj: .ROOT, key: HintSchema.title, value: .String(hint.title))
        if let desc = hint.hintDescription {
            try put(obj: .ROOT, key: HintSchema.description, value: .String(desc))
        }
        try put(obj: .ROOT, key: HintSchema.status, value: .String(hint.status))
        if let answeredAt = hint.answeredAt {
            try put(obj: .ROOT, key: HintSchema.answeredAt, value: .Timestamp(answeredAt))
        }
    }

    /// Apply document state to hint
    func applyToHint(_ hint: Hint) throws {
        if case .Scalar(.String(let type)) = try? get(obj: .ROOT, key: HintSchema.type) {
            hint.type = type
        }
        if case .Scalar(.String(let title)) = try? get(obj: .ROOT, key: HintSchema.title) {
            hint.title = title
        }
        if case .Scalar(.String(let desc)) = try? get(obj: .ROOT, key: HintSchema.description) {
            hint.hintDescription = desc.isEmpty ? nil : desc
        }
        if case .Scalar(.String(let status)) = try? get(obj: .ROOT, key: HintSchema.status) {
            hint.status = status
        }
        if case .Scalar(.Timestamp(let answeredAt)) = try? get(obj: .ROOT, key: HintSchema.answeredAt) {
            hint.answeredAt = answeredAt
        }
    }

    /// Update hint fields
    func updateHintStatus(_ status: String) throws {
        try put(obj: .ROOT, key: HintSchema.status, value: .String(status))
    }

    func updateHintAnsweredAt(_ answeredAt: Date?) throws {
        if let answeredAt {
            try put(obj: .ROOT, key: HintSchema.answeredAt, value: .Timestamp(answeredAt))
        } else {
            try delete(obj: .ROOT, key: HintSchema.answeredAt)
        }
    }
}

// MARK: - Document Extensions for Organization

extension Document {
    /// Initialize document with organization data
    func initializeOrganization(_ org: Organization) throws {
        try put(obj: .ROOT, key: OrganizationSchema.name, value: .String(org.name))
        try put(obj: .ROOT, key: OrganizationSchema.slug, value: .String(org.slug))
        if let avatarUrl = org.avatarUrl {
            try put(obj: .ROOT, key: OrganizationSchema.avatarUrl, value: .String(avatarUrl))
        }
    }

    /// Apply document state to organization
    func applyToOrganization(_ org: Organization) throws {
        if case .Scalar(.String(let name)) = try? get(obj: .ROOT, key: OrganizationSchema.name) {
            org.name = name
        }
        if case .Scalar(.String(let slug)) = try? get(obj: .ROOT, key: OrganizationSchema.slug) {
            org.slug = slug
        }
        if case .Scalar(.String(let avatarUrl)) = try? get(obj: .ROOT, key: OrganizationSchema.avatarUrl) {
            org.avatarUrl = avatarUrl.isEmpty ? nil : avatarUrl
        }
    }

    /// Update organization fields
    func updateOrganizationName(_ name: String) throws {
        try put(obj: .ROOT, key: OrganizationSchema.name, value: .String(name))
    }

    func updateOrganizationSlug(_ slug: String) throws {
        try put(obj: .ROOT, key: OrganizationSchema.slug, value: .String(slug))
    }

    func updateOrganizationAvatarUrl(_ avatarUrl: String?) throws {
        if let avatarUrl {
            try put(obj: .ROOT, key: OrganizationSchema.avatarUrl, value: .String(avatarUrl))
        } else {
            try delete(obj: .ROOT, key: OrganizationSchema.avatarUrl)
        }
    }
}
