import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

// MARK: - Terminal Session Managing Protocol

/// Protocol for terminal session management, enabling dependency injection and testing
@MainActor
protocol TerminalSessionManaging: AnyObject {
    /// All active sessions
    var sessions: [TerminalSession] { get }

    /// Start a new session for a task or standalone terminal
    func startSession(
        for task: WorkTask?,
        paneId: String?,
        command: String?,
        workingDirectory: String?,
        workspaceId: UUID,
        worktreeBranch: String?,
        provider: AIProvider
    ) -> TerminalSession

    /// Get or create a session for a pane ID
    func session(forPaneId paneId: String, workingDirectory: String?, workspaceId: UUID) -> TerminalSession

    /// Get all sessions for a workspace
    func sessions(for workspaceId: UUID) -> [TerminalSession]

    /// Find a session by task
    func session(for task: WorkTask) -> TerminalSession?

    /// Stop a session by task
    func stopSession(for task: WorkTask)

    /// Stop a session directly
    func stopSession(_ session: TerminalSession)

    /// Stop a session by pane ID
    func stopSession(forPaneId paneId: String)

    /// Count of running sessions in a workspace
    func runningCount(for workspaceId: UUID) -> Int

    /// Whether there are any running sessions
    var hasRunningSessions: Bool { get }
}

// MARK: - Terminal Session Manager Environment Key

private struct TerminalSessionManagerKey: EnvironmentKey {
    @MainActor static let defaultValue = TerminalSessionManager.shared
}

extension EnvironmentValues {
    var terminalSessionManager: TerminalSessionManager {
        get { self[TerminalSessionManagerKey.self] }
        set { self[TerminalSessionManagerKey.self] = newValue }
    }
}

// MARK: - Terminal Session Manager

@MainActor
@Observable
final class TerminalSessionManager: TerminalSessionManaging {
    static let shared = TerminalSessionManager()

    var sessions: [TerminalSession] = []

    /// Internal initializer for singleton
    private init() {}

    /// Initializer for testing with pre-populated sessions
    init(sessions: [TerminalSession]) {
        self.sessions = sessions
    }

    /// Start a session for a task (or standalone with paneId), scoped to a workspace
    func startSession(for task: WorkTask?, paneId: String? = nil, command: String? = nil, workingDirectory: String? = nil, workspaceId: UUID, worktreeBranch: String? = nil, provider: AIProvider = .claude) -> TerminalSession {
        // Check if session already exists for this task
        if let task = task,
           let existing = sessions.first(where: { $0.taskId == task.persistentModelID }) {
            return existing
        }

        // Check if session already exists for this paneId
        if let paneId = paneId,
           let existing = sessions.first(where: { $0.paneId == paneId }) {
            return existing
        }

        let session = TerminalSession(task: task, paneId: paneId, command: command, workingDirectory: workingDirectory, workspaceId: workspaceId, worktreeBranch: worktreeBranch, provider: provider)
        sessions.append(session)
        return session
    }

    /// Get or create a session by paneId, scoped to a workspace
    func session(forPaneId paneId: String, workingDirectory: String? = nil, workspaceId: UUID) -> TerminalSession {
        if let existing = sessions.first(where: { $0.paneId == paneId }) {
            return existing
        }
        let session = TerminalSession(task: nil, paneId: paneId, command: nil, workingDirectory: workingDirectory, workspaceId: workspaceId)
        sessions.append(session)
        return session
    }

    /// Get sessions for a specific workspace
    func sessions(for workspaceId: UUID) -> [TerminalSession] {
        sessions.filter { $0.workspaceId == workspaceId }
    }

    /// Get running count for a specific workspace
    func runningCount(for workspaceId: UUID) -> Int {
        sessions(for: workspaceId).count
    }

    /// Group sessions by worktree branch for a specific workspace
    /// Returns a dictionary where keys are worktree names ("main" for nil) and values are session arrays
    func sessionsByWorktree(for workspaceId: UUID) -> [String: [TerminalSession]] {
        let workspaceSessions = sessions(for: workspaceId)
        return Dictionary(grouping: workspaceSessions) { $0.worktreeDisplayName }
    }

