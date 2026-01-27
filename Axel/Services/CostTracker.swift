import Foundation

/// A data point in the token usage time series
struct TokenDataPoint: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Delta from a previous point
    init(current: TokenDataPoint, previous: TokenDataPoint?) {
        self.timestamp = current.timestamp
        if let prev = previous {
            self.inputTokens = max(0, current.inputTokens - prev.inputTokens)
            self.outputTokens = max(0, current.outputTokens - prev.outputTokens)
            self.cacheReadTokens = max(0, current.cacheReadTokens - prev.cacheReadTokens)
            self.cacheCreationTokens = max(0, current.cacheCreationTokens - prev.cacheCreationTokens)
            self.costUSD = max(0, current.costUSD - prev.costUSD)
        } else {
            self.inputTokens = current.inputTokens
            self.outputTokens = current.outputTokens
            self.cacheReadTokens = current.cacheReadTokens
            self.cacheCreationTokens = current.cacheCreationTokens
            self.costUSD = current.costUSD
        }
    }

    init(timestamp: Date = Date(), inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0, costUSD: Double = 0) {
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.costUSD = costUSD
    }
}

/// A segment of token usage within a task (between permission requests)
struct TaskSegment: Identifiable, Equatable {
    let id = UUID()
    let startTime: Date
    var endTime: Date?
    let toolName: String?
    let filePath: String?

    /// Tokens at segment start
    let startTokens: Int
    let startCost: Double

    /// Tokens at segment end (updated as metrics come in)
    var endTokens: Int
    var endCost: Double

    var tokensUsed: Int { endTokens - startTokens }
    var costUsed: Double { endCost - startCost }

    var description: String {
        if let tool = toolName {
            if let path = filePath {
                return "\(tool): \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return tool
        }
        return "Segment"
    }
}

/// Tracks token usage for a single terminal
@Observable
final class TerminalCostTracker: Identifiable {
    let id: String  // paneId or claudeSessionId

    /// Time series of token usage (deltas per update)
    private(set) var timeSeries: [TokenDataPoint] = []

    /// Current cumulative totals
    private(set) var totalInputTokens: Int = 0
    private(set) var totalOutputTokens: Int = 0
    private(set) var totalCacheReadTokens: Int = 0
    private(set) var totalCacheCreationTokens: Int = 0
    private(set) var totalCostUSD: Double = 0

    /// Maximum data points to keep (for histogram display)
    private let maxDataPoints = 60

    var totalTokens: Int {
        totalInputTokens + totalOutputTokens + totalCacheReadTokens + totalCacheCreationTokens
    }

    /// Recent token values for histogram (normalized 0-1)
    var histogramValues: [Double] {
        let recent = Array(timeSeries.suffix(12))
        guard !recent.isEmpty else { return Array(repeating: 0.1, count: 12) }

        let maxTokens = recent.map { Double($0.totalTokens) }.max() ?? 1
        let values = recent.map { maxTokens > 0 ? Double($0.totalTokens) / maxTokens : 0.1 }

        // Pad to 12 values if needed
        if values.count < 12 {
            return Array(repeating: 0.1, count: 12 - values.count) + values
        }
        return values
    }

    init(id: String) {
        self.id = id
    }

    /// Record a metrics update
    func recordMetrics(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, costUSD: Double) {
        // Calculate delta from previous cumulative values
        let delta = TokenDataPoint(
            timestamp: Date(),
            inputTokens: max(0, inputTokens - totalInputTokens),
            outputTokens: max(0, outputTokens - totalOutputTokens),
            cacheReadTokens: max(0, cacheReadTokens - totalCacheReadTokens),
            cacheCreationTokens: max(0, cacheCreationTokens - totalCacheCreationTokens),
            costUSD: max(0, costUSD - totalCostUSD)
        )

        // Only add if there's actual change
        if delta.totalTokens > 0 {
            timeSeries.append(delta)

            // Trim old data points
            if timeSeries.count > maxDataPoints {
                timeSeries.removeFirst(timeSeries.count - maxDataPoints)
            }
        }

        // Update cumulative totals
        totalInputTokens = inputTokens
        totalOutputTokens = outputTokens
        totalCacheReadTokens = cacheReadTokens
        totalCacheCreationTokens = cacheCreationTokens
        totalCostUSD = costUSD
    }
}

/// Tracks token usage for a task with breakdown by segments
@Observable
final class TaskCostTracker: Identifiable {
    let id: UUID  // taskId
    let taskTitle: String

