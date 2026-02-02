import Foundation

// MARK: - Session Status
// ============================================================================
// SessionStatus represents the unified state of a terminal/agent session.
// It combines multiple data sources to determine what the agent is "doing":
//
// Data Sources:
// 1. CostTracker - Token consumption indicates LLM activity (thinking/generating)
// 2. InboxService - Permission requests indicate blocked state
// 3. TerminalSession - Task assignment indicates if agent has work
//
// Status Priority (highest to lowest):
// - .blocked: Has pending permission request (user action required)
// - .thinking: Recent token activity detected (LLM is generating)
// - .active: Has task assigned but no recent activity
// - .idle: Has task but hasn't consumed tokens recently
// - .dormant: No task assigned (available for work)
// ============================================================================

/// The computed status of a terminal/agent session
enum SessionStatus: String, CaseIterable, Sendable {
    /// Waiting for user to approve a permission request
    /// Source: InboxService.blockedPaneIds contains this session's paneId
    case blocked = "blocked"

    /// LLM is actively generating (consuming tokens)
    /// Source: CostTracker shows recent token delta within last N seconds
    case thinking = "thinking"

    /// Has a task and running, but not currently generating
    /// Source: Has taskId, not blocked, no recent token activity
    case active = "active"

    /// Has a task but idle for a while (may be waiting on external process)
    /// Source: Has taskId, no activity for extended period
    case idle = "idle"

    /// No task assigned - available to take on work
    /// Source: taskId is nil
    case dormant = "dormant"

    // MARK: - Display Properties

    /// SF Symbol icon for this status
    var icon: String {
        switch self {
        case .blocked: return "exclamationmark.circle.fill"
        case .thinking: return "brain.fill"
        case .active: return "bolt.fill"
        case .idle: return "hourglass"
        case .dormant: return "moon.fill"
        }
    }

    /// Human-readable label
    var label: String {
        switch self {
        case .blocked: return "Blocked"
        case .thinking: return "Thinking"
        case .active: return "Active"
        case .idle: return "Idle"
        case .dormant: return "Dormant"
        }
    }

    /// Priority for sorting (lower = more urgent/important)
    var sortPriority: Int {
        switch self {
        case .blocked: return 0   // Needs attention first
        case .thinking: return 1  // Actively working
        case .active: return 2    // Has work but not generating
        case .idle: return 3      // Stale/waiting
        case .dormant: return 4   // Available
        }
    }

    /// Whether this status indicates the session needs attention
    var needsAttention: Bool {
        self == .blocked
    }

    /// Whether this status indicates the session is doing work
    var isWorking: Bool {
        self == .thinking || self == .active
    }
}

// MARK: - Session Status Service
// ============================================================================
// Centralized service that computes and tracks session status by combining
// multiple data sources. UI components should observe this service instead of
// computing status locally.
//
// Architecture:
// - Singleton service (SessionStatusService.shared)
// - @Observable for SwiftUI reactivity
// - Polls/debounces to avoid excessive recomputation
// - Caches status to reduce redundant queries
// ============================================================================

/// Threshold for considering a session "thinking" (had token activity within this window)
private let thinkingActivityThresholdSeconds: TimeInterval = 10

/// Threshold for considering a session "idle" (no activity for longer than this)
private let idleActivityThresholdSeconds: TimeInterval = 60

@MainActor
@Observable
final class SessionStatusService {

    // MARK: - Singleton

    static let shared = SessionStatusService()

    // MARK: - Dependencies
    // These are injected/referenced from their respective singletons

    private let costTracker: CostTracker
    private let inboxService: InboxService

    // MARK: - Cached Status
    // Status is computed on-demand and cached briefly to avoid redundant work

    /// Last computed status per paneId
    private var statusCache: [String: SessionStatus] = [:]

    /// Timestamp of last status computation per paneId
    private var statusCacheTimestamp: [String: Date] = [:]

    /// Cache validity duration (how long before recomputing)
    private let cacheValiditySeconds: TimeInterval = 0.5

    // MARK: - Activity Tracking
    // Track when each session last had token activity (for thinking vs idle detection)

    /// Last activity timestamp per paneId (set when tokens are consumed)
    private var lastActivityTimestamp: [String: Date] = [:]

    // MARK: - Initialization

    private init() {
        self.costTracker = CostTracker.shared
        self.inboxService = InboxService.shared
    }

    // MARK: - Public API

    /// Get the current status for a session by paneId
    /// This is the primary method UI components should use
    func status(forPaneId paneId: String?, hasTask: Bool) -> SessionStatus {
        guard let paneId = paneId else {
            // No paneId means session isn't fully initialized
            return hasTask ? .active : .dormant
        }

        // Check cache validity
        if let cached = statusCache[paneId],
           let timestamp = statusCacheTimestamp[paneId],
           Date().timeIntervalSince(timestamp) < cacheValiditySeconds {
            return cached
        }

        // Compute fresh status
        let status = computeStatus(forPaneId: paneId, hasTask: hasTask)

        // Update cache
        statusCache[paneId] = status
        statusCacheTimestamp[paneId] = Date()

        return status
    }

    /// Check if a session is blocked (has pending permission request)
    /// Convenience method for quick blocking checks
    func isBlocked(paneId: String?) -> Bool {
        guard let paneId = paneId else { return false }
        return inboxService.blockedPaneIds.contains(paneId)
    }

    /// Check if a session is actively thinking (recent token consumption)
    /// Convenience method for activity indicators
    func isThinking(paneId: String?) -> Bool {
        guard let paneId = paneId else { return false }
        return hasRecentActivity(paneId: paneId, withinSeconds: thinkingActivityThresholdSeconds)
    }

