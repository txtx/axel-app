import Foundation
import SwiftData

#if os(macOS)
/// Manages per-workspace SQLite databases on macOS.
///
/// Architecture:
/// - Shared DB (`~/.config/axel/shared.sqlite`): Profile, Organization, OrganizationMember, Workspace
/// - Per-workspace DB (`~/.config/axel/workspaces/{id}.sqlite`): WorkTask, Skill, Context, Terminal, Hint, etc.
@MainActor
final class WorkspaceContainerManager {
    static let shared = WorkspaceContainerManager()

    /// The shared container for user settings and workspace metadata (lazily initialized)
    private var _sharedContainer: ModelContainer?

    /// Returns the shared container, initializing it if needed
    /// This is now a computed property that initializes lazily
    var sharedContainer: ModelContainer {
        get throws {
            if let container = _sharedContainer {
                return container
            }
            let container = try initializeSharedContainer()
            _sharedContainer = container
            return container
        }
    }

    /// Check if the shared container is already initialized
    var isInitialized: Bool {
        _sharedContainer != nil
    }

    /// Cache of workspace-specific containers
    private var workspaceContainers: [UUID: ModelContainer] = [:]

    /// Base directory for all axel data
    private let baseDir: URL

    /// Directory for workspace databases
    private let workspacesDir: URL

    /// Schema for shared database (user settings, workspace list for picker)
    private static let sharedSchema = Schema([
        Profile.self,
        Organization.self,
        OrganizationMember.self,
        Workspace.self
    ])

    /// Schema for workspace-specific database (includes Workspace for relationships)
    /// Each workspace DB has its own copy of the Workspace object so relationships work
    private static let workspaceSchema = Schema([
        Workspace.self,  // Needed for relationships to work
        WorkTask.self,
        TaskAssignee.self,
        TaskComment.self,
        TaskAttachment.self,
        Terminal.self,
        TaskDispatch.self,
        Hint.self,
        Skill.self,
        Context.self,
        Profile.self,  // For createdBy relationship
        Organization.self,
        OrganizationMember.self
    ])

    private init() {
        // Set up directories only - defer container initialization
        baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("axel")

        workspacesDir = baseDir.appendingPathComponent("workspaces")

        // Create directories if needed (this is fast)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: workspacesDir, withIntermediateDirectories: true)
    }

    /// Initialize the shared container (called lazily or explicitly during async load)
    private func initializeSharedContainer() throws -> ModelContainer {
        let sharedDbUrl = baseDir.appendingPathComponent("shared.sqlite")
        let sharedConfig = ModelConfiguration(
            schema: Self.sharedSchema,
            url: sharedDbUrl,
            allowsSave: true
        )
        return try ModelContainer(for: Self.sharedSchema, configurations: [sharedConfig])
    }

    /// Initialize the container if not already done
    /// Call this from a view's .task modifier to avoid blocking scene creation
    func ensureInitialized() throws -> ModelContainer {
        if let container = _sharedContainer {
            return container
        }
        let container = try initializeSharedContainer()
        _sharedContainer = container
        return container
    }

    /// Get or create a container for a specific workspace
    func container(for workspaceId: UUID) throws -> ModelContainer {
        if let existing = workspaceContainers[workspaceId] {
            return existing
        }

        let dbUrl = workspacesDir.appendingPathComponent("\(workspaceId.uuidString).sqlite")
        let config = ModelConfiguration(
            schema: Self.workspaceSchema,
            url: dbUrl,
            allowsSave: true
        )

        let container = try ModelContainer(for: Self.workspaceSchema, configurations: [config])
        workspaceContainers[workspaceId] = container
        return container
    }

