import AutomergeWrapper
import Foundation
import SwiftData
import Supabase

// MARK: - Background Automerge Processing

/// Processed task fields extracted from Automerge document (used for background processing)
private struct ProcessedTaskFields: Sendable {
    let id: UUID
    let title: String?
    let description: String?
    let status: String?
    let priority: Int?
    let completedAt: Date?
    let documentBytes: Data // The merged/loaded document bytes to store
    let needsRepair: Bool
}

/// Process Automerge bytes in background and extract field values
/// This runs off the main thread to avoid UI freezes
private func processAutomergeBytesInBackground(
    remoteTasks: [SyncTask],
    localSyncIds: Set<UUID>,
    existingDocBytes: [UUID: Data]
) async -> [UUID: ProcessedTaskFields] {
    await Task.detached(priority: .userInitiated) {
        var results: [UUID: ProcessedTaskFields] = [:]

        for remote in remoteTasks {
            guard let remoteBytes = remote.automergeDocData else {
                // No automerge doc - will use field-level merge on main thread
                continue
            }

            do {
                let mergedDoc: Document

                if let existingBytes = existingDocBytes[remote.id] {
                    // Merge with existing local doc
                    let localDoc = try Document(existingBytes)
                    let remoteDoc = try Document(remoteBytes)
                    try localDoc.merge(other: remoteDoc)
                    mergedDoc = localDoc
                } else {
                    // Just load the remote doc
                    mergedDoc = try Document(remoteBytes)
                }

                // Extract field values from merged document
                let title: String? = {
                    if case .Scalar(.String(let v)) = try? mergedDoc.get(obj: .ROOT, key: TaskSchema.title) {
                        return v
                    }
                    return nil
                }()

                let description: String? = {
                    if case .Scalar(.String(let v)) = try? mergedDoc.get(obj: .ROOT, key: TaskSchema.description) {
                        return v.isEmpty ? nil : v
                    }
                    return nil
                }()

                let status: String? = {
                    if case .Scalar(.String(let v)) = try? mergedDoc.get(obj: .ROOT, key: TaskSchema.status) {
                        return v
                    }
                    return nil
                }()

                let priority: Int? = {
                    if case .Scalar(.Int(let v)) = try? mergedDoc.get(obj: .ROOT, key: TaskSchema.priority) {
                        return Int(v)
                    }
                    return nil
                }()

                let completedAt: Date? = {
                    if case .Scalar(.Timestamp(let v)) = try? mergedDoc.get(obj: .ROOT, key: TaskSchema.completedAt) {
                        return v
                    }
                    return nil
                }()

                results[remote.id] = ProcessedTaskFields(
                    id: remote.id,
                    title: title,
                    description: description,
                    status: status,
                    priority: priority,
                    completedAt: completedAt,
                    documentBytes: mergedDoc.save(),
                    needsRepair: false
                )
            } catch {
                // Mark for repair - will use field-level merge
                results[remote.id] = ProcessedTaskFields(
                    id: remote.id,
                    title: nil,
                    description: nil,
                    status: nil,
                    priority: nil,
                    completedAt: nil,
                    documentBytes: Data(),
                    needsRepair: true
                )
            }
        }

        return results
    }.value
}

// MARK: - Background Sync Worker (runs off main thread)

/// Actor that performs sync work entirely off the main thread
private actor BackgroundSyncWorker {
    static func performSync(container: ModelContainer, syncService: SyncService) async {
        // Use lock to prevent concurrent sync operations that could create duplicate records
        guard syncService.tryAcquireSyncLock() else {
            print("[BackgroundSync] Skipping: another sync in progress")
            return
        }
        defer { syncService.releaseSyncLock() }

        // Check auth
        let authService = await AuthService.shared
        await authService.checkSession()
        let isAuthenticated = await authService.isAuthenticated
        guard isAuthenticated else {
            print("[BackgroundSync] Skipping: not authenticated")
            return
        }

        await MainActor.run { syncService.isSyncing = true; syncService.syncError = nil }

        // Create background context
        let context = ModelContext(container)
        context.autosaveEnabled = false // We'll save manually

        guard let supabase = await SupabaseManager.shared.client else {
            print("[BackgroundSync] Supabase disabled (missing config)")
            await MainActor.run { syncService.isSyncing = false }
            return
        }

        do {
            // Pull all data
            try await pullOrganizations(context: context, supabase: supabase)
            try await pullWorkspaces(context: context, supabase: supabase)
            try await pullTasks(context: context, supabase: supabase)
            try await pullSkills(context: context, supabase: supabase)
            try await pullContexts(context: context, supabase: supabase)
            try await pullTerminals(context: context, supabase: supabase)
            try await pullHints(context: context, supabase: supabase)

            try context.save()

            await MainActor.run { syncService.lastSyncDate = Date() }
            print("[BackgroundSync] Completed successfully")
        } catch {
            await MainActor.run { syncService.syncError = error }
            print("[BackgroundSync] Error: \(error)")
        }

        await MainActor.run { syncService.isSyncing = false }
    }

    // MARK: - Pull Operations (simplified for background)

    private static func pullOrganizations(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncOrganization] = try await supabase.from("organizations").select().execute().value
        let descriptor = FetchDescriptor<Organization>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary(local.compactMap { o -> (UUID, Organization)? in
            guard let syncId = o.syncId else { return nil }
            return (syncId, o)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                if r.updatedAt > l.updatedAt {
                    l.name = r.name
                    l.slug = r.slug
                    l.updatedAt = r.updatedAt
                }
            } else {
                let org = Organization(name: r.name, slug: r.slug)
                org.syncId = r.id
                org.createdAt = r.createdAt
                org.updatedAt = r.updatedAt
                context.insert(org)
            }
        }
    }

    private static func pullWorkspaces(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncWorkspace] = try await supabase.from("workspaces").select().execute().value
        let descriptor = FetchDescriptor<Workspace>()
        let local = try context.fetch(descriptor)

        // Index local workspaces by syncId
        let localBySyncId = Dictionary(local.compactMap { w -> (UUID, Workspace)? in
            guard let syncId = w.syncId else { return nil }
            return (syncId, w)
        }, uniquingKeysWith: { first, _ in first })

        // Also index by slug for matching unsynced local workspaces
        let localBySlug = Dictionary(local.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })

        let orgDescriptor = FetchDescriptor<Organization>()
        let orgs = try context.fetch(orgDescriptor)
        let orgById = Dictionary(orgs.compactMap { o -> (UUID, Organization)? in
            guard let syncId = o.syncId else { return nil }
            return (syncId, o)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            // First, try to find by syncId (already linked)
            if let l = localBySyncId[r.id] {
                if r.updatedAt > l.updatedAt {
                    l.name = r.name
                    l.slug = r.slug
                    l.updatedAt = r.updatedAt
                    if let orgId = r.organizationId {
                        l.organization = orgById[orgId]
                    }
                }
            }
            // Next, try to find by slug (not yet linked - link them now)
            else if let l = localBySlug[r.slug], l.syncId == nil {
                print("[SyncService] Linking local workspace '\(l.slug)' to remote ID: \(r.id)")
                l.syncId = r.id
                l.name = r.name
                l.updatedAt = r.updatedAt
                if let orgId = r.organizationId {
                    l.organization = orgById[orgId]
                }
            }
            // Not found locally - create new
            else {
                let ws = Workspace(name: r.name, slug: r.slug)
                ws.syncId = r.id
                ws.createdAt = r.createdAt
                ws.updatedAt = r.updatedAt
                if let orgId = r.organizationId {
                    ws.organization = orgById[orgId]
                }
                context.insert(ws)
            }
        }
    }

    private static func pullTasks(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncTask] = try await supabase.from("tasks").select().execute().value
        let descriptor = FetchDescriptor<WorkTask>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary( local.compactMap { t -> (UUID, WorkTask)? in
            guard let syncId = t.syncId else { return nil }
            return (syncId, t)
        }, uniquingKeysWith: { first, _ in first })

        let wsDescriptor = FetchDescriptor<Workspace>()
        let workspaces = try context.fetch(wsDescriptor)
        let wsById = Dictionary( workspaces.compactMap { w -> (UUID, Workspace)? in
            guard let syncId = w.syncId else { return nil }
            return (syncId, w)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                // Simple field update - skip Automerge for background sync
                if r.updatedAt > l.updatedAt {
                    l.title = r.title
                    l.taskDescription = r.description
                    l.status = r.status
                    l.priority = r.priority
                    l.completedAt = r.completedAt
                    l.updatedAt = r.updatedAt
                }
            } else {
                let task = WorkTask(title: r.title, description: r.description)
                task.syncId = r.id
                task.status = r.status
                task.priority = r.priority
                task.createdAt = r.createdAt
                task.updatedAt = r.updatedAt
                task.completedAt = r.completedAt
                if let wsId = r.workspaceId {
                    task.workspace = wsById[wsId]
                }
                context.insert(task)
            }
        }
    }

    private static func pullSkills(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncSkill] = try await supabase.from("skills").select().execute().value
        let descriptor = FetchDescriptor<Skill>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary( local.compactMap { s -> (UUID, Skill)? in
            guard let syncId = s.syncId else { return nil }
            return (syncId, s)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                if r.updatedAt > l.updatedAt {
                    l.name = r.name
                    l.content = r.content
                    l.updatedAt = r.updatedAt
                }
            } else {
                let skill = Skill(name: r.name, content: r.content)
                skill.syncId = r.id
                skill.createdAt = r.createdAt
                skill.updatedAt = r.updatedAt
                context.insert(skill)
            }
        }
    }

    private static func pullContexts(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncContext] = try await supabase.from("contexts").select().execute().value
        let descriptor = FetchDescriptor<Context>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary( local.compactMap { c -> (UUID, Context)? in
            guard let syncId = c.syncId else { return nil }
            return (syncId, c)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                if r.updatedAt > l.updatedAt {
                    l.name = r.name
                    l.content = r.content
                    l.updatedAt = r.updatedAt
                }
            } else {
                let ctx = Context(name: r.name, content: r.content)
                ctx.syncId = r.id
                ctx.createdAt = r.createdAt
                ctx.updatedAt = r.updatedAt
                context.insert(ctx)
            }
        }
    }

    private static func pullTerminals(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncTerminal] = try await supabase.from("terminals").select().execute().value
        let descriptor = FetchDescriptor<Terminal>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary( local.compactMap { t -> (UUID, Terminal)? in
            guard let syncId = t.syncId else { return nil }
            return (syncId, t)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                if r.updatedAt > l.updatedAt {
                    l.name = r.name
                    l.updatedAt = r.updatedAt
                }
            } else {
                let terminal = Terminal(name: r.name)
                terminal.syncId = r.id
                terminal.createdAt = r.createdAt
                terminal.updatedAt = r.updatedAt
                context.insert(terminal)
            }
        }
    }

    private static func pullHints(context: ModelContext, supabase: SupabaseClient) async throws {
        let remote: [SyncHint] = try await supabase.from("hints").select().execute().value
        let descriptor = FetchDescriptor<Hint>()
        let local = try context.fetch(descriptor)
        let localById = Dictionary( local.compactMap { h -> (UUID, Hint)? in
            guard let syncId = h.syncId else { return nil }
            return (syncId, h)
        }, uniquingKeysWith: { first, _ in first })

        let taskDescriptor = FetchDescriptor<WorkTask>()
        let tasks = try context.fetch(taskDescriptor)
        let taskById = Dictionary( tasks.compactMap { t -> (UUID, WorkTask)? in
            guard let syncId = t.syncId else { return nil }
            return (syncId, t)
        }, uniquingKeysWith: { first, _ in first })

        for r in remote {
            if let l = localById[r.id] {
                // Compare using createdAt since Hint doesn't have updatedAt
                if r.createdAt > l.createdAt {
                    l.title = r.title
                    l.hintDescription = r.description
                    l.status = r.status
                }
            } else {
                let hint = Hint(type: HintType(rawValue: r.type) ?? .exclusiveChoice, title: r.title, description: r.description)
                hint.syncId = r.id
                hint.status = r.status
                hint.createdAt = r.createdAt
                hint.answeredAt = r.answeredAt
                if let taskId = r.taskId {
                    hint.task = taskById[taskId]
                }
                context.insert(hint)
            }
        }
    }
}

