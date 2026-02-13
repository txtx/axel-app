import Foundation
import SwiftData
import UserNotifications

/// Service that connects to the axel server's SSE /inbox endpoint
/// and streams Claude Code hook events to the app.
///
/// ## Architecture
///
/// Each terminal in a workspace gets its own axel-cli event server on a unique port
/// (starting at 4318, incrementing per terminal). This service connects to each
/// terminal's SSE endpoint independently and merges all events into a single `events` array.
///
/// ## The Shared Hooks Problem
///
/// Claude Code hooks are configured in `.claude/settings.json` at the **workspace level**.
/// This file is shared by ALL Claude instances in the workspace. When axel creates a new
/// terminal, it writes hooks pointing to that terminal's server (port + pane_id), **overwriting**
/// the hooks from previous terminals.
///
/// This means ALL hook events (PermissionRequest, Stop, etc.) arrive at the **last terminal's**
/// server with the **last terminal's pane_id** — regardless of which Claude session triggered them.
///
/// ## OTEL-Based Correction
///
/// Unlike hooks, OTEL telemetry uses per-process environment variables
/// (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`) that include the correct pane_id in the URL path.
/// These are set at process start time and can't be overwritten by other terminals.
///
/// The `CostTracker` builds a reliable `sessionId → paneId` mapping from OTEL data.
/// We use `resolvedPaneId(for:)` to correct wrong pane_ids everywhere in the system.
///
/// ## Key Invariant
///
/// **Never use `event.paneId` directly for routing or per-terminal logic.**
/// Always use `resolvedPaneId(for:)` or `CostTracker.shared.paneId(forSessionId:)`.
/// The raw `event.paneId` is only reliable for the last terminal created.
@MainActor
@Observable
final class InboxService {
    static let shared = InboxService()

    /// Recent events (newest first)
    private(set) var events: [InboxEvent] = []

    /// Task metrics by Claude session ID (for OTEL metrics tracking)
    private(set) var taskMetrics: [String: TaskMetrics] = [:]

    /// Model context for persisting hints (set by the app on launch)
    var modelContext: ModelContext?

    /// Metrics snapshots by event ID (captured at completion events)
    private(set) var eventMetricsSnapshots: [UUID: MetricsSnapshot] = [:]

    /// Pending Stop events waiting for OTEL metrics (eventID -> sessionID)
    private var pendingStopEvents: [(eventId: UUID, sessionId: String, timestamp: Date)] = []

    /// File commits tracked per pane (for review-post-completion mode, from individual file_committed events)
    private(set) var committedFiles: [String: [FileCommit]] = [:]

    /// File commits attached to Stop events (from worktree_commits in the event payload).
    /// Keyed by event ID to avoid paneId mismatch issues.
    private(set) var eventCommits: [UUID: [FileCommit]] = [:]

    /// Versioning info extracted from the agent's transcript (attached to Stop events).
    /// Keyed by event ID. Contains (commitMessage, commitDescription).
    private(set) var eventVersioning: [UUID: (message: String, description: String)] = [:]

    /// Last snapshot values per session (for computing deltas)
    private var lastSnapshotValues: [String: MetricsSnapshot] = [:]

    /// Resolved event IDs (confirmed by user or auto-resolved)
    private(set) var resolvedEventIds: Set<UUID> = []

    /// Last Stop event ID per session (for auto-resolving)
    private var lastStopEventPerSession: [String: UUID] = [:]

    /// Last PermissionRequest event ID per session (for auto-resolving).
    /// **Keyed by claudeSessionId** (not paneId) to avoid cross-session interference
    /// from the shared .claude/settings.json hooks problem.
    private var lastPermissionRequestPerSession: [String: UUID] = [:]

    /// Token snapshot at time of permission request (sessionId -> total tokens at request time).
    /// Used to avoid auto-resolving based on stale OTEL data from before the request.
    /// **Keyed by claudeSessionId** (not paneId).
    private var permissionRequestTokenSnapshot: [String: Int] = [:]

    /// Timestamp when permission request arrived (sessionId -> timestamp).
    /// Used to add a time delay before auto-resolving.
    /// **Keyed by claudeSessionId** (not paneId).
    private var permissionRequestTimestamp: [String: Date] = [:]

    /// Minimum token increase required to auto-resolve a permission request
    private let autoResolveTokenThreshold = 100

    /// Minimum seconds before a permission request can be auto-resolved
    private let autoResolveDelaySeconds: TimeInterval = 15

    /// Connection state (true if at least one terminal is connected)
    var isConnected: Bool {
        !activeConnections.isEmpty
    }
    private(set) var connectionError: Error?

    /// Whether notifications are enabled
    var notificationsEnabled = true

    /// Maximum number of events to keep in memory
    private let maxEvents = 100

    /// Active SSE connections by terminal paneId
    private var activeConnections: [String: Task<Void?, Never>] = [:]

    /// Port mapping: paneId -> port
    private var panePortMapping: [String: Int] = [:]

    /// Port allocator - starts at 4318 and increments
    private var nextPort: Int = 4318

    private let decoder: JSONDecoder
    private let notificationCenter = UNUserNotificationCenter.current()