    /// Record activity for a session (called by CostTracker or directly)
    /// This updates the "last activity" timestamp used for thinking detection
    func recordActivity(forPaneId paneId: String) {
        lastActivityTimestamp[paneId] = Date()
        // Invalidate cache so next status query recomputes
        statusCache.removeValue(forKey: paneId)
    }

    /// Clear tracking data for a session (called when session ends)
    func clearSession(paneId: String) {
        statusCache.removeValue(forKey: paneId)
        statusCacheTimestamp.removeValue(forKey: paneId)
        lastActivityTimestamp.removeValue(forKey: paneId)
    }

    // MARK: - Batch Queries
    // For UI components that need to categorize multiple sessions

    /// Get all sessions with a specific status
    func sessions<T: SessionIdentifiable>(from sessions: [T], withStatus status: SessionStatus) -> [T] {
        sessions.filter { self.status(forPaneId: $0.paneId, hasTask: $0.hasTask) == status }
    }

    /// Group sessions by status, sorted by status priority
    func groupedByStatus<T: SessionIdentifiable>(_ sessions: [T]) -> [(status: SessionStatus, sessions: [T])] {
        var grouped: [SessionStatus: [T]] = [:]

        for session in sessions {
            let sessionStatus = status(forPaneId: session.paneId, hasTask: session.hasTask)
            grouped[sessionStatus, default: []].append(session)
        }

        // Sort by status priority and filter out empty groups
        return SessionStatus.allCases
            .compactMap { status in
                guard let sessions = grouped[status], !sessions.isEmpty else { return nil }
                return (status: status, sessions: sessions)
            }
    }

    /// Get sessions ordered by status priority (blocked first, dormant last)
    func orderedByPriority<T: SessionIdentifiable>(_ sessions: [T]) -> [T] {
        sessions.sorted { lhs, rhs in
            let lhsStatus = status(forPaneId: lhs.paneId, hasTask: lhs.hasTask)
            let rhsStatus = status(forPaneId: rhs.paneId, hasTask: rhs.hasTask)
            return lhsStatus.sortPriority < rhsStatus.sortPriority
        }
    }

    // MARK: - Status Counts
    // For badges and summary displays

    /// Count of sessions that need attention (blocked)
    func blockedCount<T: SessionIdentifiable>(in sessions: [T]) -> Int {
        sessions.filter { isBlocked(paneId: $0.paneId) }.count
    }

    /// Count of sessions actively working (thinking or active)
    func workingCount<T: SessionIdentifiable>(in sessions: [T]) -> Int {
        sessions.filter {
            let s = status(forPaneId: $0.paneId, hasTask: $0.hasTask)
            return s.isWorking
        }.count
    }

    // MARK: - Private: Status Computation

    /// Core status computation logic
    /// Priority: blocked > thinking > active > idle > dormant
    private func computeStatus(forPaneId paneId: String, hasTask: Bool) -> SessionStatus {
        // 1. Check for blocking permission request (highest priority)
        //    Source: InboxService tracks unresolved permission requests per paneId
        if inboxService.blockedPaneIds.contains(paneId) {
            return .blocked
        }

        // 2. No task = dormant (available for assignment)
        guard hasTask else {
            return .dormant
        }

        // 3. Check for recent token activity (thinking state)
        //    Source: CostTracker time series shows when tokens were consumed
        if hasRecentActivity(paneId: paneId, withinSeconds: thinkingActivityThresholdSeconds) {
            return .thinking
        }

        // 4. Check for extended inactivity (idle state)
        //    No tokens consumed for a while, but still has task
        if !hasRecentActivity(paneId: paneId, withinSeconds: idleActivityThresholdSeconds) {
            // Has been inactive for more than the idle threshold
            return .idle
        }

        // 5. Default: has task, not blocked, not currently thinking, not idle yet
        return .active
    }

    /// Check if a session has had activity within the given time window
    private func hasRecentActivity(paneId: String, withinSeconds threshold: TimeInterval) -> Bool {
        // First check our locally tracked activity timestamp
        if let lastActivity = lastActivityTimestamp[paneId] {
            if Date().timeIntervalSince(lastActivity) < threshold {
                return true
            }
        }

        // Also check CostTracker's time series for this terminal
        // This catches activity that may have been recorded before we started tracking
        if let tracker = costTracker.terminalTrackers[paneId],
           let lastDataPoint = tracker.timeSeries.last {
            if Date().timeIntervalSince(lastDataPoint.timestamp) < threshold {
                return true
            }
        }

        return false
    }
}

// MARK: - Session Identifiable Protocol
// ============================================================================
// Protocol for types that can have their status computed.
// Allows SessionStatusService to work with different session types.
// ============================================================================

/// Protocol for types that can be identified for status computation
@MainActor protocol SessionIdentifiable {
    /// The pane ID used for status tracking (may be nil if not yet assigned)
    var paneId: String? { get }

    /// Whether this session has a task assigned
    var hasTask: Bool { get }
}

// MARK: - SwiftUI Integration
// ============================================================================
// Extensions to make status colors and display convenient in SwiftUI
// ============================================================================

#if canImport(SwiftUI)
import SwiftUI

extension SessionStatus {
    /// Color for this status (for indicators, badges, etc.)
    var color: Color {
        switch self {
        case .blocked: return .orange
        case .thinking: return .purple
        case .active: return .green
        case .idle: return .yellow
        case .dormant: return .secondary
        }
    }

    /// Background color for cards/sections
    var backgroundColor: Color {
        color.opacity(0.15)
    }
}
#endif
