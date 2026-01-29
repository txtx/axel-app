import Foundation

// MARK: - Token Counting Architecture
//
// This file implements the cost tracking system for Claude Code sessions.
//
// ## Data Flow
//
// ```
// OTEL SSE Event (cumulative per-model counters)
//       ↓
// InboxService.parseOTELMetrics()
//       ↓
// InboxService.parseMetric()
//   - Aggregates datapoints by session (SUMS across models)
//   - Updates TaskMetrics with aggregated cumulative values
//       ↓
// CostTracker.recordMetrics(forSession:...)
//   - Resolves sessionId → paneId via registered mapping
//   - Delegates to TerminalCostTracker
//       ↓
// TerminalCostTracker.recordMetrics()
//   - Computes DELTA = incoming cumulative - lastSessionCumulative
//   - Adds delta to all-time totals
//   - Appends delta to timeSeries for histogram/activity detection
// ```
//
// ## Key Design Decisions
//
// 1. **OTEL sends cumulative values**: Each OTEL batch contains cumulative
//    token counts since session start, not deltas. Multiple models in a
//    session report separately.
//
// 2. **Delta calculation happens here**: TerminalCostTracker tracks
//    "lastSession" values to compute deltas. This handles:
//    - Out-of-order OTEL batches (max(0, delta) prevents negatives)
//    - Session resets (detected via 50% drop threshold)
//    - Multiple calls with same values (delta = 0)
//
// 3. **Session ID mapping**: OTEL uses Claude's internal sessionId, but
//    we track by paneId (terminal identifier). The mapping is registered
//    when hook events arrive (they contain both IDs).
//
// 4. **Multi-model aggregation**: InboxService sums datapoints across
//    models before calling recordMetrics. This assumes each model reports
//    its own cumulative counter, not a shared session total.
//
// ## Debugging Token Over-Counting
//
// If tokens appear to count too fast, check:
// 1. OTEL datapoint structure - are values per-model or session-total?
// 2. Is parseMetric called multiple times with overlapping data?
// 3. Is the sessionId→paneId mapping correct (no duplicates)?
//
// Add logging in TerminalCostTracker.recordMetrics() to trace:
//   print("[CostTracker] paneId=\(id) incoming=\(inputTokens) last=\(lastSessionInputTokens) delta=\(deltaInput)")

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

/// Tracks token usage for a single terminal (identified by paneId).
///
/// ## Delta Calculation
///
/// OTEL sends **cumulative** values (total tokens since session start).
/// This class computes deltas by tracking what was last reported:
///
/// ```
/// Batch 1: incoming=1000 → delta = 1000 - 0 = 1000, lastSession = 1000
/// Batch 2: incoming=1500 → delta = 1500 - 1000 = 500, lastSession = 1500
/// Batch 3: incoming=1500 → delta = 1500 - 1500 = 0 (no change)
/// ```
///
/// ## Session Reset Detection
///
/// When a new Claude session starts, OTEL counters reset to 0. We detect this
/// via a "50% drop" heuristic: if incoming total < lastSession total / 2
/// (and lastSession had >100 tokens), we reset lastSession tracking values
/// but preserve all-time cumulative totals.
///
/// ## Thread Safety
///
/// This class is `@Observable` and should only be accessed from `@MainActor`.
@Observable
final class TerminalCostTracker: Identifiable {
    let id: String  // paneId (terminal identifier)

    /// Time series of token deltas (not cumulative). Each entry represents
    /// new tokens consumed since the previous entry. Used for histograms
    /// and activity detection (recent entry = "thinking" state).
    private(set) var timeSeries: [TokenDataPoint] = []

    /// All-time cumulative totals. These persist across Claude session resets
    /// and represent total consumption for this terminal's lifetime.
    private(set) var totalInputTokens: Int = 0
    private(set) var totalOutputTokens: Int = 0
    private(set) var totalCacheReadTokens: Int = 0
    private(set) var totalCacheCreationTokens: Int = 0
    private(set) var totalCostUSD: Double = 0

    /// Last reported cumulative values from OTEL (for delta calculation).
    /// These are reset when a new Claude session is detected.
    private var lastSessionInputTokens: Int = 0
    private var lastSessionOutputTokens: Int = 0
    private var lastSessionCacheReadTokens: Int = 0
    private var lastSessionCacheCreationTokens: Int = 0
    private var lastSessionCostUSD: Double = 0

    /// Maximum data points to keep in timeSeries (for histogram display)
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