    /// Custom URLSession configured for SSE streaming
    private let sseSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5 // 5 second connection timeout
        config.timeoutIntervalForResource = .infinity // No resource timeout for streaming
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache"
        ]
        return URLSession(configuration: config)
    }()

    private init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        requestNotificationPermissions()
        registerNotificationCategories()
        loadPersistedStopEvents()
    }

    // MARK: - Notifications

    /// Request permission to show notifications
    private func requestNotificationPermissions() {
        Task {
            do {
                let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
                print("[InboxService] Notification permission granted: \(granted)")
            } catch {
                print("[InboxService] Failed to request notification permission: \(error)")
            }
        }
    }

    /// Register notification categories with action buttons
    private func registerNotificationCategories() {
        // Approve action
        let approveAction = UNNotificationAction(
            identifier: "APPROVE_ACTION",
            title: "Approve",
            options: []
        )

        // Reject action
        let rejectAction = UNNotificationAction(
            identifier: "REJECT_ACTION",
            title: "Reject",
            options: [.destructive]
        )

        // Permission request category with both actions
        let permissionCategory = UNNotificationCategory(
            identifier: "PERMISSION_REQUEST",
            actions: [approveAction, rejectAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // Generic inbox event category (no actions)
        let inboxCategory = UNNotificationCategory(
            identifier: "INBOX_EVENT",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([permissionCategory, inboxCategory])
    }

    /// Send a notification for a new inbox event
    private func sendNotification(for event: InboxEvent) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()

        // For permission requests, try to get the task title
        if event.event.hookEventName == "PermissionRequest" {
            let taskTitle = getTaskTitle(forPaneId: resolvedPaneId(for: event))
            content.title = taskTitle ?? "Permission Required"
            content.categoryIdentifier = "PERMISSION_REQUEST"
        } else {
            content.title = event.title
            content.categoryIdentifier = "INBOX_EVENT"
        }

        if let subtitle = event.subtitle {
            content.body = subtitle
        }
        content.sound = .default

        // Add event info to userInfo for handling taps and actions
        // Use resolved paneId (OTEL-corrected) so notification actions target the right terminal
        var userInfo: [String: String] = [
            "eventId": event.id.uuidString,
            "eventType": event.eventType,
            "paneId": resolvedPaneId(for: event)
        ]

        if let sessionId = event.event.claudeSessionId {
            userInfo["sessionId"] = sessionId
        }

        // Include workspaceId for deeplink navigation when notification is tapped
        if let workspaceId = getWorkspaceId(forPaneId: resolvedPaneId(for: event)) {
            userInfo["workspaceId"] = workspaceId.uuidString
        }

        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        Task {
            do {
                try await notificationCenter.add(request)
                print("[InboxService] Sent notification for: \(content.title)")
            } catch {
                print("[InboxService] Failed to send notification: \(error)")
            }
        }
    }

    /// Get the workspace ID for a given paneId by querying the Terminal → Workspace relationship
    private func getWorkspaceId(forPaneId paneId: String) -> UUID? {
        guard let context = modelContext else { return nil }

        do {
            let descriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == paneId }
            )
            if let terminal = try context.fetch(descriptor).first,
               let workspace = terminal.workspace {
                return workspace.id
            }
        } catch {
            print("[InboxService] Failed to fetch workspace ID: \(error)")
        }

        return nil
    }

    /// Get the task title for a given paneId by querying the Terminal
    private func getTaskTitle(forPaneId paneId: String) -> String? {
        guard let context = modelContext else { return nil }

        do {
            let descriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == paneId }
            )
            if let terminal = try context.fetch(descriptor).first,
               let task = terminal.task {
                return task.title
            }
        } catch {
            print("[InboxService] Failed to fetch task title: \(error)")
        }

        return nil
    }

    /// Check if terminal has a running task (for determining if completion screen should show)
    private func hasRunningTask(forPaneId paneId: String) -> Bool {
        guard let context = modelContext else { return false }

        do {
            let descriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == paneId }
            )
            if let terminal = try context.fetch(descriptor).first,
               let task = terminal.task {
                return task.status == TaskStatus.running.rawValue
            }
        } catch {
            print("[InboxService] Failed to check running task: \(error)")
        }

        return false
    }

    /// Handle notification action response (called from AppDelegate)
    func handleNotificationAction(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard let sessionId = userInfo["sessionId"] as? String,
              let paneId = userInfo["paneId"] as? String,
              let eventIdString = userInfo["eventId"] as? String,
              let eventId = UUID(uuidString: eventIdString) else {
            print("[InboxService] Missing required info for notification action")
            return
        }

        let allow = actionIdentifier == "APPROVE_ACTION"

        Task {
            do {
                try await sendPermissionResponse(sessionId: sessionId, allow: allow, paneId: paneId)
                await MainActor.run {
                    resolveEvent(eventId)
                }
                print("[InboxService] Handled notification action: \(allow ? "approve" : "reject")")
            } catch {
                print("[InboxService] Failed to handle notification action: \(error)")
            }
        }
    }

    /// Get or create metrics for a Claude session (linked to Terminal)
    func metrics(for claudeSessionId: String) -> TaskMetrics {
        if let existing = taskMetrics[claudeSessionId] {
            return existing
        }
        let metrics = TaskMetrics(claudeSessionId: claudeSessionId)
        taskMetrics[claudeSessionId] = metrics
        return metrics
    }

    // MARK: - Port Allocation

    /// Allocate a unique port for a new terminal
    func allocatePort() -> Int {
        let port = nextPort
        nextPort += 1
        return port
    }

    // MARK: - Scripting Support

    #if os(macOS)
    /// Get scriptable agents for AppleScript support
    func getScriptableAgents(for workspaceId: UUID) -> [ScriptableAgent] {
        TerminalSessionManager.shared.sessions(for: workspaceId).map { session in
            ScriptableAgent(
                paneId: session.paneId ?? "",
                displayName: session.taskTitle.isEmpty ? session.provider.displayName : session.taskTitle,
                provider: session.provider.rawValue,
                worktree: session.worktreeBranch,
                hasTask: session.hasTask,
                workspaceId: session.workspaceId
            )
        }
    }
    #endif

    // MARK: - Public API

    /// Connect to a terminal's SSE endpoint
    func connect(paneId: String, port: Int) {
        guard activeConnections[paneId] == nil else {
            print("[InboxService] Already connected to pane \(paneId.prefix(8))...")
            return
        }

        // Store the port mapping
        panePortMapping[paneId] = port

        let task = Task { [weak self] in
            await self?.streamEvents(paneId: paneId, port: port)
        }
        activeConnections[paneId] = task
        print("[InboxService] Connecting to terminal \(paneId.prefix(8))... on port \(port)")
    }

    /// Get the port for a paneId, defaults to 4318
    func port(for paneId: String?) -> Int {
        guard let paneId = paneId else { return 4318 }
        return panePortMapping[paneId] ?? 4318
    }

    /// Disconnect from a specific terminal
    func disconnect(paneId: String) {
        panePortMapping.removeValue(forKey: paneId)
        if let task = activeConnections.removeValue(forKey: paneId) {
            task.cancel()
            print("[InboxService] Disconnected from pane \(paneId.prefix(8))...")
        }
    }

    /// Disconnect from all terminals
    func disconnectAll() {
        for (paneId, task) in activeConnections {
            task.cancel()
            print("[InboxService] Disconnected from pane \(paneId.prefix(8))...")
        }
        activeConnections.removeAll()
        panePortMapping.removeAll()
    }

    /// Clear all events
    func clearEvents() {
        events.removeAll()
        eventMetricsSnapshots.removeAll()
        pendingStopEvents.removeAll()
        lastSnapshotValues.removeAll()
        resolvedEventIds.removeAll()
        lastStopEventPerSession.removeAll()
        lastPermissionRequestPerSession.removeAll()
        permissionRequestTokenSnapshot.removeAll()
        permissionRequestTimestamp.removeAll()
        saveStopEventsToDisk()
    }

    /// Mark an event as resolved (confirmed by user)
    func resolveEvent(_ eventId: UUID) {
        resolvedEventIds.insert(eventId)
        saveStopEventsToDisk()
    }

    /// Check if an event is resolved
    func isResolved(_ eventId: UUID) -> Bool {
        resolvedEventIds.contains(eventId)
    }

    #if os(macOS)
    /// Confirm task completion and trigger queue consumption for the next task.
    /// This should be called when the user validates a Stop event in the inbox.
    /// - Parameter paneId: The terminal pane ID where the task completed
    func confirmTaskCompletion(forPaneId paneId: String) {
        // Post notification to trigger queue consumption
        NotificationCenter.default.post(
            name: .taskCompletedOnTerminal,
            object: nil,
            userInfo: ["paneId": paneId]
        )
        print("[InboxService] Task completion confirmed for pane \(paneId.prefix(8))... - triggering queue consumption")
    }

    /// Complete an isolated worktree by squash-merging commits to the parent worktree.
    /// Calls the /worktree/complete endpoint on the terminal's server.
    ///
    /// - Parameter keepWorktree: If true, the worktree is reset to the parent's HEAD
    ///   instead of being removed. This keeps the directory alive so the same Claude
    ///   session can continue working for chained tasks.
    func completeWorktree(
        forPaneId paneId: String,
        commitMessage: String,
        commitDescription: String,
        keepWorktree: Bool = false
    ) async throws -> WorktreeCompleteResponse {
        guard let port = panePortMapping[paneId] else {
            throw InboxServiceError.connectionFailed
        }

        let url = URL(string: "http://localhost:\(port)/worktree/complete")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "commit_message": commitMessage,
            "commit_description": commitDescription,
            "keep_worktree": keepWorktree,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InboxServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[InboxService] Worktree complete failed: \(errorBody)")
            throw InboxServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(WorktreeCompleteResponse.self, from: data)

        // Clear committed files for this pane after successful merge
        committedFiles.removeValue(forKey: paneId)

        print("[InboxService] Worktree completed: \(result.commit_hash) (\(result.files_changed.count) files)")
        return result
    }
    #endif

    /// Resolve the correct paneId for an event.
    /// Hook events may arrive with the wrong paneId due to shared .claude/settings.json.
    /// Uses OTEL-derived session→pane mapping from CostTracker for correction.
    func resolvedPaneId(for event: InboxEvent) -> String {
        guard let sessionId = event.event.claudeSessionId else { return event.paneId }
        return CostTracker.shared.paneId(forSessionId: sessionId) ?? event.paneId
    }

    /// Set of pane IDs that have pending (unresolved) permission requests
    var blockedPaneIds: Set<String> {
        var blocked = Set<String>()
        for event in events {
            if event.event.hookEventName == "PermissionRequest" && !resolvedEventIds.contains(event.id) {
                blocked.insert(resolvedPaneId(for: event))
            }
        }
        return blocked
    }

    /// Count of unresolved events for a specific pane
    func unresolvedEventCount(forPaneId paneId: String) -> Int {
        events.filter { resolvedPaneId(for: $0) == paneId && !resolvedEventIds.contains($0.id) }.count
    }

    /// Count of unresolved permission requests for a specific pane
    func unresolvedPermissionRequestCount(forPaneId paneId: String) -> Int {
        events.filter {
            resolvedPaneId(for: $0) == paneId &&
            $0.event.hookEventName == "PermissionRequest" &&
            !resolvedEventIds.contains($0.id)
        }.count
    }

    /// Clear all events for a specific pane (resolve them and remove from list)
    func clearEventsForPane(_ paneId: String) {
        // Mark all events for this pane as resolved (using resolved paneId comparison)
        for event in events where resolvedPaneId(for: event) == paneId {
            resolvedEventIds.insert(event.id)
        }
        // Remove events for this pane from the list
        events.removeAll { resolvedPaneId(for: $0) == paneId }
        // Clean up related tracking state (keys are now sessionId-based)
        lastStopEventPerSession = lastStopEventPerSession.filter { sessionId, _ in
            CostTracker.shared.paneId(forSessionId: sessionId) != paneId
        }
        lastPermissionRequestPerSession = lastPermissionRequestPerSession.filter { sessionId, _ in
            CostTracker.shared.paneId(forSessionId: sessionId) != paneId
        }
        // Clean up token snapshots/timestamps for sessions mapped to this pane
        for (sessionId, _) in permissionRequestTokenSnapshot {
            if CostTracker.shared.paneId(forSessionId: sessionId) == paneId {
                permissionRequestTokenSnapshot.removeValue(forKey: sessionId)
                permissionRequestTimestamp.removeValue(forKey: sessionId)
            }
        }
        saveStopEventsToDisk()
        print("[InboxService] Cleared all events for pane \(paneId.prefix(8))...")
    }

    /// Legacy connect() for backwards compatibility - does nothing now
    /// Connections are established per-terminal via connect(paneId:port:)
    func connect() {
        // No-op - connections are now per-terminal
        print("[InboxService] connect() called - connections are now per-terminal")
    }

    /// Legacy reconnect() - does nothing now
    func reconnect() {
        // No-op - connections are now per-terminal
        print("[InboxService] reconnect() called - connections are now per-terminal")
    }

    /// Legacy disconnect() - disconnects all
    func disconnect() {
        disconnectAll()
    }

    // MARK: - SSE Streaming

    /// Connect to a terminal's SSE `/inbox` endpoint and stream events.
    ///
    /// Reads the byte stream line-by-line, accumulating SSE `data:` fields until
    /// a double-newline delimiter signals a complete event. Auto-reconnects with
    /// a 5-second backoff on disconnection.
    private func streamEvents(paneId: String, port: Int) async {
        let inboxURL = URL(string: "http://localhost:\(port)/inbox")!
        print("[InboxService] Connecting to \(inboxURL)")

        var request = URLRequest(url: inboxURL)
        request.timeoutInterval = .infinity

        do {
            let (bytes, response) = try await sseSession.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw InboxServiceError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw InboxServiceError.httpError(statusCode: httpResponse.statusCode)
            }

            connectionError = nil
            print("[InboxService] Connected to port \(port) successfully")

            var buffer = ""

            for try await byte in bytes {
                guard !Task.isCancelled else { break }

                let char = Character(UnicodeScalar(byte))
                buffer.append(char)

                // SSE events are separated by double newlines
                if buffer.hasSuffix("\n\n") {
                    processSSEBuffer(&buffer)
                }
            }

            print("[InboxService] Stream for port \(port) ended")
        } catch is CancellationError {
            print("[InboxService] Stream for port \(port) cancelled")
        } catch {
            print("[InboxService] Connection error on port \(port): \(error)")
            connectionError = error
        }

        // Auto-reconnect after a delay if not cancelled
        if !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                print("[InboxService] Attempting to reconnect to port \(port)...")
                await streamEvents(paneId: paneId, port: port)
            }
        }
    }

    private func processSSEBuffer(_ buffer: inout String) {
        let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
        buffer = ""

        var eventData: String?

        for line in lines {
            let lineStr = String(line)

            if lineStr.hasPrefix("data:") {
                let data = String(lineStr.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if eventData == nil {
                    eventData = data
                } else {
                    eventData! += "\n" + data
                }
            } else if lineStr.hasPrefix("event:") {
                // Event type field (we use the JSON data instead)
            } else if lineStr.hasPrefix("id:") {
                // Event ID field
            } else if lineStr.hasPrefix("retry:") {
                // Retry interval field
            }
            // Empty line or comment (starting with :)
        }

        if let data = eventData, !data.isEmpty {
            parseAndAddEvent(data)
        }
    }

    /// Parse a raw JSON string from SSE and add it to the events array.
    ///
    /// ## Event Types
    /// - `metrics_update`: Parsed OTEL data from the CLI. Updates token counts and costs.
    /// - `unknown_hook` (with `hook_event_name`): Claude Code hook events.
    ///   The Rust server can't parse `hook_event_name` from Claude's JSON so it labels
    ///   the event type as `"unknown_hook"`, but the raw payload (with `hook_event_name`
    ///   intact) is forwarded to us. We parse it as `InboxEvent` successfully.
    ///
    /// ## PermissionRequest Handling
    /// - Keyed by `claudeSessionId` to avoid cross-session interference
    /// - Auto-resolves previous permission request from the same session
    /// - Snapshots token count + timestamp for delayed auto-resolve via OTEL activity
    ///
    /// ## Stop Event Handling
    /// - Auto-resolves previous Stop and all pending permissions for the session
    /// - Only shows completion screen if the terminal has a running task
    /// - Queues for OTEL metrics snapshot (metrics arrive ~10s after Stop)
    private func parseAndAddEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            print("[InboxService] Failed to convert string to data")
            return
        }

        // First try to parse as a generic JSON to check event type
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["event_type"] as? String else {
            print("[InboxService] Failed to parse event type")
            return
        }

        // Handle parsed metrics updates from CLI
        if eventType == "metrics_update" {
            let paneId = json["pane_id"] as? String
            handleMetricsUpdate(json, paneId: paneId)
            return
        }

        // Handle file_committed events (from review-post-completion mode)
        if eventType == "file_committed" {
            if let paneId = json["pane_id"] as? String,
               let eventData = json["event"] as? [String: Any] {
                let commit = FileCommit(
                    commitHash: eventData["commit_hash"] as? String ?? "",
                    filePath: eventData["file_path"] as? String ?? "",
                    message: eventData["message"] as? String ?? "",
                    toolName: eventData["tool_name"] as? String ?? "",
                    diff: eventData["diff"] as? String ?? "",
                    timestamp: Date()
                )
                // Store under both raw paneId and all known resolved paneIds for this server.
                // The Stop event may resolve to a different paneId due to OTEL session mapping.
                var storedPaneIds = Set([paneId])
                // Also store under paneIds that map to this server's connection
                for (connPaneId, _) in activeConnections where connPaneId == paneId {
                    storedPaneIds.insert(connPaneId)
                }
                for id in storedPaneIds {
                    var paneCommits = committedFiles[id] ?? []
                    paneCommits.append(commit)
                    committedFiles[id] = paneCommits
                }
                print("[InboxService] File committed: \(commit.displayName) (\(commit.commitHash)) on pane \(paneId.prefix(8))")
            }
            return
        }

        // Parse as InboxEvent
        do {
            let event = try decoder.decode(InboxEvent.self, from: data)

            // NOTE: Do NOT register session mapping from hook events.
            // .claude/settings.json hooks are workspace-wide: the last terminal
            // created overwrites the hooks for ALL Claude instances in the workspace.
            // This means hook events arrive with the wrong paneId (the last terminal's),
            // corrupting the sessionId→paneId mapping and causing metrics to bleed
            // across terminals ("all terminals lighting up").
            //
            // Session mapping is correctly handled by OTEL events instead, which use
            // per-process env vars (OTEL_EXPORTER_OTLP_METRICS_ENDPOINT) with the
            // correct pane_id in the URL path.
            //
            // The CLI now remaps hook events to the correct pane_id using
            // OTEL-derived session→pane mappings (see routes.rs handle_hook_event).

            // Add to front of array (newest first)
            events.insert(event, at: 0)

            // Trim old events
            if events.count > maxEvents {
                events.removeLast(events.count - maxEvents)
            }

            // Track permission requests for step tracking and auto-resolve previous ones
            if event.event.hookEventName == "PermissionRequest" {
                // Use claudeSessionId as the tracking key (not paneId) because
                // .claude/settings.json hooks are workspace-wide: all events
                // arrive with the last terminal's paneId, so using paneId would
                // cause different sessions' permission requests to auto-resolve each other.
                let sessionKey = event.event.claudeSessionId ?? event.paneId
                let resolvedPaneId = CostTracker.shared.paneId(forSessionId: sessionKey) ?? event.paneId

                // Auto-resolve previous permission request from this session
                if let previousEventId = lastPermissionRequestPerSession[sessionKey] {
                    resolvedEventIds.insert(previousEventId)
                }
                lastPermissionRequestPerSession[sessionKey] = event.id

                // Use claudeSessionId for metrics if available, otherwise paneId
                let metricsId = event.event.claudeSessionId ?? event.paneId
                let metrics = self.metrics(for: metricsId)

                // Snapshot current token count and timestamp for auto-resolve logic
                permissionRequestTokenSnapshot[sessionKey] = metrics.inputTokens + metrics.outputTokens
                permissionRequestTimestamp[sessionKey] = Date()

                metrics.recordPermissionRequest(
                    toolName: event.event.toolName ?? "Unknown",
                    filePath: event.event.toolInput?["file_path"]?.value as? String
                )

                // Update CostTracker with permission request (use resolved paneId)
                CostTracker.shared.recordPermissionRequest(
                    forPaneId: resolvedPaneId,
                    toolName: event.event.toolName,
                    filePath: event.event.toolInput?["file_path"]?.value as? String
                )

                // Persist as Hint for Supabase sync
                persistPermissionRequestAsHint(event: event, paneId: resolvedPaneId)
            }

            // Queue Stop events to wait for OTEL metrics (which arrive ~10s later)
            if let hookName = event.event.hookEventName,
               hookName == "Stop",
               let sessionId = event.event.claudeSessionId {
                // Auto-resolve previous Stop event from this session
                if let previousEventId = lastStopEventPerSession[sessionId] {
                    resolvedEventIds.insert(previousEventId)
                }
                lastStopEventPerSession[sessionId] = event.id

                // Resolve the correct paneId via OTEL mapping (hooks may send wrong paneId)
                let resolvedPaneId = CostTracker.shared.paneId(forSessionId: sessionId) ?? event.paneId

                // Auto-resolve all pending permission requests for this session
                for existingEvent in events {
                    if existingEvent.event.hookEventName == "PermissionRequest",
                       existingEvent.event.claudeSessionId == sessionId,
                       !resolvedEventIds.contains(existingEvent.id) {
                        resolvedEventIds.insert(existingEvent.id)
                    }
                }
                // Use sessionId as key (matches the key used in PermissionRequest tracking above)
                lastPermissionRequestPerSession.removeValue(forKey: sessionId)
                permissionRequestTokenSnapshot.removeValue(forKey: sessionId)
                permissionRequestTimestamp.removeValue(forKey: sessionId)

                // Finalize task in CostTracker (use resolved paneId)
                CostTracker.shared.finalizeTask(forPaneId: resolvedPaneId)

                // NOTE: We do NOT post .taskCompletedOnTerminal here.
                // Queue consumption is triggered when the user validates the Stop event
                // in the inbox via confirmTaskCompletion(forPaneId:).

                pendingStopEvents.append((eventId: event.id, sessionId: sessionId, timestamp: Date()))

                // Parse worktree_commits if present (attached by CLI for review-post-completion)
                if let commitsArray = json["worktree_commits"] as? [[String: Any]] {
                    let commits = commitsArray.compactMap { commitData -> FileCommit? in
                        guard let hash = commitData["commit_hash"] as? String,
                              let filePath = commitData["file_path"] as? String,
                              let message = commitData["message"] as? String else { return nil }
                        return FileCommit(
                            commitHash: hash,
                            filePath: filePath,
                            message: message,
                            toolName: commitData["tool_name"] as? String ?? "",
                            diff: commitData["diff"] as? String ?? "",
                            timestamp: Date()
                        )
                    }
                    print("[InboxService] Parsed \(commits.count) worktree commits from Stop event")
                    if !commits.isEmpty {
                        eventCommits[event.id] = commits
                    }
                }

                // Parse versioning info if present (extracted from agent's transcript by CLI)
                if let versioningMessage = json["versioning_message"] as? String, !versioningMessage.isEmpty {
                    let versioningDescription = json["versioning_description"] as? String ?? ""
                    eventVersioning[event.id] = (message: versioningMessage, description: versioningDescription)
                    print("[InboxService] Parsed versioning: \(versioningMessage)")
                }
            }

            // Only send OS notifications for permission requests and task completions
            if event.event.hookEventName == "PermissionRequest" || event.event.hookEventName == "Stop" {
                sendNotification(for: event)
            }

            // Persist unresolved Stop events to disk so they survive app restart
            if event.event.hookEventName == "Stop" {
                saveStopEventsToDisk()
            }

            print("[InboxService] Received event: \(event.title)")
        } catch {
            print("[InboxService] Failed to decode event: \(error)")
            print("[InboxService] JSON: \(jsonString.prefix(200))...")
        }
    }

    // MARK: - Metrics Update Handling

    /// Handle a `metrics_update` event from the CLI.
    ///
    /// The CLI receives raw OTEL protobuf from Claude Code's built-in telemetry,
    /// parses it into a flat JSON structure, and sends it as an SSE event.
    /// Unlike hook events, the paneId here is **correct** because the CLI extracts it
    /// from the OTEL endpoint URL path (set via per-process env var).
    ///
    /// This method also registers the session→pane mapping in CostTracker,
    /// which is the source of truth for correcting hook event paneIds.
    ///
    /// ## Auto-Resolve Logic
    /// After receiving metrics, checks if any pending permission requests should be
    /// auto-resolved. A request is auto-resolved when:
    /// 1. At least `autoResolveDelaySeconds` (15s) have passed since the request
    /// 2. At least `autoResolveTokenThreshold` (100) new tokens have been generated
    /// This indicates Claude has continued working (user approved via CLI/elsewhere).
    private func handleMetricsUpdate(_ json: [String: Any], paneId: String?) {
        guard let eventData = json["event"] as? [String: Any] else {
            print("[InboxService] metrics_update: missing event payload")
            return
        }

        let sessionId = eventData["session_id"] as? String
        let provider = eventData["provider"] as? String ?? "claude"
        let inputTokens = eventData["input_tokens"] as? Int ?? 0
        let outputTokens = eventData["output_tokens"] as? Int ?? 0
        let cacheReadTokens = eventData["cache_read_tokens"] as? Int ?? 0
        let cacheCreationTokens = eventData["cache_creation_tokens"] as? Int ?? 0
        let costUSD = eventData["cost_usd"] as? Double ?? 0
        let linesAdded = eventData["lines_added"] as? Int ?? 0
        let linesRemoved = eventData["lines_removed"] as? Int ?? 0
        let activeTimeSeconds = eventData["active_time_seconds"] as? Double ?? 0

        // Register session→pane mapping
        if let paneId = paneId, let sid = sessionId {
            CostTracker.shared.registerSession(paneId: paneId, sessionId: sid)
        }

        // Use sessionId if available, otherwise paneId
        let metricsId = sessionId ?? paneId ?? "unknown"
        let metrics = self.metrics(for: metricsId)

        if provider == "codex" {
            // Codex sends per-response token counts (not cumulative) — accumulate
            metrics.accumulateFromLog(inputTokens: inputTokens, outputTokens: outputTokens)
            if costUSD > 0 {
                metrics.accumulateFromLog(costUSD: costUSD)
            }
        } else {
            // Claude sends cumulative values — assign directly
            if inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 || cacheCreationTokens > 0 {
                metrics.updateFromOTEL(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheReadTokens: cacheReadTokens,
                    cacheCreationTokens: cacheCreationTokens
                )
            }
            if costUSD > 0 {
                metrics.updateFromOTEL(costUSD: costUSD)
            }
            if linesAdded > 0 || linesRemoved > 0 {
                metrics.updateFromOTEL(linesAdded: linesAdded, linesRemoved: linesRemoved)
            }
            if activeTimeSeconds > 0 {
                metrics.updateFromOTEL(activeTimeSeconds: activeTimeSeconds)
            }
        }

        // Pass (possibly accumulated) cumulative values to CostTracker
        CostTracker.shared.recordMetrics(
            forSession: metricsId,
            inputTokens: metrics.inputTokens,
            outputTokens: metrics.outputTokens,
            cacheReadTokens: metrics.cacheReadTokens,
            cacheCreationTokens: metrics.cacheCreationTokens,
            costUSD: metrics.costUSD
        )

        // Auto-resolve pending permission requests when significant token activity after delay
        // Use metricsId (sessionId) as the key to match PermissionRequest tracking
        let sessionKey = metricsId
        if let pendingEventId = lastPermissionRequestPerSession[sessionKey],
           !resolvedEventIds.contains(pendingEventId) {
            let currentTokens = metrics.inputTokens + metrics.outputTokens
            let snapshotTokens = permissionRequestTokenSnapshot[sessionKey] ?? 0
            let requestTime = permissionRequestTimestamp[sessionKey] ?? .distantPast
            let timeSinceRequest = Date().timeIntervalSince(requestTime)

            let hasEnoughTime = timeSinceRequest >= autoResolveDelaySeconds
            let hasEnoughTokens = currentTokens >= snapshotTokens + autoResolveTokenThreshold

            if hasEnoughTime && hasEnoughTokens {
                resolvedEventIds.insert(pendingEventId)
                lastPermissionRequestPerSession.removeValue(forKey: sessionKey)
                permissionRequestTokenSnapshot.removeValue(forKey: sessionKey)
                permissionRequestTimestamp.removeValue(forKey: sessionKey)
                print("[InboxService] Auto-resolved permission request for session \(sessionKey.prefix(8))... due to token activity")
            }
        }

        // Process any pending Stop event snapshots
        processPendingSnapshots()
    }

    /// Create snapshots for pending Stop events using delta values
    private func processPendingSnapshots() {
        guard !pendingStopEvents.isEmpty else { return }

        for pending in pendingStopEvents {
            guard let metrics = taskMetrics[pending.sessionId] else { continue }

            let lastValues = lastSnapshotValues[pending.sessionId]
            let deltaSnapshot = MetricsSnapshot(
                from: metrics,
                subtractingPrevious: lastValues
            )
            eventMetricsSnapshots[pending.eventId] = deltaSnapshot
            lastSnapshotValues[pending.sessionId] = MetricsSnapshot(from: metrics)
        }

        pendingStopEvents.removeAll()

        // Re-save now that metrics snapshots are available
        saveStopEventsToDisk()
    }

    // MARK: - Outbox (Sending Responses)

    /// Response type for outbox
    enum OutboxResponseType: String, Codable {
        case permissionResponse = "permission_response"
        case questionResponse = "question_response"
    }

    /// Send a permission response to the axel-cli server's `/outbox` endpoint.
    ///
    /// The server receives the JSON payload, looks up the correct tmux pane from
    /// the session→pane OTEL mapping, and injects the response text via `tmux send-keys`.
    ///
    /// **Important**: Pass the OTEL-corrected paneId (via `resolvedPaneId(for:)` or
    /// `CostTracker.shared.paneId(forSessionId:)`), not the raw `event.paneId`.
    /// The server also performs its own correction using the same OTEL mapping.
    ///
    /// - Parameters:
    ///   - sessionId: The Claude session ID (unique per Claude process)
    ///   - option: The selected permission option (contains responseText to type into terminal)
    ///   - paneId: The terminal pane ID for routing (should be OTEL-corrected)
    func sendPermissionResponse(sessionId: String, option: PermissionOption, paneId: String? = nil) async throws {
        let serverPort = port(for: paneId)
        let outboxURL = URL(string: "http://localhost:\(serverPort)/outbox")!

        var body: [String: Any] = [
            "session_id": sessionId,
            "response_type": OutboxResponseType.permissionResponse.rawValue,
            "response_text": option.responseText
        ]

        if let paneId = paneId {
            body["pane_id"] = paneId
        }

        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InboxServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw InboxServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[InboxService] Sent permission response: '\(option.label)' (\(option.responseText)) for session \(sessionId)")

        // Mark corresponding hints as answered
        markHintsAnsweredForSession(sessionId: sessionId, response: option.label)
    }

    /// Convenience method for simple allow/deny (used by notifications)
    /// For notifications, we can only offer simple Yes/No, so this creates synthetic options
    func sendPermissionResponse(sessionId: String, allow: Bool, paneId: String? = nil) async throws {
        // Create a simple option for allow/deny
        // Option 1 = Yes, Option 2 (or 3 if there are suggestions) = No
        // For simplicity from notifications, we use "1" for yes and "n" shortcut for no
        let option = PermissionOption(
            id: allow ? 1 : 99,  // 99 is a placeholder, we use responseText override
            label: allow ? "Yes" : "No",
            shortLabel: allow ? "Yes" : "No",
            isDestructive: !allow,
            suggestion: nil
        )

        let serverPort = port(for: paneId)
        let outboxURL = URL(string: "http://localhost:\(serverPort)/outbox")!

        var body: [String: Any] = [
            "session_id": sessionId,
            "response_type": OutboxResponseType.permissionResponse.rawValue,
            // Use "y" or "n" shortcuts which Claude Code accepts
            "response_text": allow ? "y" : "n"
        ]

        if let paneId = paneId {
            body["pane_id"] = paneId
        }

        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InboxServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw InboxServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[InboxService] Sent permission response: '\(option.label)' for session \(sessionId)")
        markHintsAnsweredForSession(sessionId: sessionId, response: option.label)
    }

    /// Send a text response (for questions/hints)
    func sendTextResponse(sessionId: String, text: String, paneId: String? = nil) async throws {
        let serverPort = port(for: paneId)
        let outboxURL = URL(string: "http://localhost:\(serverPort)/outbox")!

        var body: [String: Any] = [
            "session_id": sessionId,
            "response_type": OutboxResponseType.questionResponse.rawValue,
            "response_text": text
        ]

        if let paneId = paneId {
            body["pane_id"] = paneId
        }

        var request = URLRequest(url: outboxURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InboxServiceError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw InboxServiceError.httpError(statusCode: httpResponse.statusCode)
        }

        print("[InboxService] Sent text response for session \(sessionId)")
    }
}