    /// Ensure workspace exists in workspace-specific container
    /// Copies workspace metadata and organization from shared to workspace container if needed
    func ensureWorkspaceInContainer(_ workspace: Workspace, container: ModelContainer) throws {
        let context = container.mainContext
        let workspaceId = workspace.id

        // First, ensure organization exists in workspace container if workspace has one
        var localOrg: Organization?
        if let sharedOrg = workspace.organization {
            let orgId = sharedOrg.id
            let orgDescriptor = FetchDescriptor<Organization>(
                predicate: #Predicate { $0.id == orgId }
            )
            let existingOrgs = try context.fetch(orgDescriptor)
            if existingOrgs.isEmpty {
                // Copy organization to workspace container
                let newOrg = Organization(name: sharedOrg.name, slug: sharedOrg.slug)
                newOrg.id = sharedOrg.id
                newOrg.syncId = sharedOrg.syncId
                newOrg.createdAt = sharedOrg.createdAt
                newOrg.updatedAt = sharedOrg.updatedAt
                context.insert(newOrg)
                localOrg = newOrg
                print("[WorkspaceContainerManager] Created organization in workspace container: \(sharedOrg.name)")
            } else {
                localOrg = existingOrgs.first
                // Update syncId if it changed
                if let org = localOrg, org.syncId != sharedOrg.syncId {
                    org.syncId = sharedOrg.syncId
                }
            }
        }

        // Check if workspace already exists in this container
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == workspaceId }
        )

        let existing = try context.fetch(descriptor)
        if existing.isEmpty {
            // Create workspace in workspace container
            let localWorkspace = Workspace(name: workspace.name, slug: workspace.slug, path: workspace.path)
            localWorkspace.id = workspace.id
            localWorkspace.syncId = workspace.syncId
            localWorkspace.createdAt = workspace.createdAt
            localWorkspace.updatedAt = workspace.updatedAt
            localWorkspace.organization = localOrg
            context.insert(localWorkspace)
            try context.save()
            print("[WorkspaceContainerManager] Created workspace in container: \(workspace.name)")
        } else {
            // Update workspace metadata if needed
            if let local = existing.first {
                var needsSave = false
                if local.name != workspace.name || local.slug != workspace.slug || local.path != workspace.path {
                    local.name = workspace.name
                    local.slug = workspace.slug
                    local.path = workspace.path
                    local.updatedAt = workspace.updatedAt
                    needsSave = true
                }
                // Update syncId if it changed (important for sync)
                if local.syncId != workspace.syncId {
                    local.syncId = workspace.syncId
                    needsSave = true
                }
                // Update organization if changed
                if local.organization?.id != localOrg?.id {
                    local.organization = localOrg
                    needsSave = true
                }
                if needsSave {
                    try context.save()
                    print("[WorkspaceContainerManager] Updated workspace in container: \(workspace.name)")
                }
            }
        }

        // Create "Initialize workspace" task if no AXEL.md exists
        try createInitializeWorkspaceTaskIfNeeded(workspace, container: container)
    }

    /// Get workspace from workspace-specific container
    func workspace(from container: ModelContainer, id: UUID) throws -> Workspace? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// Check if AXEL.md exists at the workspace path
    private func hasAxelManifest(at workspacePath: String?) -> Bool {
        guard let path = workspacePath else { return false }
        let manifestPath = (path as NSString).appendingPathComponent("AXEL.md")
        return FileManager.default.fileExists(atPath: manifestPath)
    }

    /// Create the default "Initialize workspace" task when no AXEL.md exists
    /// This task provides instructions for the AI agent to analyze the repo and create an appropriate AXEL.md
    func createInitializeWorkspaceTaskIfNeeded(_ workspace: Workspace, container: ModelContainer) throws {
        // Helper to write debug logs
        func debugLog(_ message: String) {
            let debugMsg = "[DEBUG \(Date())] \(message)\n"
            let debugPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/axel/init-task-debug.log")
            if let data = debugMsg.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: debugPath.path) {
                    if let handle = try? FileHandle(forWritingTo: debugPath) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: debugPath)
                }
            }
            print("[WorkspaceContainerManager] \(message)")
        }

        debugLog("Checking init task for: \(workspace.name), path: \(workspace.path ?? "nil")")

        // Skip if workspace has no path
        guard let workspacePath = workspace.path else {
            debugLog("SKIP: no workspace path")
            return
        }

        // Skip if AXEL.md already exists
        if hasAxelManifest(at: workspacePath) {
            debugLog("SKIP: AXEL.md exists at \(workspacePath)")
            return
        }

        debugLog("No AXEL.md found, checking for existing task...")

        let context = container.mainContext

        // Check if we already have an active "Initialize workspace" task to avoid duplicates
        // Only skip if there's a pending/queued/running init task
        // If the task was completed/aborted but AXEL.md is missing, create a new one
        let descriptor = FetchDescriptor<WorkTask>()
        let existingTasks = try context.fetch(descriptor)
        debugLog("Found \(existingTasks.count) existing tasks")

        let activeInitTask = existingTasks.first { task in
            let isInitTask = task.title.lowercased().contains("initialize workspace")
            let isActive = task.status != TaskStatus.completed.rawValue && task.status != TaskStatus.aborted.rawValue
            return isInitTask && isActive
        }
        if activeInitTask != nil {
            debugLog("SKIP: active init task already exists (status: \(activeInitTask?.status ?? "unknown"))")
            return
        }

        debugLog("No init task exists, fetching local workspace...")

        // Get the local workspace from this container (not the shared container's workspace)
        let workspaceId = workspace.id
        let workspaceDescriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == workspaceId }
        )
        guard let localWorkspace = try context.fetch(workspaceDescriptor).first else {
            debugLog("SKIP: local workspace not found for id \(workspaceId)")
            return
        }

        debugLog("Creating init task...")

        // Create the task with comprehensive instructions
        let task = WorkTask(
            title: "Initialize workspace",
            description: Self.initializeWorkspaceDescription
        )
        task.workspace = localWorkspace
        context.insert(task)
        try context.save()
        debugLog("✓ Created 'Initialize workspace' task for: \(workspace.name)")
    }

    /// The description/instructions for the "Initialize workspace" task
    private static let initializeWorkspaceDescription = """
## Task: Create an AXEL.md workspace configuration

This workspace doesn't have an `AXEL.md` file yet. Analyze the repository to understand its structure and create an appropriate workspace layout configuration.

### What is AXEL.md?

AXEL.md is a markdown file with YAML frontmatter that defines the workspace layout for the Axel terminal manager. It configures:
- **Panes**: AI agents (Claude, Codex, etc.) and shell terminals
- **Grids**: How panes are arranged in tmux sessions

### AXEL.md Schema

```yaml
---
workspace: my-project-name

layouts:
  panes:
    # AI agent types: claude, codex, opencode, antigravity
    - type: claude
      color: gray           # UI color: purple, yellow, red, green, blue, gray, orange
      skills: ["*"]         # Skills to load, "*" for all
      # model: sonnet       # Optional: sonnet, opus, haiku
      # prompt: "..."       # Optional: initial system prompt

    # Custom panes (shells, commands) - use unique names!
    - type: custom
      name: shell           # Unique name for referencing in grids
      notes:
        - "$ npm run dev"   # Startup notes/commands

    # Custom command pane example
    # - type: custom
    #   name: logs
    #   command: "tail -f logs/app.log"
    #   color: red

  grids:
    default:
      type: tmux            # tmux, tmux_cc (iTerm2), or shell (no tmux)
      claude:               # References pane with name "claude"
        col: 0              # Column position (0, 1, 2...)
        row: 0              # Row position within column
        # width: 50         # Column width percentage
        # height: 50        # Row height percentage
      shell:                # References pane with name "shell"
        col: 1
        row: 0
        color: yellow
---

# my-project-name

Workspace description here.
```

### Steps to Complete This Task

1. **Analyze the repository**:
   - Check for `package.json` (Node.js), `Cargo.toml` (Rust), `pyproject.toml`/`requirements.txt` (Python), etc.
   - Look at existing scripts (dev servers, build commands, test runners)
   - Identify what commands developers typically run

2. **Choose an appropriate layout**:

   **For a Node.js/Frontend app:**
   ```yaml
   workspace: my-nodejs-app

   layouts:
     panes:
       - type: claude
         color: gray
         skills: ["*"]
       - type: custom
         name: shell
         notes:
           - "$ npm run dev"

     grids:
       default:
         type: tmux
         claude:
           col: 0
           row: 0
           width: 50
         shell:
           col: 1
           row: 0
   ```

   **For a Rust project:**
   ```yaml
   workspace: my-rust-project

   layouts:
     panes:
       - type: claude
         color: gray
         skills: ["*"]
       - type: custom
         name: shell
         notes:
           - "$ cargo watch -x run"

     grids:
       default:
         type: tmux
         claude:
           col: 0
           row: 0
         shell:
           col: 1
           row: 0
   ```

   **For a Python project:**
   ```yaml
   workspace: my-python-project

   layouts:
     panes:
       - type: claude
         color: gray
         skills: ["*"]
       - type: custom
         name: shell
         notes:
           - "$ python -m pytest --watch"

     grids:
       default:
         type: tmux
         claude:
           col: 0
           row: 0
         shell:
           col: 1
           row: 0
   ```

   **Popular layout (Claude left, shell + app on right) - RECOMMENDED:**

   Many developers prefer Claude on the left half of the screen, with the right side split vertically: a free shell on top for ad-hoc commands, and the app/dev server running beneath.

   ```yaml
   workspace: my-project

   layouts:
     panes:
       - type: claude
         color: gray
         skills: ["*"]
       - type: custom
         name: shell
         notes:
           - "Free shell for commands"
       - type: custom
         name: dev_server
         notes:
           - "$ npm run dev"  # or your dev server command

     grids:
       default:
         type: tmux
         claude:
           col: 0
           row: 0
           width: 50
         shell:
           col: 1
           row: 0
           height: 40
         dev_server:
           col: 1
           row: 1
           height: 60
   ```

3. **Create the AXEL.md file** at the repository root with your chosen configuration.

4. **Add a brief description** below the frontmatter explaining the workspace purpose.

### Tips

- **Most popular layout**: Claude on left (50%), right side split with free shell on top (40%) and dev server below (60%)
- Keep layouts simple - 2-3 panes is usually enough
- Put the AI agent (claude) on the left half of the screen
- Stack shells vertically on the right side
- Use `notes` to remind users what commands to run in each shell
- **Use unique names**: For multiple custom panes, use `type: custom` with unique `name` values (e.g., "shell", "dev_server", "logs")
- Color-code panes for easy identification
"""

    /// Get the database URL for a workspace (for debugging/diagnostics)
    func databaseUrl(for workspaceId: UUID) -> URL {
        workspacesDir.appendingPathComponent("\(workspaceId.uuidString).sqlite")
    }

    /// Remove a workspace's database (when workspace is deleted)
    func deleteDatabase(for workspaceId: UUID) {
        workspaceContainers.removeValue(forKey: workspaceId)
        let dbUrl = databaseUrl(for: workspaceId)
        try? FileManager.default.removeItem(at: dbUrl)
        // Also remove WAL and SHM files
        try? FileManager.default.removeItem(at: dbUrl.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: dbUrl.appendingPathExtension("shm"))
    }

    /// List all workspace database IDs
    func listWorkspaceDatabases() -> [UUID] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: workspacesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url -> UUID? in
            guard url.pathExtension == "sqlite" else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }
}
#endif
