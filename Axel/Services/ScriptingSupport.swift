#if os(macOS)
import Foundation
import AppKit
import SwiftData

// MARK: - Scriptable Objects

/// Scriptable wrapper for Workspace
@objc(ScriptableWorkspace)
class ScriptableWorkspace: NSObject {
    let workspace: Workspace

    init(_ workspace: Workspace) {
        self.workspace = workspace
        super.init()
    }

    @objc var uniqueID: String {
        workspace.id.uuidString
    }

    @objc var name: String {
        workspace.name
    }

    @objc var path: String {
        workspace.path ?? ""
    }

    @objc var scriptingTasks: [ScriptableTask] {
        workspace.tasks.map { ScriptableTask($0) }
    }

    @objc var scriptingAgents: [ScriptableAgent] {
        guard let workspaceId = workspace.id as UUID? else { return [] }
        return MainActor.assumeIsolated {
            ScriptingBridge.shared.getAgents(for: workspaceId)
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let appDescription = NSApp.classDescription as? NSScriptClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: appDescription,
            containerSpecifier: nil,
            key: "scriptingWorkspaces",
            uniqueID: uniqueID
        )
    }
}

/// Scriptable wrapper for WorkTask
@objc(ScriptableTask)
class ScriptableTask: NSObject {
    let task: WorkTask

    init(_ task: WorkTask) {
        self.task = task
        super.init()
    }

    @objc var uniqueID: String {
        task.id.uuidString
    }

    @objc var name: String {
        get { task.title }
        set { task.title = newValue }
    }

    @objc var taskDescription: String {
        get { task.taskDescription ?? "" }
        set { task.taskDescription = newValue }
    }

    @objc var status: FourCharCode {
        switch task.taskStatus {
        case .backlog: return fourCharCode("Tbkl")
        case .queued: return fourCharCode("Tque")
        case .running: return fourCharCode("Trun")
        case .completed: return fourCharCode("Tcmp")
        case .inReview: return fourCharCode("Trev")
        case .aborted: return fourCharCode("Tabt")
        }
    }

    @objc var priority: Int {
        get { task.priority }
        set { task.priority = newValue }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let workspace = task.workspace,
              let workspaceSpecifier = ScriptableWorkspace(workspace).objectSpecifier,
              let workspaceDescription = workspaceSpecifier.keyClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: workspaceDescription,
            containerSpecifier: workspaceSpecifier,
            key: "scriptingTasks",
            uniqueID: uniqueID
        )
    }
}

/// Scriptable wrapper for terminal sessions (agents)
@objc(ScriptableAgent)
class ScriptableAgent: NSObject {
    let paneId: String
    let displayName: String
    let providerName: String
    let worktreeBranch: String?
    let hasTask: Bool
    let workspaceId: UUID

    init(paneId: String, displayName: String, provider: String, worktree: String?, hasTask: Bool, workspaceId: UUID) {
        self.paneId = paneId
        self.displayName = displayName
        self.providerName = provider
        self.worktreeBranch = worktree
        self.hasTask = hasTask
        self.workspaceId = workspaceId
        super.init()
    }

    @objc var uniqueID: String { paneId }
    @objc var name: String { displayName }
    @objc var provider: String { providerName }
    @objc var worktree: String { worktreeBranch ?? "" }
    @objc var isBusy: Bool { hasTask }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let workspace = MainActor.assumeIsolated({ ScriptingBridge.shared.findWorkspace(by: workspaceId) }),
              let workspaceSpecifier = ScriptableWorkspace(workspace).objectSpecifier,
              let workspaceDescription = workspaceSpecifier.keyClassDescription else {
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: workspaceDescription,
            containerSpecifier: workspaceSpecifier,
            key: "scriptingAgents",
            uniqueID: uniqueID
        )
    }
}

// MARK: - Scripting Bridge

/// Central bridge between AppleScript and the app
@MainActor
final class ScriptingBridge {
    static let shared = ScriptingBridge()

    private var modelContainer: ModelContainer?

    private init() {}

    /// Configure the scripting bridge with the model container
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private var modelContext: ModelContext? {
        modelContainer?.mainContext
    }