    /// Segments of work (between permission requests)
    private(set) var segments: [TaskSegment] = []

    /// Current active segment
    private var currentSegment: TaskSegment?

    /// Cumulative totals for this task
    private(set) var totalTokens: Int = 0
    private(set) var totalCostUSD: Double = 0

    init(id: UUID, taskTitle: String) {
        self.id = id
        self.taskTitle = taskTitle
    }

    /// Start a new segment (called at task start or after permission request)
    func startSegment(toolName: String? = nil, filePath: String? = nil) {
        // Finalize current segment
        if var segment = currentSegment {
            segment.endTime = Date()
            segments.append(segment)
        }

        // Create new segment
        currentSegment = TaskSegment(
            startTime: Date(),
            endTime: nil,
            toolName: toolName,
            filePath: filePath,
            startTokens: totalTokens,
            startCost: totalCostUSD,
            endTokens: totalTokens,
            endCost: totalCostUSD
        )
    }

    /// Update metrics (called when OTEL data arrives)
    func updateMetrics(tokens: Int, costUSD: Double) {
        totalTokens = tokens
        totalCostUSD = costUSD

        // Update current segment's end values
        currentSegment?.endTokens = tokens
        currentSegment?.endCost = costUSD
    }

    /// Finalize tracking (task completed)
    func finalize() {
        if var segment = currentSegment {
            segment.endTime = Date()
            segments.append(segment)
            currentSegment = nil
        }
    }
}

/// Singleton service for tracking costs across the app
@MainActor
@Observable
final class CostTracker {
    static let shared = CostTracker()

    /// Global time series (aggregated from all terminals)
    private(set) var globalTimeSeries: [TokenDataPoint] = []

    /// Per-terminal trackers (keyed by paneId - our terminal identifier)
    private(set) var terminalTrackers: [String: TerminalCostTracker] = [:]

    /// Per-task trackers (keyed by task UUID)
    private(set) var taskTrackers: [UUID: TaskCostTracker] = [:]

    /// Mapping from claudeSessionId to paneId (OTEL uses sessionId, we need to find paneId)
    private var sessionIdToPaneId: [String: String] = [:]

    /// Mapping from paneId to taskId for linking
    private var paneToTask: [String: UUID] = [:]

    /// Maximum global data points
    private let maxGlobalDataPoints = 120

    // MARK: - Global Totals

    var globalTotalTokens: Int {
        terminalTrackers.values.reduce(0) { $0 + $1.totalTokens }
    }

    var globalTotalCostUSD: Double {
        terminalTrackers.values.reduce(0) { $0 + $1.totalCostUSD }
    }

    var formattedGlobalCost: String {
        String(format: "$%.4f", globalTotalCostUSD)
    }

    /// Recent global token values for histogram (normalized 0-1)
    var globalHistogramValues: [Double] {
        let recent = Array(globalTimeSeries.suffix(12))
        guard !recent.isEmpty else { return Array(repeating: 0.1, count: 12) }

        let maxTokens = recent.map { Double($0.totalTokens) }.max() ?? 1
        let values = recent.map { maxTokens > 0 ? Double($0.totalTokens) / maxTokens : 0.1 }

        // Pad to 12 values if needed
        if values.count < 12 {
            return Array(repeating: 0.1, count: 12 - values.count) + values
        }
        return values
    }

    private init() {}

    // MARK: - Session Mapping

    /// Register a mapping from claudeSessionId to paneId (called when hook events arrive)
    /// This allows us to find the right terminal when OTEL metrics arrive with sessionId
    func registerSession(paneId: String, sessionId: String) {
        sessionIdToPaneId[sessionId] = paneId
    }

    /// Get paneId for a sessionId (used when OTEL metrics arrive)
    func paneId(forSessionId sessionId: String) -> String? {
        sessionIdToPaneId[sessionId]
    }

    // MARK: - Terminal Tracking

    /// Get or create a terminal tracker by paneId
    func tracker(forPaneId paneId: String) -> TerminalCostTracker {
        if let existing = terminalTrackers[paneId] {
            return existing
        }
        let tracker = TerminalCostTracker(id: paneId)
        terminalTrackers[paneId] = tracker
        return tracker
    }