    /// Record a metrics update from OTEL data.
    ///
    /// - Parameters:
    ///   - inputTokens: Cumulative input tokens from OTEL (not a delta)
    ///   - outputTokens: Cumulative output tokens from OTEL
    ///   - cacheReadTokens: Cumulative cache read tokens from OTEL
    ///   - cacheCreationTokens: Cumulative cache creation tokens from OTEL
    ///   - costUSD: Cumulative cost from OTEL
    ///
    /// - Returns: Computed deltas for this update (used for global aggregation)
    ///
    /// ## Algorithm
    ///
    /// 1. **Session reset detection**: If incoming total < 50% of last session
    ///    (and last session had >100 tokens), assume new Claude session started.
    ///    Reset lastSession tracking but preserve all-time totals.
    ///
    /// 2. **Delta calculation**: `delta = incoming - lastSession`. Uses `max(0, ...)`
    ///    to handle out-of-order OTEL batches that might report slightly lower values.
    ///
    /// 3. **Time series**: Append delta to `timeSeries` if non-zero (for histograms).
    ///
    /// 4. **Update tracking**: Store incoming values as new `lastSession` values.
    ///
    /// 5. **Accumulate**: Add deltas to all-time totals.
    ///
    /// ## Why This Works
    ///
    /// If the same cumulative value arrives twice (e.g., parseMetric called
    /// multiple times per OTEL batch), the second call computes delta=0:
    ///
    /// ```
    /// Call 1: incoming=1000, lastSession=500 → delta=500, lastSession=1000
    /// Call 2: incoming=1000, lastSession=1000 → delta=0 (no double-count)
    /// ```
    @discardableResult
    func recordMetrics(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreationTokens: Int, costUSD: Double) -> (deltaInput: Int, deltaOutput: Int, deltaCacheRead: Int, deltaCacheCreation: Int, deltaCost: Double) {
        // Step 1: Detect session reset
        // OTEL counters reset when a new Claude session starts. We detect this
        // by checking if the incoming total is NEAR ZERO (not just lower than before).
        //
        // IMPORTANT: We can NOT use "incoming < lastSession/2" because OTEL batches
        // don't always include all models. When a subagent (haiku) is used alongside
        // the main model (sonnet), we sum their cumulative counters. But if one batch
        // only contains one model's data, the sum drops significantly - this is NOT
        // a session reset, just incomplete data.
        //
        // A REAL session reset would have incoming values near 0 (fresh session).
        let incomingTotal = inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
        let lastSessionTotal = lastSessionInputTokens + lastSessionOutputTokens + lastSessionCacheReadTokens + lastSessionCacheCreationTokens

        // Only reset if incoming is near zero AND we had significant previous data
        // This catches real session resets while ignoring incomplete OTEL batches
        let sessionReset = lastSessionTotal > 1000 && incomingTotal < 100

        // DEBUG: Log incoming values and session state
        print("[CostTracker:\(id.prefix(8))] recordMetrics: incoming(in:\(inputTokens) out:\(outputTokens) cacheR:\(cacheReadTokens) cacheC:\(cacheCreationTokens)) lastSession(in:\(lastSessionInputTokens) out:\(lastSessionOutputTokens)) total:\(totalInputTokens + totalOutputTokens)")

        if sessionReset {
            print("[CostTracker:\(id.prefix(8))] SESSION RESET detected: incoming=\(incomingTotal) near zero, lastSession=\(lastSessionTotal)")
            // New Claude session started - reset tracking but keep all-time totals
            lastSessionInputTokens = 0
            lastSessionOutputTokens = 0
            lastSessionCacheReadTokens = 0
            lastSessionCacheCreationTokens = 0
            lastSessionCostUSD = 0
        }

        // Step 2: Calculate delta from last session values
        // max(0, ...) handles out-of-order OTEL batches where a value might
        // temporarily appear lower than the previous report
        let deltaInput = max(0, inputTokens - lastSessionInputTokens)
        let deltaOutput = max(0, outputTokens - lastSessionOutputTokens)
        let deltaCacheRead = max(0, cacheReadTokens - lastSessionCacheReadTokens)
        let deltaCacheCreation = max(0, cacheCreationTokens - lastSessionCacheCreationTokens)
        let deltaCost = max(0, costUSD - lastSessionCostUSD)
        let deltaTotal = deltaInput + deltaOutput + deltaCacheRead + deltaCacheCreation

        // DEBUG: Log computed deltas
        if deltaTotal > 0 {
            print("[CostTracker:\(id.prefix(8))] DELTA: in:\(deltaInput) out:\(deltaOutput) cacheR:\(deltaCacheRead) cacheC:\(deltaCacheCreation) → newTotal:\(totalInputTokens + totalOutputTokens + deltaInput + deltaOutput)")
        }

        // Step 3: Add to time series if there's actual change
        // This feeds the histogram display and activity detection
        if deltaTotal > 0 {
            let delta = TokenDataPoint(
                timestamp: Date(),
                inputTokens: deltaInput,
                outputTokens: deltaOutput,
                cacheReadTokens: deltaCacheRead,
                cacheCreationTokens: deltaCacheCreation,
                costUSD: deltaCost
            )
            timeSeries.append(delta)

            // Trim old data points to bound memory usage
            if timeSeries.count > maxDataPoints {
                timeSeries.removeFirst(timeSeries.count - maxDataPoints)
            }
        }

        // Step 4: Update last session values for next delta calculation
        // IMPORTANT: Only update if incoming >= last value. OTEL batches may be
        // incomplete (not all models report in every batch). If we store a lower
        // value, the next complete batch would compute an inflated delta.
        //
        // Example of the bug this prevents:
        //   Batch 1 (2 models): sum=100k → lastSession=100k
        //   Batch 2 (1 model):  sum=40k  → if we set lastSession=40k...
        //   Batch 3 (2 models): sum=110k → delta=70k (wrong! should be 10k)
        //
        // By keeping lastSession at the max seen value, we correctly compute:
        //   Batch 2: delta=0, lastSession stays 100k
        //   Batch 3: delta=10k (correct!)
        if inputTokens >= lastSessionInputTokens {
            lastSessionInputTokens = inputTokens
        }
        if outputTokens >= lastSessionOutputTokens {
            lastSessionOutputTokens = outputTokens
        }
        if cacheReadTokens >= lastSessionCacheReadTokens {
            lastSessionCacheReadTokens = cacheReadTokens
        }
        if cacheCreationTokens >= lastSessionCacheCreationTokens {
            lastSessionCacheCreationTokens = cacheCreationTokens
        }
        if costUSD >= lastSessionCostUSD {
            lastSessionCostUSD = costUSD
        }

        // Step 5: Accumulate into all-time totals
        totalInputTokens += deltaInput
        totalOutputTokens += deltaOutput
        totalCacheReadTokens += deltaCacheRead
        totalCacheCreationTokens += deltaCacheCreation
        totalCostUSD += deltaCost

        return (deltaInput, deltaOutput, deltaCacheRead, deltaCacheCreation, deltaCost)
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

/// Singleton service for tracking costs across the app.
///
/// ## Architecture Overview
///
/// ```
/// CostTracker (singleton)
///     ├── terminalTrackers: [paneId → TerminalCostTracker]
///     │       └── Tracks per-terminal cumulative totals and time series
///     ├── taskTrackers: [taskId → TaskCostTracker]
///     │       └── Tracks per-task breakdown with segments
///     ├── sessionIdToPaneId: [sessionId → paneId]
///     │       └── Maps Claude's internal sessionId to our paneId
///     └── globalTimeSeries: [TokenDataPoint]
///             └── Aggregated deltas across all terminals
/// ```
///
/// ## Session ID vs Pane ID
///
/// - **sessionId**: Claude Code's internal session identifier (from OTEL)
/// - **paneId**: Our terminal identifier (from tmux/zellij)
///
/// OTEL metrics arrive with sessionId, but we track by paneId. The mapping
/// is registered when hook events arrive (they contain both IDs).
///
/// ## Thread Safety
///
/// All access must be on `@MainActor`. The class is `@Observable` for SwiftUI.
@MainActor
@Observable
final class CostTracker {
    static let shared = CostTracker()

    /// Global time series of token deltas (aggregated across all terminals).
    /// Used for app-wide activity indicators.
    private(set) var globalTimeSeries: [TokenDataPoint] = []

    /// Per-terminal cost trackers, keyed by paneId (our terminal identifier).
    /// Each terminal has independent tracking that survives Claude session resets.
    private(set) var terminalTrackers: [String: TerminalCostTracker] = [:]

    /// Per-task cost trackers, keyed by task UUID.
    /// Provides breakdown by segments (between permission requests).
    private(set) var taskTrackers: [UUID: TaskCostTracker] = [:]

    /// Maps Claude's sessionId (from OTEL) to our paneId (terminal identifier).
    /// Registered when hook events arrive with both IDs. Required because OTEL
    /// only knows sessionId, but we need to find the right TerminalCostTracker.
    private var sessionIdToPaneId: [String: String] = [:]

    /// Maps paneId to taskId for linking terminal metrics to task trackers.
    private var paneToTask: [String: UUID] = [:]

    /// Maximum data points to keep in globalTimeSeries
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
    /// This is the primary entry point for token consumption data from Claude Code.
    /// When tokens are consumed, it indicates the LLM is actively working ("thinking").
    func recordMetrics(
        forSession sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        costUSD: Double
    ) {
        // Resolve sessionId to paneId (OTEL uses Claude's internal session ID)
        // The mapping is registered when hook events arrive with both IDs
        guard let paneId = sessionIdToPaneId[sessionId] else {
            return
        }

        // Get terminal tracker (keyed by paneId)
        let terminalTracker = tracker(forPaneId: paneId)

        // Update terminal tracker and get the correctly computed deltas
        let deltas = terminalTracker.recordMetrics(
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

        // Calculate total delta to check if there was actual activity
        let deltaTotal = deltas.deltaInput + deltas.deltaOutput + deltas.deltaCacheRead + deltas.deltaCacheCreation

        // NOTE: SessionStatusService detects "thinking" state by checking the
        // timestamp of the last data point in our time series. No need to
        // explicitly notify it - it reads our data directly to avoid circular deps.

        // Update global time series with delta from terminal tracker
        if deltaTotal > 0 {
            let point = TokenDataPoint(
                timestamp: Date(),
                inputTokens: deltas.deltaInput,
                outputTokens: deltas.deltaOutput,
                cacheReadTokens: deltas.deltaCacheRead,
                cacheCreationTokens: deltas.deltaCacheCreation,
                costUSD: deltas.deltaCost
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
