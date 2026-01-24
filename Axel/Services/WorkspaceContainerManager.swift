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
    }

    /// Get workspace from workspace-specific container
    func workspace(from container: ModelContainer, id: UUID) throws -> Workspace? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

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