// MARK: - Hint Persistence

extension InboxService {
    /// Mark all pending hints for a pane as answered
    private func markHintsAnsweredForSession(sessionId: String, response: String) {
        guard let context = modelContext else {
            return
        }

        do {
            // Find pending hints linked to terminals with this pane ID
            let terminalDescriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == sessionId }
            )
            guard let terminal = try context.fetch(terminalDescriptor).first else {
                return
            }

            // Find pending hints for this terminal by fetching all pending hints
            // and filtering by terminal (since #Predicate has issues with optional relationships)
            let pendingStatus = HintStatus.pending.rawValue
            let hintDescriptor = FetchDescriptor<Hint>(
                predicate: #Predicate { $0.status == pendingStatus }
            )
            let allPendingHints = try context.fetch(hintDescriptor)
            let hints = allPendingHints.filter { $0.terminal?.id == terminal.id }

            for hint in hints {
                hint.markAnswered()
                // Store the response
                hint.responseData = try? JSONEncoder().encode(["response": response])
            }

            try context.save()

            // Trigger sync
            Task {
                await SyncScheduler.shared.scheduleSync()
            }
        } catch {
            // Error marking hints - handled silently
        }
    }

    /// Create a Hint from a PermissionRequest event and persist it to SwiftData
    private func persistPermissionRequestAsHint(event: InboxEvent, paneId: String) {
        guard let context = modelContext else {
            return
        }

        // Build title from tool info
        let toolName = event.event.toolName ?? "Unknown"
        var title = "Permission: \(toolName)"

        if let input = event.event.toolInput,
           let filePath = input["file_path"]?.value as? String {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            title = "\(toolName): \(fileName)"
        } else if toolName == "Bash",
                  let input = event.event.toolInput,
                  let command = input["command"]?.value as? String {
            let truncated = String(command.prefix(40))
            title = "Bash: \(truncated)\(command.count > 40 ? "..." : "")"
        }

        // Build description
        var description = "Permission request from Claude Code"
        if let cwd = event.event.cwd {
            description += " in \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }

        // Create the hint
        let hint = Hint(type: .exclusiveChoice, title: title, description: description)

        // Set options for allow/deny
        hint.options = [
            HintOption(label: "Allow", value: "allow"),
            HintOption(label: "Deny", value: "deny")
        ]

        // Try to find the Terminal and Task linked to this pane
        var linkedToTask = false
        do {
            // First try: find terminal by paneId
            let terminalDescriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == paneId }
            )
            if let terminal = try context.fetch(terminalDescriptor).first {
                hint.terminal = terminal

                // Link to task if terminal has one
                if let task = terminal.task {
                    hint.task = task
                    linkedToTask = true
                }
            }

            // Fallback: if not linked to task, try to find workspace by cwd and link to running task
            if !linkedToTask, let cwd = event.event.cwd {
                // Find workspace that matches this cwd
                let workspaceDescriptor = FetchDescriptor<Workspace>()
                let workspaces = try context.fetch(workspaceDescriptor)

                // Find workspace whose path is a prefix of cwd (or exact match)
                if let workspace = workspaces.first(where: { ws in
                    guard let wsPath = ws.path else { return false }
                    return cwd.hasPrefix(wsPath) || wsPath.hasPrefix(cwd)
                }) {
                    // Find a running task in this workspace, or the most recent task
                    let runningStatus = TaskStatus.running.rawValue
                    let runningTask = workspace.tasks.first { $0.status == runningStatus }
                    let fallbackTask = workspace.tasks.sorted { $0.createdAt > $1.createdAt }.first

                    if let task = runningTask ?? fallbackTask {
                        hint.task = task
                        linkedToTask = true
                    }
                }
            }
        } catch {
            // Failed to link hint to task - it will be persisted without a task link
        }

        // Insert and save
        context.insert(hint)
        do {
            try context.save()

            // Trigger sync if available
            Task {
                await SyncScheduler.shared.scheduleSync()
            }
        } catch {
            // Hint persistence failed - user will need to handle this manually
        }
    }
}