    /// Link a terminal (by paneId) to a task
    func linkTerminal(_ paneId: String, toTask taskId: UUID, taskTitle: String) {
        paneToTask[paneId] = taskId

        // Create task tracker if needed
        if taskTrackers[taskId] == nil {
            let tracker = TaskCostTracker(id: taskId, taskTitle: taskTitle)
            tracker.startSegment()  // Start initial segment
            taskTrackers[taskId] = tracker
        }
    }

    // MARK: - Metrics Recording

    /// Record metrics update from OTEL data (OTEL uses Claude's sessionId)
    func recordMetrics(
        forSession sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double
    ) {
        // Resolve sessionId to paneId (OTEL uses Claude's internal session ID)
        guard let paneId = sessionIdToPaneId[sessionId] else {
            return
        }

        // Get terminal tracker (keyed by paneId)
        let terminalTracker = tracker(forPaneId: paneId)

        // Compute deltas BEFORE updating tracker
        let deltaInput = max(0, inputTokens - terminalTracker.totalInputTokens)
        let deltaOutput = max(0, outputTokens - terminalTracker.totalOutputTokens)
        let deltaCacheRead = max(0, cacheReadTokens - terminalTracker.totalCacheReadTokens)
        let deltaCacheCreation = max(0, cacheCreationTokens - terminalTracker.totalCacheCreationTokens)
        let deltaCost = max(0, costUSD - terminalTracker.totalCostUSD)
        let deltaTotal = deltaInput + deltaOutput + deltaCacheRead + deltaCacheCreation

        // Update terminal tracker
        terminalTracker.recordMetrics(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            costUSD: costUSD
        )

        // Update task tracker if linked
        if let taskId = paneToTask[paneId],
           let taskTracker = taskTrackers[taskId] {
            taskTracker.updateMetrics(
                tokens: terminalTracker.totalTokens,
                costUSD: terminalTracker.totalCostUSD
            )
        }

        // Update global time series with delta
        if deltaTotal > 0 {
            let point = TokenDataPoint(
                timestamp: Date(),
                inputTokens: deltaInput,
                outputTokens: deltaOutput,
                cacheReadTokens: deltaCacheRead,
                cacheCreationTokens: deltaCacheCreation,
                costUSD: deltaCost
            )

            globalTimeSeries.append(point)

            if globalTimeSeries.count > maxGlobalDataPoints {
                globalTimeSeries.removeFirst(globalTimeSeries.count - maxGlobalDataPoints)
            }
        }
    }

    /// Record a permission request (starts new segment in task tracker)
    func recordPermissionRequest(forPaneId paneId: String, toolName: String?, filePath: String?) {
        if let taskId = paneToTask[paneId],
           let taskTracker = taskTrackers[taskId] {
            taskTracker.startSegment(toolName: toolName, filePath: filePath)
        }
    }

    /// Finalize a task (called on Stop event)
    func finalizeTask(forPaneId paneId: String) {
        if let taskId = paneToTask[paneId],
           let taskTracker = taskTrackers[taskId] {
            taskTracker.finalize()
        }
    }

    // MARK: - Queries

    /// Get histogram values for a specific terminal (by paneId)
    func histogramValues(forTerminal paneId: String) -> [Double] {
        terminalTrackers[paneId]?.histogramValues ?? Array(repeating: 0.1, count: 12)
    }

    /// Get total tokens for a specific terminal (by paneId)
    func totalTokens(forTerminal paneId: String) -> Int {
        terminalTrackers[paneId]?.totalTokens ?? 0
    }

    /// Get task tracker for a paneId
    func taskTracker(forPaneId paneId: String) -> TaskCostTracker? {
        guard let taskId = paneToTask[paneId] else { return nil }
        return taskTrackers[taskId]
    }

    /// Get segments for a task
    func segments(forTask taskId: UUID) -> [TaskSegment] {
        taskTrackers[taskId]?.segments ?? []
    }

    // MARK: - Cleanup

    /// Clear all tracking data
    func clearAll() {
        globalTimeSeries.removeAll()
        terminalTrackers.removeAll()
        taskTrackers.removeAll()
        sessionIdToPaneId.removeAll()
        paneToTask.removeAll()
    }

    /// Remove tracking for a specific terminal
    func removeTerminal(_ paneId: String) {
        terminalTrackers.removeValue(forKey: paneId)
        paneToTask.removeValue(forKey: paneId)
        // Also remove sessionId mappings that point to this paneId
        sessionIdToPaneId = sessionIdToPaneId.filter { $0.value != paneId }
    }
}
