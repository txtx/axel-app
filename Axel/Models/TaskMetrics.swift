import Foundation

/// Tracks metrics for a Claude Code task (associated with a Terminal)
@Observable
final class TaskMetrics {
    /// Claude Code session ID (used to link to Terminal)
    let claudeSessionId: String

    /// Total tokens by type
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0

    /// Total cost in USD
    var costUSD: Double = 0.0

    /// Lines of code changed
    var linesAdded: Int = 0
    var linesRemoved: Int = 0

    /// Active time in seconds
    var activeTimeSeconds: Double = 0.0

    /// Steps (each PermissionRequest marks a new step)
    var steps: [TaskStep] = []

    /// Current step being tracked
    private var currentStep: TaskStep?

    init(claudeSessionId: String) {
        self.claudeSessionId = claudeSessionId
        // Start with an initial step
        startNewStep()
    }

    /// Total tokens across all types
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    /// Formatted cost string
    var formattedCost: String {
        String(format: "$%.4f", costUSD)
    }

    /// Start a new step (called on PermissionRequest)
    func startNewStep() {
        // Finalize current step
        if let step = currentStep {
            step.endTokens = totalTokens
            step.endCost = costUSD
        }

        // Create new step
        let step = TaskStep(
            index: steps.count,
            startTokens: totalTokens,
            startCost: costUSD
        )
        steps.append(step)
        currentStep = step
    }

    /// Mark the current step with a permission request
    func recordPermissionRequest(toolName: String, filePath: String?) {
        currentStep?.toolName = toolName
        currentStep?.filePath = filePath
        currentStep?.timestamp = Date()

        // Start a new step for the next action
        startNewStep()
    }

    /// Accumulate per-response token values from OTEL log records (Codex).
    /// Unlike `updateFromOTEL` which assigns cumulative values, this ADDS to existing totals
    /// because Codex sends per-response counts, not session-cumulative ones.
    func accumulateFromLog(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        costUSD: Double = 0
    ) {
        self.inputTokens += inputTokens
        self.outputTokens += outputTokens
        self.costUSD += costUSD

        // Update current step's end values
        currentStep?.endTokens = totalTokens
        currentStep?.endCost = self.costUSD
    }

    /// Update metrics from OTEL data.
    /// NOTE: This ASSIGNS values (not adds). Values should be cumulative from OTEL.
    func updateFromOTEL(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        costUSD: Double? = nil,
        linesAdded: Int? = nil,
        linesRemoved: Int? = nil,
        activeTimeSeconds: Double? = nil
    ) {
        // DEBUG: Log before/after for token updates
        let prevIn = self.inputTokens
        let prevOut = self.outputTokens

        if let v = inputTokens { self.inputTokens = v }
        if let v = outputTokens { self.outputTokens = v }
        if let v = cacheReadTokens { self.cacheReadTokens = v }
        if let v = cacheCreationTokens { self.cacheCreationTokens = v }
        if let v = costUSD { self.costUSD = v }
        if let v = linesAdded { self.linesAdded = v }
        if let v = linesRemoved { self.linesRemoved = v }
        if let v = activeTimeSeconds { self.activeTimeSeconds = v }

        // DEBUG: Log if token values changed
        if inputTokens != nil || outputTokens != nil {
            print("[TaskMetrics:\(claudeSessionId.prefix(8))] updateFromOTEL: in:\(prevIn)→\(self.inputTokens) out:\(prevOut)→\(self.outputTokens)")
        }

        // Update current step's end values
        currentStep?.endTokens = totalTokens
        currentStep?.endCost = self.costUSD
    }
}

/// A point-in-time snapshot of metrics (for completion events)
struct MetricsSnapshot: Codable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let costUSD: Double
    let linesAdded: Int
    let linesRemoved: Int
    let activeTimeSeconds: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    var formattedCost: String {
        String(format: "$%.4f", costUSD)
    }

    /// Create a snapshot from current metrics
    init(from metrics: TaskMetrics) {
        self.inputTokens = metrics.inputTokens
        self.outputTokens = metrics.outputTokens
        self.cacheReadTokens = metrics.cacheReadTokens
        self.cacheCreationTokens = metrics.cacheCreationTokens
        self.costUSD = metrics.costUSD
        self.linesAdded = metrics.linesAdded
        self.linesRemoved = metrics.linesRemoved
        self.activeTimeSeconds = metrics.activeTimeSeconds
    }

    /// Create a delta snapshot (current - previous) for per-task values
    init(from metrics: TaskMetrics, subtractingPrevious previous: MetricsSnapshot?) {
        if let prev = previous {
            self.inputTokens = max(0, metrics.inputTokens - prev.inputTokens)
            self.outputTokens = max(0, metrics.outputTokens - prev.outputTokens)
            self.cacheReadTokens = max(0, metrics.cacheReadTokens - prev.cacheReadTokens)
            self.cacheCreationTokens = max(0, metrics.cacheCreationTokens - prev.cacheCreationTokens)
            self.costUSD = max(0, metrics.costUSD - prev.costUSD)
            self.linesAdded = max(0, metrics.linesAdded - prev.linesAdded)
            self.linesRemoved = max(0, metrics.linesRemoved - prev.linesRemoved)
            self.activeTimeSeconds = max(0, metrics.activeTimeSeconds - prev.activeTimeSeconds)
        } else {
            // No previous snapshot, use current values as-is
            self.inputTokens = metrics.inputTokens
            self.outputTokens = metrics.outputTokens
            self.cacheReadTokens = metrics.cacheReadTokens
            self.cacheCreationTokens = metrics.cacheCreationTokens
            self.costUSD = metrics.costUSD
            self.linesAdded = metrics.linesAdded
            self.linesRemoved = metrics.linesRemoved
            self.activeTimeSeconds = metrics.activeTimeSeconds
        }
    }
}

/// Represents a single step/action in a task
@Observable
final class TaskStep: Identifiable {
    let id = UUID()
    let index: Int
    let startTokens: Int
    let startCost: Double

    var endTokens: Int = 0
    var endCost: Double = 0.0

    var toolName: String?
    var filePath: String?
    var timestamp: Date?

    init(index: Int, startTokens: Int, startCost: Double) {
        self.index = index
        self.startTokens = startTokens
        self.startCost = startCost
        self.endTokens = startTokens
        self.endCost = startCost
    }

    /// Tokens used in this step
    var tokensUsed: Int {
        endTokens - startTokens
    }

    /// Cost for this step
    var stepCost: Double {
        endCost - startCost
    }

    /// Description of the step
    var description: String {
        if let tool = toolName {
            if let path = filePath {
                return "\(tool): \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return tool
        }
        return "Step \(index + 1)"
    }
}