// MARK: - Stop Event Persistence

/// Bundled data for a persisted Stop event
private struct PersistedStopEvent: Codable {
    let event: InboxEvent
    let metricsSnapshot: MetricsSnapshot?
    let commits: [FileCommit]?
    let versioningMessage: String?
    let versioningDescription: String?
}

extension InboxService {
    /// File URL for persisted stop events
    private static var stopEventsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Axel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_stop_events.json")
    }

    /// Load persisted Stop events from disk on startup
    func loadPersistedStopEvents() {
        let fileURL = Self.stopEventsFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode([PersistedStopEvent].self, from: data)

            for item in persisted {
                // Skip if already present (shouldn't happen, but be safe)
                guard !events.contains(where: { $0.id == item.event.id }) else { continue }

                events.append(item.event)

                if let snapshot = item.metricsSnapshot {
                    eventMetricsSnapshots[item.event.id] = snapshot
                }
                if let commits = item.commits, !commits.isEmpty {
                    eventCommits[item.event.id] = commits
                }
                if let msg = item.versioningMessage, !msg.isEmpty {
                    eventVersioning[item.event.id] = (
                        message: msg,
                        description: item.versioningDescription ?? ""
                    )
                }
            }

            // Sort newest first (events loaded from disk may be older)
            events.sort { $0.timestamp > $1.timestamp }

            print("[InboxService] Loaded \(persisted.count) persisted Stop events from disk")
        } catch {
            print("[InboxService] Failed to load persisted Stop events: \(error)")
        }
    }

    /// Persist all unresolved Stop events to disk
    func saveStopEventsToDisk() {
        let unresolvedStops = events.filter { event in
            event.event.hookEventName == "Stop" && !resolvedEventIds.contains(event.id)
        }

        let persisted = unresolvedStops.map { event in
            PersistedStopEvent(
                event: event,
                metricsSnapshot: eventMetricsSnapshots[event.id],
                commits: eventCommits[event.id],
                versioningMessage: eventVersioning[event.id]?.message,
                versioningDescription: eventVersioning[event.id]?.description
            )
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persisted)
            try data.write(to: Self.stopEventsFileURL, options: .atomic)
            print("[InboxService] Persisted \(persisted.count) Stop events to disk")
        } catch {
            print("[InboxService] Failed to persist Stop events: \(error)")
        }
    }
}

// MARK: - Errors

enum InboxServiceError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .connectionFailed:
            return "Failed to connect to server"
        }
    }
}

/// A file commit tracked during review-post-completion mode
struct FileCommit: Identifiable, Codable {
    let id = UUID()
    let commitHash: String
    let filePath: String
    let message: String
    let toolName: String
    let diff: String
    let timestamp: Date

    /// Short display name (file basename)
    var displayName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

/// Response from /worktree/complete endpoint
struct WorktreeCompleteResponse: Codable {
    let commit_hash: String
    let files_changed: [String]
    let insertions: Int
    let deletions: Int
}
