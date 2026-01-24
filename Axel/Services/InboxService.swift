import Foundation
import SwiftData
import UserNotifications

/// Service that connects to the axel server's SSE /inbox endpoint
/// and streams Claude Code hook events to the app
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

    /// Last snapshot values per session (for computing deltas)
    private var lastSnapshotValues: [String: MetricsSnapshot] = [:]

    /// Resolved event IDs (confirmed by user or auto-resolved)
    private(set) var resolvedEventIds: Set<UUID> = []

    /// Last Stop event ID per session (for auto-resolving)
    private var lastStopEventPerSession: [String: UUID] = [:]

    /// Last PermissionRequest event ID per session (for auto-resolving)
    private var lastPermissionRequestPerSession: [String: UUID] = [:]

    /// Connection state
    private(set) var isConnected = false
    private(set) var connectionError: Error?

    /// Whether notifications are enabled
    var notificationsEnabled = true

    /// Maximum number of events to keep in memory
    private let maxEvents = 100

    /// The base URL for the axel server
    var serverURL: URL = URL(string: "http://localhost:4318")!

    private var streamTask: Task<Void, Never>?
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

    /// Send a notification for a new inbox event
    private func sendNotification(for event: InboxEvent) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle {
            content.body = subtitle
        }
        content.sound = .default
        content.categoryIdentifier = "INBOX_EVENT"

        // Add event info to userInfo for handling taps
        content.userInfo = [
            "eventId": event.id.uuidString,
            "eventType": event.eventType
        ]

        let request = UNNotificationRequest(
            identifier: event.id.uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        Task {
            do {
                try await notificationCenter.add(request)
                print("[InboxService] Sent notification for: \(event.title)")
            } catch {
                print("[InboxService] Failed to send notification: \(error)")
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

    // MARK: - Public API

    /// Connect to the SSE inbox endpoint and start receiving events
    func connect() {
        guard streamTask == nil else {
            print("[InboxService] Already connected or connecting")
            return
        }

        connectionError = nil

        streamTask = Task { [weak self] in
            await self?.streamEvents()
        }
    }

    /// Disconnect from the SSE endpoint
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        isConnected = false
        print("[InboxService] Disconnected")
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
    }

    /// Mark an event as resolved (confirmed by user)
    func resolveEvent(_ eventId: UUID) {
        resolvedEventIds.insert(eventId)
    }

    /// Check if an event is resolved
    func isResolved(_ eventId: UUID) -> Bool {
        resolvedEventIds.contains(eventId)
    }

    /// Set of pane IDs that have pending (unresolved) permission requests
    var blockedPaneIds: Set<String> {
        var blocked = Set<String>()
        for event in events {
            if event.event.hookEventName == "PermissionRequest" && !resolvedEventIds.contains(event.id) {
                blocked.insert(event.paneId)
            }
        }
        return blocked
    }

    /// Reconnect to the server
    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - SSE Streaming

    private func streamEvents() async {
        let inboxURL = serverURL.appendingPathComponent("inbox")
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

            isConnected = true
            connectionError = nil
            print("[InboxService] Connected successfully")

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

            print("[InboxService] Stream ended")
        } catch is CancellationError {
            print("[InboxService] Stream cancelled")
        } catch {
            print("[InboxService] Connection error: \(error)")
            connectionError = error
        }

        isConnected = false

        // Auto-reconnect after a delay if not cancelled
        if !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                print("[InboxService] Attempting to reconnect...")
                await streamEvents()
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

        // Handle OTEL metrics separately
        if eventType == "otel_metrics" {
            parseOTELMetrics(json)
            return
        }

        // Parse as InboxEvent
        do {
            let event = try decoder.decode(InboxEvent.self, from: data)

            // Add to front of array (newest first)
            events.insert(event, at: 0)

            // Trim old events
            if events.count > maxEvents {
                events.removeLast(events.count - maxEvents)
            }

            // Track permission requests for step tracking and auto-resolve previous ones
            if event.event.hookEventName == "PermissionRequest" {
                let paneId = event.paneId

                // Auto-resolve previous permission request from this pane
                if let previousEventId = lastPermissionRequestPerSession[paneId] {
                    resolvedEventIds.insert(previousEventId)
                }
                lastPermissionRequestPerSession[paneId] = event.id

                // Use claudeSessionId for metrics if available, otherwise paneId
                let metricsId = event.event.claudeSessionId ?? paneId
                let metrics = self.metrics(for: metricsId)
                metrics.recordPermissionRequest(
                    toolName: event.event.toolName ?? "Unknown",
                    filePath: event.event.toolInput?["file_path"]?.value as? String
                )

                // Persist as Hint for Supabase sync (use paneId to find terminal)
                persistPermissionRequestAsHint(event: event, paneId: paneId)
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

                // Auto-resolve all pending permission requests for this session
                for existingEvent in events {
                    if existingEvent.event.hookEventName == "PermissionRequest",
                       existingEvent.event.claudeSessionId == sessionId,
                       !resolvedEventIds.contains(existingEvent.id) {
                        resolvedEventIds.insert(existingEvent.id)
                    }
                }
                lastPermissionRequestPerSession.removeValue(forKey: sessionId)

                pendingStopEvents.append((eventId: event.id, sessionId: sessionId, timestamp: Date()))
            }

            // Send OS notification only for inbox items (permission requests)
            if event.event.hookEventName == "PermissionRequest" {
                sendNotification(for: event)
            }

            print("[InboxService] Received event: \(event.title)")
        } catch {
            print("[InboxService] Failed to decode event: \(error)")
            print("[InboxService] JSON: \(jsonString.prefix(200))...")
        }
    }

    // MARK: - OTEL Metrics Parsing

    private func parseOTELMetrics(_ json: [String: Any]) {
        guard let eventData = json["event"] as? [String: Any],
              let resourceMetrics = eventData["resourceMetrics"] as? [[String: Any]] else {
            return
        }

        for resourceMetric in resourceMetrics {
            guard let scopeMetrics = resourceMetric["scopeMetrics"] as? [[String: Any]] else {
                continue
            }

            for scopeMetric in scopeMetrics {
                guard let metrics = scopeMetric["metrics"] as? [[String: Any]] else {
                    continue
                }

                for metric in metrics {
                    parseMetric(metric)
                }
            }
        }

        // Process any pending Stop events now that we have fresh metrics
        processPendingSnapshots()
    }

    /// Create snapshots for pending Stop events using delta values
    private func processPendingSnapshots() {
        guard !pendingStopEvents.isEmpty else { return }

        // Process all pending events
        for pending in pendingStopEvents {
            guard let metrics = taskMetrics[pending.sessionId] else { continue }

            // Get the last snapshot values for this session (or zeros if first task)
            let lastValues = lastSnapshotValues[pending.sessionId]

            // Create delta snapshot
            let deltaSnapshot = MetricsSnapshot(
                from: metrics,
                subtractingPrevious: lastValues
            )

            eventMetricsSnapshots[pending.eventId] = deltaSnapshot

            // Update last snapshot values for next delta calculation
            lastSnapshotValues[pending.sessionId] = MetricsSnapshot(from: metrics)

            print("[InboxService] Created snapshot for event \(pending.eventId): \(deltaSnapshot.formattedCost)")
        }

        pendingStopEvents.removeAll()
    }

    private func parseMetric(_ metric: [String: Any]) {
        guard let name = metric["name"] as? String,
              let sum = metric["sum"] as? [String: Any],
              let dataPoints = sum["dataPoints"] as? [[String: Any]] else {
            return
        }

        for dataPoint in dataPoints {
            guard let value = dataPoint["asDouble"] as? Double,
                  let attributes = dataPoint["attributes"] as? [[String: Any]] else {
                continue
            }

            // Extract session ID and type from attributes
            var sessionId: String?
            var type: String?

            for attr in attributes {
                guard let key = attr["key"] as? String,
                      let valueDict = attr["value"] as? [String: Any],
                      let stringValue = valueDict["stringValue"] as? String else {
                    continue
                }

                if key == "session.id" {
                    sessionId = stringValue
                } else if key == "type" {
                    type = stringValue
                }
            }

            guard let sid = sessionId else { continue }
            let metrics = self.metrics(for: sid)

            switch name {
            case "claude_code.token.usage":
                switch type {
                case "input":
                    metrics.updateFromOTEL(inputTokens: Int(value))
                case "output":
                    metrics.updateFromOTEL(outputTokens: Int(value))
                case "cacheRead":
                    metrics.updateFromOTEL(cacheReadTokens: Int(value))
                case "cacheCreation":
                    metrics.updateFromOTEL(cacheCreationTokens: Int(value))
                default:
                    break
                }

            case "claude_code.cost.usage":
                metrics.updateFromOTEL(costUSD: value)

            case "claude_code.lines_of_code.count":
                switch type {
                case "added":
                    metrics.updateFromOTEL(linesAdded: Int(value))
                case "removed":
                    metrics.updateFromOTEL(linesRemoved: Int(value))
                default:
                    break
                }

            case "claude_code.active_time.total":
                metrics.updateFromOTEL(activeTimeSeconds: value)

            default:
                break
            }
        }
    }

    // MARK: - Outbox (Sending Responses)

    /// Response type for outbox
    enum OutboxResponseType: String, Codable {
        case permissionResponse = "permission_response"
        case questionResponse = "question_response"
    }

    /// Send a permission response to the axel server
    func sendPermissionResponse(sessionId: String, allow: Bool, paneId: String? = nil) async throws {
        let outboxURL = serverURL.appendingPathComponent("outbox")

        var body: [String: Any] = [
            "session_id": sessionId,
            "response_type": OutboxResponseType.permissionResponse.rawValue,
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

        print("[InboxService] Sent permission response: \(allow ? "allow" : "deny") for session \(sessionId)")

        // Mark corresponding hints as answered
        markHintsAnsweredForSession(sessionId: sessionId, response: allow ? "allow" : "deny")
    }

    /// Send a text response (for questions/hints)
    func sendTextResponse(sessionId: String, text: String, paneId: String? = nil) async throws {
        let outboxURL = serverURL.appendingPathComponent("outbox")

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
            print("[InboxService] No model context set, skipping hint update")
            return
        }

        do {
            // Find pending hints linked to terminals with this pane ID
            let terminalDescriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == sessionId }
            )
            guard let terminal = try context.fetch(terminalDescriptor).first else {
                print("[InboxService] No terminal found for paneId: \(sessionId)")
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
                print("[InboxService] Marked hint as answered: \(hint.title)")
            }

            try context.save()

            // Trigger sync
            Task {
                await SyncScheduler.shared.scheduleSync()
            }
        } catch {
            print("[InboxService] Error marking hints as answered: \(error)")
        }
    }

    /// Create a Hint from a PermissionRequest event and persist it to SwiftData
    private func persistPermissionRequestAsHint(event: InboxEvent, paneId: String) {
        print("[InboxService] === HINT PERSISTENCE DEBUG ===")
        print("[InboxService] Pane ID: \(paneId)")
        print("[InboxService] CWD: \(event.event.cwd ?? "nil")")

        guard let context = modelContext else {
            print("[InboxService] ERROR: No model context set, skipping hint persistence")
            return
        }
        print("[InboxService] Model context available: YES")

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
                    print("[InboxService] Linked hint to task via terminal: \(task.title)")
                }
            }

            // Fallback: if not linked to task, try to find workspace by cwd and link to running task
            if !linkedToTask, let cwd = event.event.cwd {
                print("[InboxService] Trying workspace fallback for cwd: \(cwd)")

                // Find workspace that matches this cwd
                let workspaceDescriptor = FetchDescriptor<Workspace>()
                let workspaces = try context.fetch(workspaceDescriptor)
                print("[InboxService] Found \(workspaces.count) workspaces")

                for ws in workspaces {
                    print("[InboxService]   - Workspace: \(ws.name), path: \(ws.path ?? "nil"), tasks: \(ws.tasks.count), syncId: \(ws.syncId?.uuidString ?? "nil")")
                }

                // Find workspace whose path is a prefix of cwd (or exact match)
                if let workspace = workspaces.first(where: { ws in
                    guard let wsPath = ws.path else { return false }
                    let matches = cwd.hasPrefix(wsPath) || wsPath.hasPrefix(cwd)
                    if matches {
                        print("[InboxService] Matched workspace: \(ws.name)")
                    }
                    return matches
                }) {
                    // Find a running task in this workspace, or the most recent task
                    print("[InboxService] Workspace \(workspace.name) has \(workspace.tasks.count) tasks")
                    for task in workspace.tasks {
                        print("[InboxService]   - Task: \(task.title), status: \(task.status), syncId: \(task.syncId?.uuidString ?? "nil")")
                    }

                    let runningStatus = TaskStatus.running.rawValue
                    let runningTask = workspace.tasks.first { $0.status == runningStatus }
                    let fallbackTask = workspace.tasks.sorted { $0.createdAt > $1.createdAt }.first

                    if let task = runningTask ?? fallbackTask {
                        hint.task = task
                        linkedToTask = true
                        print("[InboxService] Linked hint to task via workspace: \(task.title) (syncId: \(task.syncId?.uuidString ?? "nil"))")
                    } else {
                        print("[InboxService] No tasks found in workspace \(workspace.name)")
                    }
                } else {
                    print("[InboxService] No workspace matched cwd: \(cwd)")
                }
            }

            if !linkedToTask {
                print("[InboxService] WARNING: Hint not linked to any task, won't sync to Supabase")
            }
        } catch {
            print("[InboxService] Error finding terminal/workspace: \(error)")
        }

        // Insert and save
        context.insert(hint)
        do {
            try context.save()
            print("[InboxService] Persisted hint: \(title) (linked to task: \(linkedToTask))")

            // Trigger sync if available
            Task {
                await SyncScheduler.shared.scheduleSync()
            }
        } catch {
            print("[InboxService] Failed to save hint: \(error)")
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
