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

    // MARK: - Port Allocation

    /// Allocate a unique port for a new terminal
    func allocatePort() -> Int {
        let port = nextPort
        nextPort += 1
        return port
    }

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
            let otelPaneId = json["pane_id"] as? String
            parseOTELMetrics(json, paneId: otelPaneId)
            return
        }

        // Parse as InboxEvent
        do {
            let event = try decoder.decode(InboxEvent.self, from: data)

            // Register paneId to sessionId mapping for ANY event that has both
            // This ensures the mapping exists before OTEL metrics arrive
            if let sessionId = event.event.claudeSessionId {
                CostTracker.shared.registerSession(paneId: event.paneId, sessionId: sessionId)
            }

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

                // Update CostTracker with permission request (use paneId)
                CostTracker.shared.recordPermissionRequest(
                    forPaneId: paneId,
                    toolName: event.event.toolName,
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

                // Finalize task in CostTracker (use paneId)
                CostTracker.shared.finalizeTask(forPaneId: event.paneId)

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

    private func parseOTELMetrics(_ json: [String: Any], paneId: String?) {
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
                    parseMetric(metric, paneId: paneId)
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
        }

        pendingStopEvents.removeAll()
    }

    private func parseMetric(_ metric: [String: Any], paneId eventPaneId: String?) {
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

            // If we have paneId from the event, register the mapping
            if let paneId = eventPaneId {
                // Register the mapping (this is idempotent - won't overwrite if already exists)
                CostTracker.shared.registerSession(paneId: paneId, sessionId: sid)
            }

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

            // Update CostTracker with the metrics
            CostTracker.shared.recordMetrics(
                forSession: sid,
                inputTokens: metrics.inputTokens,
                outputTokens: metrics.outputTokens,
                cacheReadTokens: metrics.cacheReadTokens,
                cacheCreationTokens: metrics.cacheCreationTokens,
                costUSD: metrics.costUSD
            )
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
        let serverPort = port(for: paneId)
        let outboxURL = URL(string: "http://localhost:\(serverPort)/outbox")!

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