    func getWorkspaces() -> [Workspace] {
        guard let context = modelContext else { return [] }
        let descriptor = FetchDescriptor<Workspace>(sortBy: [SortDescriptor(\.name)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func findWorkspace(by id: UUID) -> Workspace? {
        getWorkspaces().first { $0.id == id }
    }

    func findWorkspace(byName name: String) -> Workspace? {
        getWorkspaces().first { $0.name.lowercased() == name.lowercased() }
    }

    func findTask(by id: UUID) -> WorkTask? {
        guard let context = modelContext else { return nil }
        let descriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func getAgents(for workspaceId: UUID) -> [ScriptableAgent] {
        // Get agents from InboxService which tracks all terminal sessions
        return InboxService.shared.getScriptableAgents(for: workspaceId)
    }

    func createTask(title: String, description: String?, priority: Int?, in workspace: Workspace) -> WorkTask {
        let task = WorkTask(title: title)
        task.taskDescription = description
        task.workspace = workspace
        if let priority = priority {
            task.priority = priority
        }
        modelContext?.insert(task)
        try? modelContext?.save()
        return task
    }

    func requestStartAgent(in workspaceId: UUID, worktree: String?, provider: AIProvider, taskId: UUID? = nil) {
        // Post notification that workspace views can listen to
        NotificationCenter.default.post(
            name: .scriptingStartAgent,
            object: nil,
            userInfo: [
                "workspaceId": workspaceId,
                "worktree": worktree as Any,
                "provider": provider,
                "taskId": taskId as Any
            ]
        )
    }
}

// MARK: - NSApplication Extension for Scripting

extension NSApplication {
    @objc var scriptingWorkspaces: [ScriptableWorkspace] {
        Task { @MainActor in
            ScriptingBridge.shared.getWorkspaces()
        }
        // Synchronous fallback - scripting requires immediate response
        return MainActor.assumeIsolated {
            ScriptingBridge.shared.getWorkspaces().map { ScriptableWorkspace($0) }
        }
    }
}

// MARK: - Script Commands

/// Create a new task
@objc(CreateTaskCommand)
class CreateTaskCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let title = directParameter as? String else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Task title is required"
            return nil
        }

        guard let workspaceArg = arguments?["inWorkspace"],
              let scriptableWorkspace = workspaceArg as? ScriptableWorkspace else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Workspace is required"
            return nil
        }

        let description = arguments?["withDescription"] as? String
        let priority = arguments?["priority"] as? Int

        let task = MainActor.assumeIsolated {
            ScriptingBridge.shared.createTask(
                title: title,
                description: description,
                priority: priority,
                in: scriptableWorkspace.workspace
            )
        }

        return ScriptableTask(task)
    }
}

/// Run a task with an agent
@objc(RunTaskCommand)
class RunTaskCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let taskArg = directParameter,
              let scriptableTask = taskArg as? ScriptableTask else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Task is required"
            return nil
        }

        let task = scriptableTask.task
        let worktree = arguments?["worktree"] as? String
        let providerCode = arguments?["provider"] as? FourCharCode

        let provider: AIProvider
        if let code = providerCode {
            switch code {
            case fourCharCode("Pcld"): provider = .claude
            case fourCharCode("Pcdx"): provider = .codex
            case fourCharCode("Pshl"): provider = .shell
            default: provider = .claude
            }
        } else {
            provider = .claude
        }

        // Check if assigning to existing agent
        if let agentArg = arguments?["withAgent"],
           let scriptableAgent = agentArg as? ScriptableAgent {
            // Queue task on existing agent
            MainActor.assumeIsolated {
                task.updateStatus(TaskStatus.queued)
                TaskQueueService.shared.enqueue(taskId: task.id, onTerminal: scriptableAgent.paneId)
            }
            return scriptableAgent
        }

        // Create new agent for the task
        guard let workspace = task.workspace else {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = "Task has no workspace"
            return nil
        }

        MainActor.assumeIsolated {
            ScriptingBridge.shared.requestStartAgent(
                in: workspace.id,
                worktree: worktree,
                provider: provider,
                taskId: task.id
            )
        }

        // Return a placeholder agent (the actual agent will be created asynchronously)
        return ScriptableAgent(
            paneId: "pending",
            displayName: "Starting...",
            provider: provider.displayName,
            worktree: worktree,
            hasTask: true,
            workspaceId: workspace.id
        )
    }
}

/// Start a new agent without a task
@objc(StartAgentCommand)
class StartAgentCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let workspaceArg = arguments?["inWorkspace"],
              let scriptableWorkspace = workspaceArg as? ScriptableWorkspace else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Workspace is required"
            return nil
        }

        let worktree = arguments?["worktree"] as? String
        let providerCode = arguments?["provider"] as? FourCharCode

        let provider: AIProvider
        if let code = providerCode {
            switch code {
            case fourCharCode("Pcld"): provider = .claude
            case fourCharCode("Pcdx"): provider = .codex
            case fourCharCode("Pshl"): provider = .shell
            default: provider = .claude
            }
        } else {
            provider = .claude
        }

        MainActor.assumeIsolated {
            ScriptingBridge.shared.requestStartAgent(
                in: scriptableWorkspace.workspace.id,
                worktree: worktree,
                provider: provider
            )
        }

        return ScriptableAgent(
            paneId: "pending",
            displayName: "Starting...",
            provider: provider.displayName,
            worktree: worktree,
            hasTask: false,
            workspaceId: scriptableWorkspace.workspace.id
        )
    }
}

/// Complete a task
@objc(CompleteTaskCommand)
class CompleteTaskCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let taskArg = directParameter,
              let scriptableTask = taskArg as? ScriptableTask else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Task is required"
            return nil
        }

        MainActor.assumeIsolated {
            scriptableTask.task.markCompleted()
        }
        return nil
    }
}

/// List worktrees in a workspace
@objc(ListWorktreesCommand)
class ListWorktreesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let workspaceArg = directParameter,
              let scriptableWorkspace = workspaceArg as? ScriptableWorkspace else {
            scriptErrorNumber = errAEParamMissed
            scriptErrorString = "Workspace is required"
            return nil
        }

        guard let path = scriptableWorkspace.workspace.path, !path.isEmpty else {
            return [] as [String]
        }

        // Synchronously fetch worktrees
        let worktrees = MainActor.assumeIsolated {
            // Use a semaphore to make the async call synchronous
            var result: [String] = []
            let semaphore = DispatchSemaphore(value: 0)

            Task {
                let infos = await WorktreeService.shared.listWorktrees(in: path)
                result = infos.map { $0.displayName }
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 5)
            return result
        }

        return worktrees
    }
}

// MARK: - Helpers

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}
#endif