    func stopSession(for task: WorkTask) {
        let taskModelId = task.persistentModelID
        if let session = sessions.first(where: { $0.taskId == taskModelId }) {
            session.stopScreenshotCapture()
        }
        sessions.removeAll { $0.taskId == taskModelId }
    }

    func stopSession(_ session: TerminalSession) {
        session.stopScreenshotCapture()
        sessions.removeAll { $0.id == session.id }
    }

    func stopSession(forPaneId paneId: String) {
        if let session = sessions.first(where: { $0.paneId == paneId }) {
            session.stopScreenshotCapture()
            sessions.removeAll { $0.id == session.id }
        }
    }

    func session(for task: WorkTask) -> TerminalSession? {
        let taskModelId = task.persistentModelID
        return sessions.first { $0.taskId == taskModelId }
    }

    var hasRunningSessions: Bool {
        !sessions.isEmpty
    }

    var runningCount: Int {
        sessions.count
    }
}

// MARK: - Terminal Session
// ============================================================================
// TerminalSession represents a running terminal/agent in memory.
// It conforms to SessionIdentifiable for centralized status tracking.
//
// Status is NOT stored here - it's computed by SessionStatusService using:
// - paneId: Links to InboxService for permission blocking
// - taskId: Indicates if session has assigned work
// - CostTracker: Activity tracked separately via paneId
// ============================================================================

@MainActor
@Observable
final class TerminalSession: Identifiable, SessionIdentifiable {
    let id = UUID()
    let paneId: String?
    var taskId: PersistentIdentifier?
    let workspaceId: UUID  // Workspace this session belongs to
    var taskTitle: String
    let startedAt: Date
    var surfaceView: TerminalEmulator.SurfaceView?
    var isReady: Bool = false  // Terminal is ready to be displayed
    let initialCommand: String?

    /// Git worktree branch this session is operating in.
    /// nil means the session is in the main workspace (no worktree).
    var worktreeBranch: String?

    /// AI provider for this session (claude, codex, etc.)
    var provider: AIProvider

    /// Display name for the worktree (returns "main" if no worktree)
    var worktreeDisplayName: String {
        worktreeBranch ?? "main"
    }

    /// History of recent task titles (most recent first, max 3)
    /// Note: This is local-only, not synced to remote
    var taskHistory: [String] = []

    // Current and previous thumbnails for smooth crossfade
    var currentThumbnail: NSImage?
    var previousThumbnail: NSImage?
    var thumbnailGeneration: Int = 0  // Increments on each new screenshot

    private var screenshotTimer: Timer?

    // Offscreen window to host terminal view for screenshot capture
    // This allows bitmapImageRepForCachingDisplay to work even when
    // the terminal isn't displayed in the main UI
    private var offscreenWindow: NSWindow?

    // MARK: - SessionIdentifiable Conformance
    // Used by SessionStatusService to compute status

    /// Whether this session has a task assigned (for status computation)
    var hasTask: Bool { taskId != nil }

    /// Computed status from SessionStatusService (convenience accessor)
    var status: SessionStatus {
        SessionStatusService.shared.status(forPaneId: paneId, hasTask: hasTask)
    }