// MARK: - Sync Service

@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private let supabase = SupabaseManager.shared.client
    private var realtimeChannels: [RealtimeChannelV2] = []
    private var realtimeChannel: RealtimeChannelV2? // Legacy reference for guard check

    var isSyncing = false
    var lastSyncDate: Date?
    var syncError: Error?

    /// Lock to prevent concurrent sync operations that could create duplicate records
    private let syncLock = NSLock()

    /// Set of workspace IDs that are currently being actively used (open in a window)
    /// Only tasks from these workspaces will be synced
    private(set) var activeWorkspaceIds: Set<UUID> = []

    private init() {
        print("[SyncService] Initializing SyncService")
    }

    enum SyncError: Error {
        case supabaseDisabled
    }

    private func requireSupabase() throws -> SupabaseClient {
        guard let supabase else { throw SyncError.supabaseDisabled }
        return supabase
    }

    /// Attempt to acquire sync lock. Returns true if acquired, false if already locked.
    /// Thread-safe - can be called from any thread/actor.
    nonisolated func tryAcquireSyncLock() -> Bool {
        return syncLock.try()
    }

    /// Release the sync lock
    /// Thread-safe - can be called from any thread/actor.
    nonisolated func releaseSyncLock() {
        syncLock.unlock()
    }

    #if os(macOS)
    /// Sync a workspace using its container (called by SyncScheduler)
    func performWorkspaceSyncWithContext(workspaceId: UUID) async {
        print("[SyncService] performWorkspaceSyncWithContext for: \(workspaceId)")
        do {
            let container = try WorkspaceContainerManager.shared.container(for: workspaceId)
            // Use mainContext to ensure we see changes from InboxService and other sources
            let context = container.mainContext
            print("[SyncService] Got container and context, calling performWorkspaceSync")
            await performWorkspaceSync(workspaceId: workspaceId, context: context)
        } catch {
            print("[SyncService] Failed to get container for workspace \(workspaceId): \(error)")
        }
    }
    #endif

    // MARK: - Platform-Aware Sync Dispatch

    /// Unified sync dispatch: uses workspace-scoped sync on macOS, global sync on iOS/visionOS.
    func performPlatformSync(globalContext: ModelContext?) async {
        switch PlatformServices.syncMode {
        case .workspaceScoped:
            #if os(macOS)
            print("[SyncService] Platform sync: workspace-scoped, active IDs: \(activeWorkspaceIds)")
            if activeWorkspaceIds.isEmpty {
                print("[SyncService] WARNING: No active workspaces registered!")
            }
            for workspaceId in activeWorkspaceIds {
                await performWorkspaceSyncWithContext(workspaceId: workspaceId)
            }
            #endif
        case .global:
            if let context = globalContext {
                await performFullSync(context: context)
            } else {
                print("[SyncService] No context available for global sync")
            }
        }
    }

    // MARK: - Active Workspace Management

    /// Register a workspace as active (e.g., when opening a workspace window)
    func registerActiveWorkspace(_ workspaceId: UUID) {
        activeWorkspaceIds.insert(workspaceId)
        print("[SyncService] Registered active workspace: \(workspaceId) (total: \(activeWorkspaceIds.count))")
    }

    /// Unregister a workspace (e.g., when closing a workspace window)
    func unregisterActiveWorkspace(_ workspaceId: UUID) {
        activeWorkspaceIds.remove(workspaceId)
        print("[SyncService] Unregistered workspace: \(workspaceId) (total: \(activeWorkspaceIds.count))")
    }

    /// Check if a workspace is currently active
    func isWorkspaceActive(_ workspaceId: UUID) -> Bool {
        activeWorkspaceIds.contains(workspaceId)
    }

    // MARK: - Background Sync (iOS)

    /// Perform a full sync in the background without blocking the UI.
    /// Creates its own ModelContext from the container and runs entirely off main thread.
    /// - Parameter container: The ModelContainer to use
    nonisolated func performFullSyncInBackground(container: ModelContainer) {
        Task.detached(priority: .utility) {
            await BackgroundSyncWorker.performSync(container: container, syncService: self)
        }
    }

    // MARK: - Full Sync

    /// Perform a workspace-scoped sync with Supabase.
    /// Only syncs data for the specified workspace.
    /// - Parameters:
    ///   - workspaceId: The workspace to sync
    ///   - context: The model context
    ///   - pullOnly: If true, only pull remote changes without pushing local changes.
    func performWorkspaceSync(workspaceId: UUID, context: ModelContext, pullOnly: Bool = false) async {
        guard supabase != nil else {
            print("[SyncService] Supabase disabled (missing config)")
            return
        }
        // Use lock to prevent concurrent sync operations that could create duplicate records
        guard tryAcquireSyncLock() else {
            print("[SyncService] Skipping workspace sync: another sync in progress")
            return
        }
        defer { releaseSyncLock() }

        let authService = AuthService.shared
        await authService.checkSession()

        guard authService.isAuthenticated else {
            print("[SyncService] Skipping sync: not authenticated")
            return
        }

        isSyncing = true
        syncError = nil

        do {
            // First, ensure the workspace has a syncId (push to Supabase if needed)
            try await ensureWorkspaceSynced(workspaceId: workspaceId, context: context)
            await Task.yield() // Let UI update

            // Sync only data for this workspace
            try await syncTasksForWorkspace(workspaceId: workspaceId, context: context)
            await Task.yield()
            try await syncSkillsForWorkspace(workspaceId: workspaceId, context: context)
            await Task.yield()
            try await syncContextsForWorkspace(workspaceId: workspaceId, context: context)
            await Task.yield()
            try await syncTerminalsForWorkspace(workspaceId: workspaceId, context: context)
            await Task.yield()
            try await syncHintsForWorkspace(workspaceId: workspaceId, context: context)
            await Task.yield()

            if !pullOnly {
                try await pushLocalTasksForWorkspace(workspaceId: workspaceId, context: context)
                await Task.yield()
                try await pushTaskUpdatesForWorkspace(workspaceId: workspaceId, context: context)
                await Task.yield()
                try await pushLocalSkillsForWorkspace(workspaceId: workspaceId, context: context)
                await Task.yield()
                try await pushLocalContextsForWorkspace(workspaceId: workspaceId, context: context)
                await Task.yield()
                try await pushLocalTerminalsForWorkspace(workspaceId: workspaceId, context: context)
                await Task.yield()
                try await pushLocalHintsForWorkspace(workspaceId: workspaceId, context: context)
            }

            lastSyncDate = Date()
            print("[SyncService] Workspace sync completed for: \(workspaceId)")
        } catch {
            syncError = error
            print("[SyncService] Workspace sync error: \(error)")
        }

        isSyncing = false
    }

    /// Ensure the workspace has a syncId, pushing to Supabase if needed
    private func ensureWorkspaceSynced(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == workspaceId || $0.syncId == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else {
            print("[SyncService] Workspace not found: \(workspaceId)")
            return
        }

        // If workspace already has syncId, we're good
        if workspace.syncId != nil {
            return
        }

        // Need to push workspace to Supabase first
        guard AuthService.shared.currentUser?.id != nil else {
            print("[SyncService] Cannot push workspace: not authenticated")
            return
        }

        // Get organization for the workspace
        let orgDescriptor = FetchDescriptor<Organization>()
        let organizations = try context.fetch(orgDescriptor)
        guard let userOrg = organizations.first, let orgSyncId = userOrg.syncId else {
            print("[SyncService] Cannot push workspace: no synced organization found")
            return
        }

        let workspaceOrgId = workspace.organization?.syncId ?? orgSyncId

        // Initialize automerge document for new workspace
        let doc = AutomergeStore.shared.document(for: workspace.id)
        try? doc.initializeWorkspace(workspace)
        let docBytes = AutomergeStore.shared.save(id: workspace.id)

        let syncWorkspace = SyncWorkspace(
            id: workspace.id,
            name: workspace.name,
            slug: workspace.slug,
            ownerId: nil,
            organizationId: workspaceOrgId,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            automergeDoc: docBytes.map { PostgresBytea($0) }
        )

        try await insertToSupabase(.workspaces, data: syncWorkspace)
        workspace.syncId = workspace.id
        if workspace.organization == nil {
            workspace.organization = userOrg
        }
        try context.save()
        print("[SyncService] Pushed new workspace during workspace sync: \(workspace.name)")
    }

    /// Perform a full sync with Supabase (syncs all active workspaces)
    /// - Parameters:
    ///   - context: The model context
    ///   - pullOnly: If true, only pull remote changes without pushing local changes.
    ///               Use this when responding to realtime notifications to avoid overwriting remote changes.
    func performFullSync(context: ModelContext, pullOnly: Bool = false) async {
        guard supabase != nil else {
            print("[SyncService] Supabase disabled (missing config)")
            return
        }
        // Use lock to prevent concurrent sync operations that could create duplicate records
        guard tryAcquireSyncLock() else {
            print("[SyncService] Skipping full sync: another sync in progress")
            return
        }
        defer { releaseSyncLock() }

        // Refresh auth session before sync
        let authService = AuthService.shared
        await authService.checkSession()

        print("[SyncService] Auth check - isAuthenticated: \(authService.isAuthenticated), currentUser: \(String(describing: authService.currentUser?.id))")
        guard authService.isAuthenticated else {
            print("[SyncService] Skipping sync: not authenticated")
            return
        }

        isSyncing = true
        syncError = nil

        do {
            // 1. Pull organizations first (needed for workspace relationships)
            try await syncOrganizations(context: context)
            await Task.yield() // Let UI update

            // 1b. Pull organization invitations (optional - table may not exist)
            do {
                try await syncOrganizationInvitations(context: context)
            } catch {
                print("[SyncService] Skipping organization invitations sync: \(error.localizedDescription)")
            }
            await Task.yield()

            // 2. PULL FIRST - Merge remote automerge docs before pushing
            // This ensures we don't overwrite remote changes with stale local state
            try await syncWorkspaces(context: context)
            await Task.yield()
            try await syncTasks(context: context)
            await Task.yield()
            try await syncSkills(context: context)
            await Task.yield()
            try await syncContexts(context: context)
            await Task.yield()
            try await syncTerminals(context: context)
            await Task.yield()
            try await syncHints(context: context)
            await Task.yield()

            // 3. THEN PUSH - Push merged state back to remote
            // Skip pushing if this is a pull-only sync (e.g., from realtime notification)
            if !pullOnly {
                try await pushLocalInvitations(context: context)
                await Task.yield()
                try await pushLocalWorkspaces(context: context)
                await Task.yield()
                try await pushLocalTasks(context: context)
                await Task.yield()
                try await pushTaskUpdates(context: context)
                await Task.yield()
                try await pushLocalSkills(context: context)
                await Task.yield()
                try await pushLocalContexts(context: context)
                await Task.yield()
                try await pushLocalTerminals(context: context)
                await Task.yield()
                try await pushLocalHints(context: context)
            }

            lastSyncDate = Date()
            print("[SyncService] Sync completed successfully (pullOnly: \(pullOnly))")
        } catch {
            syncError = error
            print("[SyncService] Sync error: \(error)")
        }

        isSyncing = false
    }

    // MARK: - Network Helpers (run on background)

    private func fetchFromSupabase<T: Decodable & Sendable>(_ table: SupabaseTable) async throws -> [T] {
        let supabase = try requireSupabase()
        return try await Task.detached { [supabase] in
            try await supabase
                .from(table.rawValue)
                .select()
                .execute()
                .value
        }.value
    }

    /// Fetch from Supabase with workspace_id filter
    private func fetchFromSupabaseForWorkspace<T: Decodable & Sendable>(_ table: SupabaseTable, workspaceId: UUID) async throws -> [T] {
        let supabase = try requireSupabase()
        return try await Task.detached { [supabase] in
            try await supabase
                .from(table.rawValue)
                .select()
                .eq("workspace_id", value: workspaceId)
                .execute()
                .value
        }.value
    }

    private func insertToSupabase<T: Encodable & Sendable>(_ table: SupabaseTable, data: T) async throws {
        let supabase = try requireSupabase()
        try await Task.detached { [supabase] in
            try await supabase
                .from(table.rawValue)
                .insert(data)
                .execute()
        }.value
    }

    private func updateInSupabase<T: Encodable & Sendable>(_ table: SupabaseTable, id: UUID, data: T) async throws {
        let supabase = try requireSupabase()
        try await Task.detached { [supabase] in
            try await supabase
                .from(table.rawValue)
                .update(data)
                .eq("id", value: id)
                .execute()
        }.value
    }

    private func deleteFromSupabase(_ table: SupabaseTable, id: UUID) async throws {
        let supabase = try requireSupabase()
        try await Task.detached { [supabase] in
            try await supabase
                .from(table.rawValue)
                .delete()
                .eq("id", value: id)
                .execute()
        }.value
    }

    // MARK: - Public Deletion Methods

    /// Delete a task from Supabase. Call this when user deletes a task locally.
    func deleteTask(syncId: UUID) async {
        do {
            try await deleteFromSupabase(.tasks, id: syncId)
            AutomergeStore.shared.remove(id: syncId)
            print("[SyncService] Deleted task from remote: \(syncId)")
        } catch {
            print("[SyncService] Failed to delete task from remote: \(error)")
        }
    }

    /// Delete a workspace from Supabase.
    func deleteWorkspace(syncId: UUID) async {
        do {
            try await deleteFromSupabase(.workspaces, id: syncId)
            AutomergeStore.shared.remove(id: syncId)
            print("[SyncService] Deleted workspace from remote: \(syncId)")
        } catch {
            print("[SyncService] Failed to delete workspace from remote: \(error)")
        }
    }

    /// Clean up remote tasks that don't exist locally.
    /// DEPRECATED: This function is dangerous — if local store is empty (fresh install,
    /// after sign-out, or data clear), it will DELETE ALL remote tasks.
    /// Disabled to prevent data loss. Individual task deletions are handled by deleteTask().
    func cleanupOrphanedRemoteTasks(context: ModelContext) async {
        print("[SyncService] cleanupOrphanedRemoteTasks is disabled to prevent data loss")
    }

    /// Performs a full sync. The orphaned task cleanup has been disabled to prevent data loss.
    func performCleanupSync(context: ModelContext) async {
        print("[SyncService] Starting sync (cleanup step disabled)...")
        await performFullSync(context: context)
    }

    // MARK: - Push Local Workspaces

    private func pushLocalWorkspaces(context: ModelContext) async throws {
        guard AuthService.shared.currentUser?.id != nil else {
            print("[SyncService] Cannot push workspaces: not authenticated")
            return
        }

        let orgDescriptor = FetchDescriptor<Organization>()
        let organizations = try context.fetch(orgDescriptor)

        guard let userOrg = organizations.first, let orgSyncId = userOrg.syncId else {
            print("[SyncService] Cannot push workspaces: no synced organization found.")
            return
        }

        let descriptor = FetchDescriptor<Workspace>()
        let localWorkspaces = try context.fetch(descriptor)

        for workspace in localWorkspaces {
            if workspace.syncId == nil {
                let workspaceOrgId = workspace.organization?.syncId ?? orgSyncId

                // Initialize automerge document for new workspace
                let doc = AutomergeStore.shared.document(for: workspace.id)
                try? doc.initializeWorkspace(workspace)
                let docBytes = AutomergeStore.shared.save(id: workspace.id)

                let syncWorkspace = SyncWorkspace(
                    id: workspace.id,
                    name: workspace.name,
                    slug: workspace.slug,
                    ownerId: nil,
                    organizationId: workspaceOrgId,
                    createdAt: workspace.createdAt,
                    updatedAt: workspace.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.workspaces, data: syncWorkspace)
                    workspace.syncId = workspace.id
                    if workspace.organization == nil {
                        workspace.organization = userOrg
                    }
                    print("[SyncService] Pushed new workspace: \(workspace.name)")
                } catch {
                    print("[SyncService] Failed to push workspace '\(workspace.name)': \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Push Local Tasks

    private func pushLocalTasks(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global task push (workspace-scoped sync mode)")
            return
        }
        print("[SyncService] Pushing local tasks...")
        guard let userId = AuthService.shared.currentUser?.id else {
            print("[SyncService] Cannot push tasks: not authenticated")
            return
        }

        let descriptor = FetchDescriptor<WorkTask>()
        let localTasks = try context.fetch(descriptor)
        print("[SyncService] Found \(localTasks.count) local tasks to check")

        for task in localTasks {
            if task.syncId == nil {
                guard let workspaceSyncId = task.workspace?.syncId else {
                    print("[SyncService] Skipping task '\(task.title)': workspace not synced yet")
                    continue
                }

                // Initialize automerge document for new task
                let doc = AutomergeStore.shared.document(for: task.id)
                do {
                    try doc.initializeTask(task)
                    print("[SyncService] Initialized automerge doc for task: \(task.title)")
                } catch {
                    print("[SyncService] Failed to initialize automerge doc for task '\(task.title)': \(error)")
                }
                let docBytes = AutomergeStore.shared.save(id: task.id)
                print("[SyncService] Automerge doc bytes for '\(task.title)': \(docBytes?.count ?? 0) bytes")

                let syncTask = SyncTask(
                    id: task.id,
                    workspaceId: workspaceSyncId,
                    title: task.title,
                    description: task.taskDescription,
                    status: task.status,
                    priority: task.priority,
                    createdById: userId,
                    createdAt: task.createdAt,
                    updatedAt: task.updatedAt,
                    completedAt: task.completedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.tasks, data: syncTask)
                    task.syncId = task.id
                    print("[SyncService] Pushed new task: \(task.title)")
                } catch {
                    print("[SyncService] Failed to push task '\(task.title)': \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Push Task Updates

    private func pushTaskUpdates(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global task updates push (workspace-scoped sync mode)")
            return
        }
        print("[SyncService] Pushing task updates...")

        let descriptor = FetchDescriptor<WorkTask>()
        let localTasks = try context.fetch(descriptor)
        let syncedTasks = localTasks.filter { $0.syncId != nil }
        print("[SyncService] Found \(syncedTasks.count) synced tasks to update")

        for task in syncedTasks {
            guard let syncId = task.syncId else { continue }

            // Get or create the automerge doc
            let doc = AutomergeStore.shared.document(for: syncId)

            // Sync current SwiftData state to the automerge doc before pushing
            // This ensures any local UI changes are captured in the CRDT
            do {
                try doc.updateTaskTitle(task.title)
                try doc.updateTaskDescription(task.taskDescription)
                try doc.updateTaskStatus(task.status)
                try doc.updateTaskPriority(task.priority)
                try doc.updateTaskCompletedAt(task.completedAt)
            } catch {
                print("[SyncService] Failed to update automerge doc for task '\(task.title)': \(error)")
            }

            // Get automerge doc bytes for this task
            let docBytes = AutomergeStore.shared.save(id: syncId)
            print("[SyncService] Task '\(task.title)' automerge doc: \(docBytes?.count ?? 0) bytes, status: \(task.status)")

            let updatePayload = SyncTaskUpdate(
                title: task.title,
                description: task.taskDescription,
                status: task.status,
                priority: task.priority,
                updatedAt: task.updatedAt,
                completedAt: task.completedAt,
                automergeDocData: docBytes
            )

            do {
                try await updateInSupabase(.tasks, id: syncId, data: updatePayload)
                print("[SyncService] Updated task: \(task.title) (priority: \(task.priority))")
            } catch {
                print("[SyncService] Failed to update task '\(task.title)': \(error)")
            }
        }
    }

    // MARK: - Push Local Skills

    private func pushLocalSkills(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global skills push (workspace-scoped sync mode)")
            return
        }
        let descriptor = FetchDescriptor<Skill>()
        let localSkills = try context.fetch(descriptor)

        for skill in localSkills {
            if skill.syncId == nil {
                guard let workspaceSyncId = skill.workspace?.syncId else {
                    continue
                }

                // Initialize automerge document for new skill
                let doc = AutomergeStore.shared.document(for: skill.id)
                try? doc.initializeSkill(skill)
                let docBytes = AutomergeStore.shared.save(id: skill.id)

                let syncSkill = SyncSkill(
                    id: skill.id,
                    workspaceId: workspaceSyncId,
                    name: skill.name,
                    content: skill.content,
                    createdAt: skill.createdAt,
                    updatedAt: skill.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.skills, data: syncSkill)
                    skill.syncId = skill.id
                    print("[SyncService] Pushed new skill: \(skill.name)")
                } catch {
                    print("[SyncService] Failed to push skill '\(skill.name)': \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Push Local Contexts

    private func pushLocalContexts(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global contexts push (workspace-scoped sync mode)")
            return
        }
        let descriptor = FetchDescriptor<Context>()
        let localContexts = try context.fetch(descriptor)

        for ctx in localContexts {
            if ctx.syncId == nil {
                guard let workspaceSyncId = ctx.workspace?.syncId else {
                    continue
                }

                // Initialize automerge document for new context
                let doc = AutomergeStore.shared.document(for: ctx.id)
                try? doc.initializeContext(ctx)
                let docBytes = AutomergeStore.shared.save(id: ctx.id)

                let syncContext = SyncContext(
                    id: ctx.id,
                    workspaceId: workspaceSyncId,
                    name: ctx.name,
                    content: ctx.content,
                    createdAt: ctx.createdAt,
                    updatedAt: ctx.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.contexts, data: syncContext)
                    ctx.syncId = ctx.id
                    print("[SyncService] Pushed new context: \(ctx.name)")
                } catch {
                    print("[SyncService] Failed to push context '\(ctx.name)': \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Push Local Hints

    private func pushLocalHints(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global hints push (workspace-scoped sync mode)")
            return
        }
        let descriptor = FetchDescriptor<Hint>()
        let localHints = try context.fetch(descriptor)

        for hint in localHints {
            if hint.syncId == nil {
                // Initialize automerge document for new hint
                let doc = AutomergeStore.shared.document(for: hint.id)
                try? doc.initializeHint(hint)
                let docBytes = AutomergeStore.shared.save(id: hint.id)

                let syncHint = SyncHint(
                    id: hint.id,
                    terminalId: hint.terminal?.syncId ?? hint.terminal?.id,
                    taskId: hint.task?.syncId ?? hint.task?.id,
                    type: hint.type,
                    title: hint.title,
                    description: hint.hintDescription,
                    options: hint.options?.map { SyncHintOption(label: $0.label, value: $0.value) },
                    response: nil,
                    status: hint.status,
                    createdAt: hint.createdAt,
                    answeredAt: hint.answeredAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.hints, data: syncHint)
                    hint.syncId = hint.id
                    print("[SyncService] Pushed new hint: \(hint.title)")
                } catch {
                    print("[SyncService] Failed to push hint '\(hint.title)': \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Push Local Terminals

    private func pushLocalTerminals(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global terminals push (workspace-scoped sync mode)")
            return
        }
        let descriptor = FetchDescriptor<Terminal>()
        let localTerminals = try context.fetch(descriptor)

        for terminal in localTerminals {
            if terminal.syncId == nil {
                // Initialize automerge document for new terminal
                let doc = AutomergeStore.shared.document(for: terminal.id)
                try? doc.initializeTerminal(terminal)
                let docBytes = AutomergeStore.shared.save(id: terminal.id)

                let syncTerminal = SyncTerminal(
                    id: terminal.id,
                    workspaceId: terminal.workspace?.syncId ?? terminal.workspace?.id,
                    taskId: terminal.task?.syncId ?? terminal.task?.id,
                    name: terminal.name,
                    status: terminal.status,
                    startedAt: terminal.startedAt,
                    endedAt: terminal.endedAt,
                    createdAt: terminal.createdAt,
                    updatedAt: terminal.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.terminals, data: syncTerminal)
                    terminal.syncId = terminal.id
                    print("[SyncService] Pushed new terminal: \(terminal.name ?? terminal.id.uuidString)")
                } catch {
                    print("[SyncService] Failed to push terminal: \(error)")
                }
            }
        }

        try context.save()
    }

    // MARK: - Organizations Sync

    private func syncOrganizations(context: ModelContext) async throws {
        print("[SyncService] Fetching organizations from Supabase...")

        // Debug session on background
        let supabase = try requireSupabase()
        await Task.detached { [supabase] in
            do {
                let session = try await supabase.auth.session
                print("[SyncService] Supabase session user: \(session.user.id)")
            } catch {
                print("[SyncService] Session error: \(error)")
            }
        }.value

        let remoteOrganizations: [SyncOrganization] = try await fetchFromSupabase(.organizations)
        print("[SyncService] Found \(remoteOrganizations.count) remote organizations")

        let descriptor = FetchDescriptor<Organization>()
        let localOrganizations = try context.fetch(descriptor)

        let localById = Dictionary( localOrganizations.compactMap { org -> (UUID, Organization)? in
            guard let syncId = org.syncId else { return nil }
            return (syncId, org)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteOrganizations {
            if let local = localById[remote.id] {
                // Use Automerge merge instead of timestamp comparison
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToOrganization(local)
                        local.updatedAt = Date()
                    } catch {
                        // Fallback to timestamp-based sync
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.slug = remote.slug
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else {
                    // No automerge doc - use timestamp-based sync
                    if remote.updatedAt > local.updatedAt {
                        local.name = remote.name
                        local.slug = remote.slug
                        local.updatedAt = remote.updatedAt
                    }
                }
            } else {
                let newOrg = Organization(name: remote.name, slug: remote.slug)
                newOrg.syncId = remote.id
                newOrg.createdAt = remote.createdAt
                newOrg.updatedAt = remote.updatedAt
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newOrg)
                print("[SyncService] Inserted new organization: \(remote.name)")
            }
        }

        try context.save()
    }

    // MARK: - Organization Invitations Sync

    private func syncOrganizationInvitations(context: ModelContext) async throws {
        print("[SyncService] Fetching organization invitations from Supabase...")
        let remoteInvitations: [SyncOrganizationInvitation] = try await fetchFromSupabase(.organizationInvitations)
        print("[SyncService] Found \(remoteInvitations.count) remote invitations")

        let descriptor = FetchDescriptor<OrganizationInvitation>()
        let localInvitations = try context.fetch(descriptor)

        let orgDescriptor = FetchDescriptor<Organization>()
        let organizations = try context.fetch(orgDescriptor)
        let orgBySyncId = Dictionary( organizations.compactMap { org -> (UUID, Organization)? in
            guard let syncId = org.syncId else { return nil }
            return (syncId, org)
        }, uniquingKeysWith: { first, _ in first })

        let localById = Dictionary( localInvitations.compactMap { inv -> (UUID, OrganizationInvitation)? in
            guard let syncId = inv.syncId else { return nil }
            return (syncId, inv)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteInvitations {
            if let local = localById[remote.id] {
                // Update existing invitation
                local.email = remote.email
                local.role = remote.role
                local.status = remote.status
                local.expiresAt = remote.expiresAt
            } else {
                // Create new invitation
                let newInvitation = OrganizationInvitation(
                    email: remote.email,
                    role: remote.role,
                    status: remote.status,
                    expiresAt: remote.expiresAt
                )
                newInvitation.syncId = remote.id
                newInvitation.createdAt = remote.createdAt
                if let orgId = remote.organizationId as UUID? {
                    newInvitation.organization = orgBySyncId[orgId]
                }
                context.insert(newInvitation)
                print("[SyncService] Inserted new invitation for: \(remote.email)")
            }
        }

        try context.save()
    }

    /// Push local invitations to Supabase
    private func pushLocalInvitations(context: ModelContext) async throws {
        let descriptor = FetchDescriptor<OrganizationInvitation>(
            predicate: #Predicate { $0.syncId == nil }
        )
        let unsyncedInvitations = try context.fetch(descriptor)

        for invitation in unsyncedInvitations {
            guard let orgSyncId = invitation.organization?.syncId else {
                print("[SyncService] Skipping invitation without org syncId: \(invitation.email)")
                continue
            }

            let syncInvitation = SyncOrganizationInvitation(
                id: invitation.id,
                organizationId: orgSyncId,
                email: invitation.email,
                role: invitation.role,
                invitedBy: nil, // TODO: Add invited_by support
                status: invitation.status,
                createdAt: invitation.createdAt,
                expiresAt: invitation.expiresAt
            )

            do {
                try await insertToSupabase(.organizationInvitations, data: syncInvitation)
                invitation.syncId = invitation.id
                print("[SyncService] Pushed new invitation: \(invitation.email)")
            } catch {
                print("[SyncService] Failed to push invitation: \(error)")
            }
        }

        try context.save()
    }

    // MARK: - Workspaces Sync

    private func syncWorkspaces(context: ModelContext) async throws {
        print("[SyncService] Fetching workspaces from Supabase...")
        let remoteWorkspaces: [SyncWorkspace] = try await fetchFromSupabase(.workspaces)
        print("[SyncService] Found \(remoteWorkspaces.count) remote workspaces")

        let descriptor = FetchDescriptor<Workspace>()
        let localWorkspaces = try context.fetch(descriptor)

        let orgDescriptor = FetchDescriptor<Organization>()
        let organizations = try context.fetch(orgDescriptor)
        let orgBySyncId = Dictionary( organizations.compactMap { org -> (UUID, Organization)? in
            guard let syncId = org.syncId else { return nil }
            return (syncId, org)
        }, uniquingKeysWith: { first, _ in first })

        // Index by syncId for already-linked workspaces
        let localBySyncId = Dictionary( localWorkspaces.compactMap { ws -> (UUID, Workspace)? in
            guard let syncId = ws.syncId else { return nil }
            return (syncId, ws)
        }, uniquingKeysWith: { first, _ in first })

        // Also index by slug for matching unsynced local workspaces
        let localBySlug = Dictionary(localWorkspaces.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })

        for remote in remoteWorkspaces {
            // First, try to find by syncId (already linked)
            if let local = localBySyncId[remote.id] {
                // Use Automerge merge instead of timestamp comparison
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToWorkspace(local)
                        local.updatedAt = Date()
                    } catch {
                        // Fallback to timestamp-based sync
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.slug = remote.slug
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else {
                    // No automerge doc - use timestamp-based sync
                    if remote.updatedAt > local.updatedAt {
                        local.name = remote.name
                        local.slug = remote.slug
                        local.updatedAt = remote.updatedAt
                    }
                }
                if local.organization == nil, let orgId = remote.organizationId {
                    local.organization = orgBySyncId[orgId]
                }
            }
            // Next, try to find by slug (not yet linked - link them now)
            else if let local = localBySlug[remote.slug], local.syncId == nil {
                print("[SyncService] Linking local workspace '\(local.slug)' to remote ID: \(remote.id)")
                local.syncId = remote.id
                local.name = remote.name
                local.updatedAt = remote.updatedAt
                if let orgId = remote.organizationId {
                    local.organization = orgBySyncId[orgId]
                }
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
            }
            // Not found locally - create new
            else {
                let newWorkspace = Workspace(name: remote.name, slug: remote.slug)
                newWorkspace.syncId = remote.id
                newWorkspace.createdAt = remote.createdAt
                newWorkspace.updatedAt = remote.updatedAt
                if let orgId = remote.organizationId {
                    newWorkspace.organization = orgBySyncId[orgId]
                }
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newWorkspace)
                print("[SyncService] Inserted new workspace '\(remote.name)'")
            }
        }

        try context.save()
    }

    // MARK: - Tasks Sync

    /// Field-level merge for tasks when automerge fails.
    /// Strategy:
    /// - If local is nil and remote has value → use remote (data is better than no data)
    /// - If local has value and remote is nil → keep local (don't delete data)
    /// - If both have values → use timestamp to decide (newer wins)
    private func applyFieldLevelMerge(local: WorkTask, remote: SyncTask) {
        let remoteNewer = remote.updatedAt > local.updatedAt

        // Title: always has value, use timestamp
        if remoteNewer {
            local.title = remote.title
        }

        // Description: prefer non-nil, then timestamp
        if local.taskDescription == nil && remote.description != nil {
            local.taskDescription = remote.description
            print("[SyncService]     Applied remote description (local was nil)")
        } else if local.taskDescription != nil && remote.description == nil {
            // Keep local (don't delete)
        } else if remoteNewer {
            local.taskDescription = remote.description
        }

        // Status: always has value, use timestamp
        if remoteNewer {
            local.status = remote.status
        }

        // Priority: always has value, use timestamp
        if remoteNewer {
            local.priority = remote.priority
        }

        // CompletedAt: prefer non-nil, then timestamp
        if local.completedAt == nil && remote.completedAt != nil {
            local.completedAt = remote.completedAt
        } else if local.completedAt != nil && remote.completedAt == nil {
            // Keep local (don't delete)
        } else if remoteNewer {
            local.completedAt = remote.completedAt
        }

        // Update timestamp to reflect merge
        local.updatedAt = max(local.updatedAt, remote.updatedAt)
    }

    /// Shared helper to process remote tasks and sync them with local tasks.
    /// Used by both `syncTasks` (iOS full sync) and `syncTasksForWorkspace` (workspace-scoped sync).
    /// Returns tasks that had corrupted automerge docs and need repair push.
    private func processRemoteTasks(
        remoteTasks: [SyncTask],
        localTasks: [WorkTask],
        workspace: Workspace?,
        workspaceBySyncId: [UUID: Workspace],
        context: ModelContext
    ) async throws -> [WorkTask] {
        var tasksNeedingRepair: [WorkTask] = []

        let localById = Dictionary( localTasks.compactMap { task -> (UUID, WorkTask)? in
            guard let syncId = task.syncId else { return nil }
            return (syncId, task)
        }, uniquingKeysWith: { first, _ in first })

        let remoteIds = Set(remoteTasks.map { $0.id })
        print("[SyncService] Processing \(remoteTasks.count) remote tasks...")

        // Step 1: Collect existing document bytes (quick, on main thread)
        var existingDocBytes: [UUID: Data] = [:]
        for remote in remoteTasks {
            if AutomergeStore.shared.hasDocument(for: remote.id),
               let bytes = AutomergeStore.shared.save(id: remote.id) {
                existingDocBytes[remote.id] = bytes
            }
        }

        // Step 2: Process Automerge documents in background (heavy work off main thread)
        let processedFields = await processAutomergeBytesInBackground(
            remoteTasks: remoteTasks,
            localSyncIds: Set(localById.keys),
            existingDocBytes: existingDocBytes
        )

        // Step 3: Apply results to SwiftData (on main thread, but fast since data is ready)
        for remote in remoteTasks {
            if let local = localById[remote.id] {
                // Existing task - apply processed fields or fallback to field-level merge
                if let processed = processedFields[remote.id], !processed.needsRepair {
                    // Apply pre-processed Automerge values
                    if let title = processed.title { local.title = title }
                    if let desc = processed.description { local.taskDescription = desc }
                    if let status = processed.status { local.status = status }
                    if let priority = processed.priority { local.priority = priority }
                    if processed.completedAt != nil { local.completedAt = processed.completedAt }

                    // Update timestamp if remote is newer
                    if remote.updatedAt > local.updatedAt {
                        local.updatedAt = remote.updatedAt
                    }

                    // Store the merged document in AutomergeStore
                    if !processed.documentBytes.isEmpty {
                        try? AutomergeStore.shared.load(id: remote.id, bytes: processed.documentBytes)
                    }
                } else {
                    // Fallback: field-level merge
                    applyFieldLevelMerge(local: local, remote: remote)

                    // Repair automerge doc
                    AutomergeStore.shared.remove(id: remote.id)
                    let repairedDoc = AutomergeStore.shared.document(for: remote.id)
                    try? repairedDoc.initializeTask(local)
                    tasksNeedingRepair.append(local)
                }

                // Link to workspace if needed
                if local.workspace == nil {
                    if let ws = workspace {
                        local.workspace = ws
                    } else if let wsId = remote.workspaceId {
                        local.workspace = workspaceBySyncId[wsId]
                    }
                }
            } else {
                // New remote task - create locally
                let newTask = WorkTask(title: remote.title, description: remote.description)
                newTask.syncId = remote.id
                newTask.status = remote.status
                newTask.priority = remote.priority
                newTask.createdAt = remote.createdAt
                newTask.updatedAt = remote.updatedAt
                newTask.completedAt = remote.completedAt

                // Apply processed Automerge values if available
                if let processed = processedFields[remote.id], !processed.needsRepair {
                    if let title = processed.title { newTask.title = title }
                    if let desc = processed.description { newTask.taskDescription = desc }
                    if let status = processed.status { newTask.status = status }
                    if let priority = processed.priority { newTask.priority = priority }
                    if processed.completedAt != nil { newTask.completedAt = processed.completedAt }

                    // Store the document
                    if !processed.documentBytes.isEmpty {
                        try? AutomergeStore.shared.load(id: remote.id, bytes: processed.documentBytes)
                    }
                }

                // Link to workspace
                if let ws = workspace {
                    newTask.workspace = ws
                } else if let wsId = remote.workspaceId {
                    newTask.workspace = workspaceBySyncId[wsId]
                }

                context.insert(newTask)
            }
        }

        // Handle tasks that exist locally but not in remote (deleted on another device)
        var deletedCount = 0
        for local in localTasks {
            if let syncId = local.syncId, !remoteIds.contains(syncId) {
                AutomergeStore.shared.remove(id: syncId)
                context.delete(local)
                deletedCount += 1
            }
        }
        if deletedCount > 0 {
            print("[SyncService] Removed \(deletedCount) locally deleted tasks")
        }

        return tasksNeedingRepair
    }

    private func syncTasks(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global task sync (workspace-scoped sync mode)")
            return
        }

        print("[SyncService] Fetching tasks from Supabase...")
        let remoteTasks: [SyncTask] = try await fetchFromSupabase(.tasks)
        print("[SyncService] Found \(remoteTasks.count) remote tasks")

        let descriptor = FetchDescriptor<WorkTask>()
        let localTasks = try context.fetch(descriptor)

        let workspaceDescriptor = FetchDescriptor<Workspace>()
        let workspaces = try context.fetch(workspaceDescriptor)
        let workspaceBySyncId = Dictionary( workspaces.compactMap { ws -> (UUID, Workspace)? in
            guard let syncId = ws.syncId else { return nil }
            return (syncId, ws)
        }, uniquingKeysWith: { first, _ in first })

        _ = try await processRemoteTasks(
            remoteTasks: remoteTasks,
            localTasks: localTasks,
            workspace: nil,
            workspaceBySyncId: workspaceBySyncId,
            context: context
        )

        try context.save()
    }

    // MARK: - Skills Sync

    private func syncSkills(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global skills sync (workspace-scoped sync mode)")
            return
        }
        let remoteSkills: [SyncSkill] = try await fetchFromSupabase(.skills)

        let descriptor = FetchDescriptor<Skill>()
        let localSkills = try context.fetch(descriptor)

        let localById = Dictionary( localSkills.compactMap { skill -> (UUID, Skill)? in
            guard let syncId = skill.syncId else { return nil }
            return (syncId, skill)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteSkills {
            if let local = localById[remote.id] {
                // Use Automerge merge instead of timestamp comparison
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToSkill(local)
                        local.updatedAt = Date()
                    } catch {
                        // Fallback to timestamp-based sync
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.content = remote.content
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else {
                    // No automerge doc - use timestamp-based sync
                    if remote.updatedAt > local.updatedAt {
                        local.name = remote.name
                        local.content = remote.content
                        local.updatedAt = remote.updatedAt
                    }
                }
            } else {
                let newSkill = Skill(name: remote.name, content: remote.content)
                newSkill.syncId = remote.id
                newSkill.createdAt = remote.createdAt
                newSkill.updatedAt = remote.updatedAt
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newSkill)
            }
        }

        try context.save()
    }

    // MARK: - Contexts Sync

    private func syncContexts(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global contexts sync (workspace-scoped sync mode)")
            return
        }
        let remoteContexts: [SyncContext] = try await fetchFromSupabase(.contexts)

        let descriptor = FetchDescriptor<Context>()
        let localContexts = try context.fetch(descriptor)

        let localById = Dictionary( localContexts.compactMap { ctx -> (UUID, Context)? in
            guard let syncId = ctx.syncId else { return nil }
            return (syncId, ctx)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteContexts {
            if let local = localById[remote.id] {
                // Use Automerge merge instead of timestamp comparison
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToContext(local)
                        local.updatedAt = Date()
                    } catch {
                        // Fallback to timestamp-based sync
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.content = remote.content
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else {
                    // No automerge doc - use timestamp-based sync
                    if remote.updatedAt > local.updatedAt {
                        local.name = remote.name
                        local.content = remote.content
                        local.updatedAt = remote.updatedAt
                    }
                }
            } else {
                let newContext = Context(name: remote.name, content: remote.content)
                newContext.syncId = remote.id
                newContext.createdAt = remote.createdAt
                newContext.updatedAt = remote.updatedAt
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newContext)
            }
        }

        try context.save()
    }

    // MARK: - Terminals Sync

    private func syncTerminals(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global terminals sync (workspace-scoped sync mode)")
            return
        }
        let remoteTerminals: [SyncTerminal] = try await fetchFromSupabase(.terminals)

        let descriptor = FetchDescriptor<Terminal>()
        let localTerminals = try context.fetch(descriptor)

        let localById = Dictionary( localTerminals.compactMap { terminal -> (UUID, Terminal)? in
            guard let syncId = terminal.syncId else { return nil }
            return (syncId, terminal)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteTerminals {
            if let local = localById[remote.id] {
                // Use Automerge merge instead of timestamp comparison
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToTerminal(local)
                        local.updatedAt = Date()
                    } catch {
                        // Fallback to timestamp-based sync
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.status = remote.status
                            local.startedAt = remote.startedAt
                            local.endedAt = remote.endedAt
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else {
                    // No automerge doc - use timestamp-based sync
                    if remote.updatedAt > local.updatedAt {
                        local.name = remote.name
                        local.status = remote.status
                        local.startedAt = remote.startedAt
                        local.endedAt = remote.endedAt
                        local.updatedAt = remote.updatedAt
                    }
                }
            } else {
                let newTerminal = Terminal(name: remote.name)
                newTerminal.syncId = remote.id
                newTerminal.status = remote.status
                newTerminal.startedAt = remote.startedAt
                newTerminal.endedAt = remote.endedAt
                newTerminal.createdAt = remote.createdAt
                newTerminal.updatedAt = remote.updatedAt
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newTerminal)
            }
        }

        try context.save()
    }

    // MARK: - Hints Sync

    private func syncHints(context: ModelContext) async throws {
        guard PlatformServices.syncMode == .global else {
            print("[SyncService] Skipping global hints sync (workspace-scoped sync mode)")
            return
        }
        let remoteHints: [SyncHint] = try await fetchFromSupabase(.hints)

        let descriptor = FetchDescriptor<Hint>()
        let localHints = try context.fetch(descriptor)

        let localById = Dictionary( localHints.compactMap { hint -> (UUID, Hint)? in
            guard let syncId = hint.syncId else { return nil }
            return (syncId, hint)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteHints {
            if let local = localById[remote.id] {
                // Use Automerge merge for existing hints
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToHint(local)
                    } catch {
                        // Fallback - update status and answeredAt
                        local.status = remote.status
                        local.answeredAt = remote.answeredAt
                    }
                } else {
                    // No automerge doc - just update status
                    local.status = remote.status
                    local.answeredAt = remote.answeredAt
                }
            } else {
                let newHint = Hint(
                    type: HintType(rawValue: remote.type) ?? .exclusiveChoice,
                    title: remote.title,
                    description: remote.description
                )
                newHint.syncId = remote.id
                newHint.status = remote.status
                newHint.createdAt = remote.createdAt
                newHint.answeredAt = remote.answeredAt
                if let options = remote.options {
                    newHint.options = options.map { HintOption(label: $0.label, value: $0.value) }
                }
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newHint)
            }
        }

        try context.save()
    }

    // MARK: - Real-time Subscriptions (using Postgres Changes with workspace filtering)

    /// Start realtime sync for a specific workspace
    /// Call this for each workspace window that opens
    func startRealtimeSync(context: ModelContext, workspaceId: UUID? = nil) async {
        // If no workspace specified, use first active workspace
        let targetWorkspaceId = workspaceId ?? activeWorkspaceIds.first

        guard let wsId = targetWorkspaceId else {
            print("[SyncService] Cannot start realtime: no active workspace")
            return
        }

        // Check if we already have a channel for this workspace
        let channelName = "workspace-\(wsId)"
        if realtimeChannels.contains(where: { $0.topic == channelName }) {
            print("[SyncService] Realtime already running for workspace: \(wsId)")
            return
        }

        print("[SyncService] Starting real-time sync for workspace: \(wsId)")

        // Create a channel for this workspace
        guard let supabase = SupabaseManager.shared.client else {
            print("[SyncService] Supabase disabled (missing config)")
            return
        }
        let channel = supabase.realtimeV2.channel(channelName)
        realtimeChannels.append(channel)
        if realtimeChannel == nil {
            realtimeChannel = channel
        }

        // Subscribe to postgres changes filtered by workspace_id
        // This ensures we only receive changes for OUR workspace
        let tasksChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "tasks",
            filter: "workspace_id=eq.\(wsId)"
        )

        let hintsChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "hints"
            // Hints are linked to tasks, so we filter by checking in the handler
        )

        let skillsChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "skills",
            filter: "workspace_id=eq.\(wsId)"
        )

        let contextsChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "contexts",
            filter: "workspace_id=eq.\(wsId)"
        )

        let terminalsChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "terminals",
            filter: "workspace_id=eq.\(wsId)"
        )

        // For workspaces table, filter by the workspace's own ID
        let workspacesChanges = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "workspaces",
            filter: "id=eq.\(wsId)"
        )

        print("[SyncService] Subscribing to Postgres changes for workspace \(wsId)...")
        await channel.subscribe()
        print("[SyncService] ✅ Realtime subscribed for workspace: \(wsId)")

        // Listen for tasks changes
        Task {
            for await change in tasksChanges {
                print("[SyncService] 🔔 Postgres Change: Tasks in workspace \(wsId) - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }

        // Listen for hints changes
        Task {
            for await change in hintsChanges {
                print("[SyncService] 🔔 Postgres Change: Hints - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }

        // Listen for skills changes
        Task {
            for await change in skillsChanges {
                print("[SyncService] 🔔 Postgres Change: Skills in workspace \(wsId) - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }

        // Listen for contexts changes
        Task {
            for await change in contextsChanges {
                print("[SyncService] 🔔 Postgres Change: Contexts in workspace \(wsId) - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }

        // Listen for terminals changes
        Task {
            for await change in terminalsChanges {
                print("[SyncService] 🔔 Postgres Change: Terminals in workspace \(wsId) - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }

        // Listen for workspaces changes
        Task {
            for await change in workspacesChanges {
                print("[SyncService] 🔔 Postgres Change: Workspace \(wsId) updated - \(change)")
                await handleRealtimeChange(context: context, workspaceId: wsId)
            }
        }
    }

    /// Handle realtime change by syncing the specific workspace
    private func handleRealtimeChange(context: ModelContext, workspaceId: UUID) async {
        print("[SyncService] Syncing workspace \(workspaceId) due to realtime change")
        await performWorkspaceSync(workspaceId: workspaceId, context: context, pullOnly: true)
    }

    func stopRealtimeSync() async {
        for channel in realtimeChannels {
            await channel.unsubscribe()
        }
        realtimeChannels = []
        realtimeChannel = nil
    }

    // MARK: - Workspace-Scoped Sync Methods

    /// Sync tasks for a specific workspace only
    /// On macOS: context is from workspace-specific container, query all tasks
    /// On iOS: context is shared, need to filter by workspace relationship
    private func syncTasksForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        // Get workspace from context (works for both iOS shared context and macOS workspace-specific context)
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else {
            print("[SyncService] Workspace not found locally: \(workspaceId)")
            return
        }

        // Use syncId (remote ID) for Supabase query, fall back to local ID if not synced yet
        let remoteWorkspaceId = workspace.syncId ?? workspaceId
        print("[SyncService] Fetching tasks for workspace: \(workspaceId) (remote ID: \(remoteWorkspaceId))")
        let remoteTasks: [SyncTask] = try await fetchFromSupabaseForWorkspace(.tasks, workspaceId: remoteWorkspaceId)
        print("[SyncService] Found \(remoteTasks.count) remote tasks for workspace")

        let localTasks = workspace.tasks

        _ = try await processRemoteTasks(
            remoteTasks: remoteTasks,
            localTasks: localTasks,
            workspace: workspace,
            workspaceBySyncId: [:],
            context: context
        )

        try context.save()
    }

    private func syncSkillsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }

        let remoteWorkspaceId = workspace.syncId ?? workspaceId
        let remoteSkills: [SyncSkill] = try await fetchFromSupabaseForWorkspace(.skills, workspaceId: remoteWorkspaceId)
        let localSkills = workspace.skills
        let localById = Dictionary( localSkills.compactMap { skill -> (UUID, Skill)? in
            guard let syncId = skill.syncId else { return nil }
            return (syncId, skill)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteSkills {
            if let local = localById[remote.id] {
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToSkill(local)
                        local.updatedAt = Date()
                    } catch {
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.content = remote.content
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else if remote.updatedAt > local.updatedAt {
                    local.name = remote.name
                    local.content = remote.content
                    local.updatedAt = remote.updatedAt
                }
            } else {
                let newSkill = Skill(name: remote.name, content: remote.content)
                newSkill.syncId = remote.id
                newSkill.createdAt = remote.createdAt
                newSkill.updatedAt = remote.updatedAt
                newSkill.workspace = workspace
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newSkill)
            }
        }

        try context.save()
    }

    private func syncContextsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }

        let remoteWorkspaceId = workspace.syncId ?? workspaceId
        let remoteContexts: [SyncContext] = try await fetchFromSupabaseForWorkspace(.contexts, workspaceId: remoteWorkspaceId)
        let localContexts = workspace.contexts
        let localById = Dictionary( localContexts.compactMap { ctx -> (UUID, Context)? in
            guard let syncId = ctx.syncId else { return nil }
            return (syncId, ctx)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteContexts {
            if let local = localById[remote.id] {
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToContext(local)
                        local.updatedAt = Date()
                    } catch {
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.content = remote.content
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else if remote.updatedAt > local.updatedAt {
                    local.name = remote.name
                    local.content = remote.content
                    local.updatedAt = remote.updatedAt
                }
            } else {
                let newContext = Context(name: remote.name, content: remote.content)
                newContext.syncId = remote.id
                newContext.createdAt = remote.createdAt
                newContext.updatedAt = remote.updatedAt
                newContext.workspace = workspace
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newContext)
            }
        }

        try context.save()
    }

    private func syncTerminalsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }

        let remoteWorkspaceId = workspace.syncId ?? workspaceId
        let remoteTerminals: [SyncTerminal] = try await fetchFromSupabaseForWorkspace(.terminals, workspaceId: remoteWorkspaceId)
        let localTerminals = workspace.terminals
        let localById = Dictionary( localTerminals.compactMap { terminal -> (UUID, Terminal)? in
            guard let syncId = terminal.syncId else { return nil }
            return (syncId, terminal)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteTerminals {
            if let local = localById[remote.id] {
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToTerminal(local)
                        local.updatedAt = Date()
                    } catch {
                        if remote.updatedAt > local.updatedAt {
                            local.name = remote.name
                            local.status = remote.status
                            local.startedAt = remote.startedAt
                            local.endedAt = remote.endedAt
                            local.updatedAt = remote.updatedAt
                        }
                    }
                } else if remote.updatedAt > local.updatedAt {
                    local.name = remote.name
                    local.status = remote.status
                    local.startedAt = remote.startedAt
                    local.endedAt = remote.endedAt
                    local.updatedAt = remote.updatedAt
                }
            } else {
                let newTerminal = Terminal(name: remote.name)
                newTerminal.syncId = remote.id
                newTerminal.status = remote.status
                newTerminal.startedAt = remote.startedAt
                newTerminal.endedAt = remote.endedAt
                newTerminal.createdAt = remote.createdAt
                newTerminal.updatedAt = remote.updatedAt
                newTerminal.workspace = workspace
                if let remoteBytes = remote.automergeDocData {
                    try? AutomergeStore.shared.load(id: remote.id, bytes: remoteBytes)
                }
                context.insert(newTerminal)
            }
        }

        try context.save()
    }

    private func syncHintsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        // Hints are linked to tasks, so we fetch hints for tasks in this workspace
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }
        let tasks = workspace.tasks
        let taskIds = tasks.compactMap { $0.syncId }

        guard !taskIds.isEmpty else { return }

        // Fetch all hints and filter by task_id
        let allHints: [SyncHint] = try await fetchFromSupabase(.hints)
        let remoteHints = allHints.filter { hint in
            guard let taskId = hint.taskId else { return false }
            return taskIds.contains(taskId)
        }

        let localHints = tasks.flatMap { $0.hints }
        let localById = Dictionary( localHints.compactMap { hint -> (UUID, Hint)? in
            guard let syncId = hint.syncId else { return nil }
            return (syncId, hint)
        }, uniquingKeysWith: { first, _ in first })

        for remote in remoteHints {
            if let local = localById[remote.id] {
                if let remoteBytes = remote.automergeDocData {
                    do {
                        try AutomergeStore.shared.merge(id: remote.id, remoteBytes: remoteBytes)
                        let doc = AutomergeStore.shared.document(for: remote.id)
                        try doc.applyToHint(local)
                    } catch {
                        local.status = remote.status
                        local.answeredAt = remote.answeredAt
                    }
                } else {
                    local.status = remote.status
                    local.answeredAt = remote.answeredAt
                }
            }
            // New hints are created through other flows, not pulled
        }

        try context.save()
    }

    // MARK: - Workspace-Scoped Push Methods

    private func pushLocalTasksForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        guard let userId = AuthService.shared.currentUser?.id else { return }

        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first,
              let workspaceSyncId = workspace.syncId else { return }
        let tasks = workspace.tasks

        for task in tasks {
            if task.syncId == nil {
                let doc = AutomergeStore.shared.document(for: task.id)
                try? doc.initializeTask(task)
                let docBytes = AutomergeStore.shared.save(id: task.id)

                let syncTask = SyncTask(
                    id: task.id,
                    workspaceId: workspaceSyncId,
                    title: task.title,
                    description: task.taskDescription,
                    status: task.status,
                    priority: task.priority,
                    createdById: userId,
                    createdAt: task.createdAt,
                    updatedAt: task.updatedAt,
                    completedAt: task.completedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.tasks, data: syncTask)
                    task.syncId = task.id
                    print("[SyncService] Pushed new task for workspace: \(task.title)")
                } catch {
                    print("[SyncService] Failed to push task: \(error)")
                }
            }
        }

        try context.save()
    }

    private func pushTaskUpdatesForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }
        let syncedTasks = workspace.tasks.filter { $0.syncId != nil }

        for task in syncedTasks {
            guard let syncId = task.syncId else { continue }

            let doc = AutomergeStore.shared.document(for: syncId)
            try? doc.updateTaskTitle(task.title)
            try? doc.updateTaskDescription(task.taskDescription)
            try? doc.updateTaskStatus(task.status)
            try? doc.updateTaskPriority(task.priority)
            try? doc.updateTaskCompletedAt(task.completedAt)

            let docBytes = AutomergeStore.shared.save(id: syncId)

            let updatePayload = SyncTaskUpdate(
                title: task.title,
                description: task.taskDescription,
                status: task.status,
                priority: task.priority,
                updatedAt: task.updatedAt,
                completedAt: task.completedAt,
                automergeDocData: docBytes
            )

            do {
                try await updateInSupabase(.tasks, id: syncId, data: updatePayload)
            } catch {
                print("[SyncService] Failed to update task: \(error)")
            }
        }
    }

    private func pushLocalSkillsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first,
              let workspaceSyncId = workspace.syncId else { return }
        let skills = workspace.skills

        for skill in skills {
            if skill.syncId == nil {
                let doc = AutomergeStore.shared.document(for: skill.id)
                try? doc.initializeSkill(skill)
                let docBytes = AutomergeStore.shared.save(id: skill.id)

                let syncSkill = SyncSkill(
                    id: skill.id,
                    workspaceId: workspaceSyncId,
                    name: skill.name,
                    content: skill.content,
                    createdAt: skill.createdAt,
                    updatedAt: skill.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.skills, data: syncSkill)
                    skill.syncId = skill.id
                } catch {
                    print("[SyncService] Failed to push skill: \(error)")
                }
            }
        }

        try context.save()
    }

    private func pushLocalContextsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first,
              let workspaceSyncId = workspace.syncId else { return }
        let contexts = workspace.contexts

        for ctx in contexts {
            if ctx.syncId == nil {
                let doc = AutomergeStore.shared.document(for: ctx.id)
                try? doc.initializeContext(ctx)
                let docBytes = AutomergeStore.shared.save(id: ctx.id)

                let syncContext = SyncContext(
                    id: ctx.id,
                    workspaceId: workspaceSyncId,
                    name: ctx.name,
                    content: ctx.content,
                    createdAt: ctx.createdAt,
                    updatedAt: ctx.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.contexts, data: syncContext)
                    ctx.syncId = ctx.id
                } catch {
                    print("[SyncService] Failed to push context: \(error)")
                }
            }
        }

        try context.save()
    }

    private func pushLocalTerminalsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else { return }
        let terminals = workspace.terminals
        let workspaceSyncId = workspace.syncId

        for terminal in terminals {
            if terminal.syncId == nil {
                let doc = AutomergeStore.shared.document(for: terminal.id)
                try? doc.initializeTerminal(terminal)
                let docBytes = AutomergeStore.shared.save(id: terminal.id)

                let syncTerminal = SyncTerminal(
                    id: terminal.id,
                    workspaceId: workspace.syncId,
                    taskId: terminal.task?.syncId,
                    name: terminal.name,
                    status: terminal.status,
                    startedAt: terminal.startedAt,
                    endedAt: terminal.endedAt,
                    createdAt: terminal.createdAt,
                    updatedAt: terminal.updatedAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.terminals, data: syncTerminal)
                    terminal.syncId = terminal.id
                } catch {
                    print("[SyncService] Failed to push terminal: \(error)")
                }
            }
        }

        try context.save()
    }

    private func pushLocalHintsForWorkspace(workspaceId: UUID, context: ModelContext) async throws {
        print("[SyncService] === PUSH HINTS DEBUG ===")
        print("[SyncService] Looking for workspace: \(workspaceId)")

        let wsDescriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.syncId == workspaceId || $0.id == workspaceId })
        guard let workspace = try context.fetch(wsDescriptor).first else {
            print("[SyncService] Workspace not found for ID: \(workspaceId)")
            return
        }
        print("[SyncService] Found workspace: \(workspace.name), tasks: \(workspace.tasks.count)")

        let hints = workspace.tasks.flatMap { $0.hints }
        print("[SyncService] Total hints to check: \(hints.count)")

        for hint in hints {
            print("[SyncService] Hint: \(hint.title), syncId: \(hint.syncId?.uuidString ?? "nil"), taskSyncId: \(hint.task?.syncId?.uuidString ?? "nil")")
            if hint.syncId == nil {
                let doc = AutomergeStore.shared.document(for: hint.id)
                try? doc.initializeHint(hint)
                let docBytes = AutomergeStore.shared.save(id: hint.id)

                let syncHint = SyncHint(
                    id: hint.id,
                    terminalId: hint.terminal?.syncId,
                    taskId: hint.task?.syncId,
                    type: hint.type,
                    title: hint.title,
                    description: hint.hintDescription,
                    options: hint.options?.map { SyncHintOption(label: $0.label, value: $0.value) },
                    response: nil,
                    status: hint.status,
                    createdAt: hint.createdAt,
                    answeredAt: hint.answeredAt,
                    automergeDoc: docBytes.map { PostgresBytea($0) }
                )

                do {
                    try await insertToSupabase(.hints, data: syncHint)
                    hint.syncId = hint.id
                } catch {
                    print("[SyncService] Failed to push hint: \(error)")
                }
            }
        }

        try context.save()
    }
}

// MARK: - Sync Scheduler

/// Debounced sync scheduler to avoid excessive sync calls during rapid edits
@MainActor
@Observable
final class SyncScheduler {
    static let shared = SyncScheduler()

    private var syncTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.5 // 500ms debounce

    /// Context for iOS syncs (set by the app on launch)
    var iosContext: ModelContext?

    private init() {}

    /// Schedule a sync with debouncing - rapid calls within 500ms are coalesced
    func scheduleSync() {
        // Cancel any pending sync
        syncTask?.cancel()

        // Schedule new sync after debounce interval
        syncTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))

            // Check if cancelled during sleep
            guard !Task.isCancelled else { return }

            await performSync()
        }
    }

    /// Force immediate sync without debouncing
    func syncNow() {
        syncTask?.cancel()
        syncTask = Task {
            await performSync()
        }
    }

    private func performSync() async {
        print("[SyncScheduler] Triggering sync...")
        let syncService = SyncService.shared

        guard !syncService.isSyncing else {
            print("[SyncScheduler] Sync already in progress, skipping")
            return
        }

        await syncService.performPlatformSync(globalContext: iosContext)
    }
}