    init(task: WorkTask?, paneId: String? = nil, command: String? = nil, workingDirectory: String? = nil, workspaceId: UUID, worktreeBranch: String? = nil, provider: AIProvider = .claude) {
        self.paneId = paneId
        self.taskId = task?.persistentModelID
        self.workspaceId = workspaceId
        self.worktreeBranch = worktreeBranch
        self.provider = provider
        self.taskTitle = task?.title ?? "Terminal"
        self.startedAt = Date()
        self.initialCommand = command

        // Defer terminal creation to next run loop to avoid blocking UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Build surface configuration with working directory and initial command
            var config = TerminalEmulator.SurfaceConfiguration(workingDirectory: workingDirectory)
            // Use initialInput to send command at shell startup - Ghostty handles timing
            if let command = command {
                config.initialInput = command + "\n"
            }

            let surface = TerminalEmulator.App.shared.createSurface(config: config)
            self.surfaceView = surface

            // Create offscreen window to host terminal view for screenshot capture
            // This ensures terminalView.window != nil so bitmapImageRepForCachingDisplay works
            self.setupOffscreenWindow(for: surface)
            self.startScreenshotCapture()

            // Mark as ready after shell has time to initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isReady = true
            }
        }
    }

    private func setupOffscreenWindow(for surface: TerminalEmulator.SurfaceView) {
        // Create an offscreen window positioned outside visible area
        let windowSize = NSSize(width: 800, height: 600)
        let offscreenOrigin = NSPoint(x: -10000, y: -10000)

        let window = NSWindow(
            contentRect: NSRect(origin: offscreenOrigin, size: windowSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Configure window to be invisible but functional for rendering
        window.isReleasedWhenClosed = false
        window.level = .init(rawValue: Int(CGWindowLevelKey.desktopWindow.rawValue) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0  // Completely invisible - prevents window from showing during view transitions
        window.ignoresMouseEvents = true  // Cannot interact with the invisible window

        // Add the terminal view to the offscreen window
        let terminalView = surface
        terminalView.frame = NSRect(origin: .zero, size: windowSize)
        terminalView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(terminalView)

        // Order window but keep it invisible (off-screen position handles this)
        window.orderBack(nil)

        self.offscreenWindow = window
    }

    private func startScreenshotCapture() {
        // Capture initial screenshot after a short delay to let terminal render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureScreenshot()
        }

        // Set up periodic capture every 2 seconds
        screenshotTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureScreenshot()
            }
        }
    }

    func stopScreenshotCapture() {
        screenshotTimer?.invalidate()
        screenshotTimer = nil

        // Tear down the ghostty surface on a background thread to avoid blocking the main thread,
        // then remove the view and close the offscreen window.
        surfaceView?.teardownAsync()
        surfaceView?.removeFromSuperview()
        surfaceView = nil
        offscreenWindow?.close()
        offscreenWindow = nil

        // Notify SessionStatusService to clear tracking for this session
        if let paneId = paneId {
            SessionStatusService.shared.clearSession(paneId: paneId)
        }
    }

    func captureScreenshot() {
        guard let terminalView = surfaceView else { return }

        // If terminal view is not in a window, re-add it to the offscreen window
        // This can happen when the full terminal view was displayed then dismissed
        if terminalView.window == nil, let offscreenWindow = offscreenWindow {
            let windowSize = offscreenWindow.contentView?.bounds.size ?? NSSize(width: 800, height: 600)
            terminalView.frame = NSRect(origin: .zero, size: windowSize)
            terminalView.autoresizingMask = [.width, .height]
            offscreenWindow.contentView?.addSubview(terminalView)
        }

        // Can only capture when view is in a window
        guard terminalView.window != nil else { return }

        // Capture the terminal view as an image
        let bounds = terminalView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }

        guard let bitmapRep = terminalView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        terminalView.cacheDisplay(in: bounds, to: bitmapRep)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)

        // Move current to previous, set new as current
        previousThumbnail = currentThumbnail
        currentThumbnail = image
        thumbnailGeneration += 1
    }

    /// Assign a new task to this session, updating history
    func assignTask(_ task: WorkTask) {
        // Add current task to history if it exists
        if taskId != nil {
            taskHistory.insert(taskTitle, at: 0)
            // Keep only the last 3 tasks in history
            if taskHistory.count > 3 {
                taskHistory = Array(taskHistory.prefix(3))
            }
        }
        // Set new task
        taskId = task.persistentModelID
        taskTitle = task.title
    }

    /// Number of tasks waiting in queue (via TaskQueueService)
    var queueCount: Int {
        guard let paneId = paneId else { return 0 }
        return TaskQueueService.shared.queueCount(forTerminal: paneId)
    }

    nonisolated func cleanup() {
        // Called from deinit - use MainActor.assumeIsolated since deinit
        // happens on the main thread for MainActor-isolated classes
        MainActor.assumeIsolated {
            screenshotTimer?.invalidate()
            surfaceView?.teardownAsync()
            surfaceView?.removeFromSuperview()
            offscreenWindow?.close()
        }
    }

    deinit {
        cleanup()
    }
}

#endif
