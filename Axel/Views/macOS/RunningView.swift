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
        cleanupOffscreenWindow()

        // Notify SessionStatusService to clear tracking for this session
        if let paneId = paneId {
            SessionStatusService.shared.clearSession(paneId: paneId)
        }
    }

    private func cleanupOffscreenWindow() {
        // Remove terminal view from offscreen window and close it
        surfaceView?.removeFromSuperview()
        offscreenWindow?.close()
        offscreenWindow = nil
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
            surfaceView?.removeFromSuperview()
            offscreenWindow?.close()
        }
    }

    deinit {
        cleanup()
    }
}

// MARK: - Running List View (Middle Column)

// MARK: - Running List View (Middle Column)
// ============================================================================
// Displays terminal sessions grouped by status.
// Uses SessionStatusService for centralized status computation.
//
// Status groups (in display order):
// - Blocked: Waiting for permission (needs user attention)
// - Thinking: LLM actively generating (recent token activity)
// - Active: Has task, running but not currently generating
// - Idle: Has task but no recent activity
// - Dormant: No task assigned (available)
// ============================================================================

struct RunningListView: View {
    @Binding var selection: TerminalSession?
    var workspaceId: UUID? = nil
    let onRequestClose: (TerminalSession) -> Void
    @Environment(\.terminalSessionManager) private var sessionManager
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    // Centralized status service - replaces scattered status logic
    private let statusService = SessionStatusService.shared

    // Minimum item width for column calculation (doubled from 150)
    private let minItemWidth: CGFloat = 280

    // Track column count for keyboard navigation
    @State private var currentColumnCount: Int = 1

    /// Sessions filtered to this workspace (or all sessions if no workspace specified)
    private var workspaceSessions: [TerminalSession] {
        if let workspaceId {
            return sessionManager.sessions(for: workspaceId)
        }
        return sessionManager.sessions
    }

    /// Sessions grouped by status using SessionStatusService
    /// Returns array of (status, sessions) tuples in display order
    private var sessionsByStatus: [(status: SessionStatus, sessions: [TerminalSession])] {
        statusService.groupedByStatus(workspaceSessions)
    }

    /// All sessions in display order (for keyboard navigation)
    /// Ordered by status priority: blocked -> thinking -> active -> idle -> dormant
    private var allSessionsOrdered: [TerminalSession] {
        statusService.orderedByPriority(workspaceSessions)
    }

    /// Navigate selection using arrow keys
    private func navigateSelection(direction: NavigationDirection) {
        let sessions = allSessionsOrdered
        guard !sessions.isEmpty else { return }

        // If nothing selected, select first or last based on direction
        guard let current = selection,
              let currentIndex = sessions.firstIndex(where: { $0.id == current.id }) else {
            switch direction {
            case .down, .right:
                selection = sessions.first
            case .up, .left:
                selection = sessions.last
            }
            return
        }

        let cols = currentColumnCount
        var newIndex = currentIndex

        switch direction {
        case .up:
            newIndex = currentIndex - cols
        case .down:
            newIndex = currentIndex + cols
        case .left:
            if currentIndex > 0 {
                newIndex = currentIndex - 1
            }
        case .right:
            if currentIndex < sessions.count - 1 {
                newIndex = currentIndex + 1
            }
        }

        // Clamp to valid range
        newIndex = max(0, min(sessions.count - 1, newIndex))
        selection = sessions[newIndex]
    }

    enum NavigationDirection {
        case up, down, left, right
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Terminals")
                    .font(.title2.bold())
                Spacer()
                Text("\(workspaceSessions.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if workspaceSessions.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let columnCount = min(3, max(1, Int(geometry.size.width / minItemWidth)))
                    let spacing: CGFloat = 12
                    let totalSpacing = spacing * CGFloat(columnCount - 1) + 24 // 12px padding on each side
                    let itemWidth = (geometry.size.width - totalSpacing) / CGFloat(columnCount)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Render sections dynamically based on status groups
                            // SessionStatusService provides groups in priority order
                            ForEach(sessionsByStatus, id: \.status) { group in
                                TerminalSectionView(
                                    status: group.status,
                                    sessions: group.sessions,
                                    selection: $selection,
                                    columnCount: columnCount,
                                    itemWidth: itemWidth,
                                    spacing: spacing,
                                    onRequestClose: onRequestClose
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: columnCount) { _, newCount in
                        currentColumnCount = newCount
                    }
                    .onAppear {
                        currentColumnCount = columnCount
                        // Auto-select first session if none selected but sessions exist
                        if selection == nil, let firstSession = allSessionsOrdered.first {
                            selection = firstSession
                        }
                    }
                }
            }
        }
        .background(backgroundColor)
        .modifier(GridKeyboardNavigation(
            navigate: navigateSelection,
            isFocused: $isFocused
        ))
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(hex: "292F30")! : Color.white
    }

    private var emptyState: some View {
        EmptyStateView(
            image: "terminal",
            title: "No Terminals",
            description: "Start a task from Inbox or press ⌘T"
        )
    }
}

// MARK: - Keyboard Event Monitor

/// Manages NSEvent local monitoring for keyboard navigation
/// Uses a class to properly handle the event monitor lifecycle
private final class KeyboardNavigationMonitor {
    private var eventMonitor: Any?
    private let onNavigate: (RunningListView.NavigationDirection) -> Void

    init(navigate: @escaping (RunningListView.NavigationDirection) -> Void) {
        self.onNavigate = navigate
        setupMonitor()
    }

    deinit {
        removeMonitor()
    }

    private func setupMonitor() {
        // Use NSEvent local monitor to capture Cmd+arrow keys even when
        // the terminal view has first responder
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Only handle Cmd+arrow keys (without other modifiers like Shift)
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control) else {
                return event
            }

            switch event.keyCode {
            case 126: // Up arrow
                self.onNavigate(.up)
                return nil  // Consume the event
            case 125: // Down arrow
                self.onNavigate(.down)
                return nil
            case 123: // Left arrow
                self.onNavigate(.left)
                return nil
            case 124: // Right arrow
                self.onNavigate(.right)
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Grid Keyboard Navigation Modifier

private struct GridKeyboardNavigation: ViewModifier {
    let navigate: (RunningListView.NavigationDirection) -> Void
    var isFocused: FocusState<Bool>.Binding
    @State private var keyboardMonitor: KeyboardNavigationMonitor?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(isFocused)
            .focusEffectDisabled()
            .onAppear {
                keyboardMonitor = KeyboardNavigationMonitor(navigate: navigate)
            }
            .onDisappear {
                keyboardMonitor = nil
            }
    }
}

// MARK: - Terminal Section View
// ============================================================================
// Displays a group of terminal sessions with a status header.
// Takes SessionStatus for consistent styling from centralized service.
// ============================================================================

struct TerminalSectionView: View {
    /// The status this section represents (determines icon, color, title)
    let status: SessionStatus
    let sessions: [TerminalSession]
    @Binding var selection: TerminalSession?
    let columnCount: Int
    let itemWidth: CGFloat
    let spacing: CGFloat
    let onRequestClose: (TerminalSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header - uses status properties for consistent styling
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.color)

                Text(status.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(Capsule())
            }
            .padding(.leading, 4)

            // Sessions grid
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: columnCount),
                spacing: spacing
            ) {
                ForEach(sessions) { session in
                    TerminalMiniatureView(
                        session: session,
                        isSelected: selection?.id == session.id,
                        width: itemWidth
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = session
                    }
                    .contextMenu {
                        let installedTerminals = TerminalApp.installedApps
                        if let paneId = session.paneId, !installedTerminals.isEmpty {
                            Menu {
                                ForEach(installedTerminals) { terminal in
                                    Button {
                                        let axelPath = AxelSetupService.shared.executablePath
                                        terminal.open(withCommand: "\(axelPath) session join \(paneId)")
                                    } label: {
                                        Label(terminal.name, systemImage: terminal.iconName)
                                    }
                                }
                            } label: {
                                Label("Open in terminal", systemImage: "arrow.up.forward.app")
                            }
                        } else {
                            Label("Open in terminal", systemImage: "arrow.up.forward.app")
                                .disabled(true)
                        }

                        Button(role: .destructive) {
                            onRequestClose(session)
                        } label: {
                            Label("Kill session", systemImage: "xmark.circle.fill")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Terminal Miniature View

struct TerminalMiniatureView: View {
    let session: TerminalSession
    var isSelected: Bool = false
    var width: CGFloat = 280

    // Calculate preview height based on width to maintain 16:9 aspect ratio
    private var previewHeight: CGFloat {
        width * (9.0 / 16.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Terminal preview - dynamic height based on width for 16:9 ratio
            ZStack(alignment: .bottomTrailing) {
                // Previous thumbnail (stays visible as base layer)
                if let previous = session.previousThumbnail {
                    GeometryReader { geo in
                        Image(nsImage: previous)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    }
                    .clipped()
                }

                // Current thumbnail (fades in on top) - show top, crop bottom
                if let current = session.currentThumbnail {
                    GeometryReader { geo in
                        Image(nsImage: current)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    }
                    .clipped()
                    .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                    .id(session.thumbnailGeneration)
                } else {
                    // Placeholder while waiting for first screenshot
                    Color(red: 0x18/255.0, green: 0x26/255.0, blue: 0x2F/255.0)
                    VStack {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.orange)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.accentPurple : Color.clear, lineWidth: isSelected ? 5 : 0)
            )
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 0)
            .padding(12)

            // Worktree + histogram capsule (centered)
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                    Text(session.worktreeBranch ?? "no worktree")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)

                    if session.provider != .shell && session.provider != .custom {
                        Rectangle()
                            .fill(isSelected ? Color.white.opacity(0.6) : Color.secondary.opacity(0.3))
                            .frame(width: 1, height: 10)
                        TokenHistogramOverlay(paneId: session.paneId, foregroundColor: isSelected ? .white : .secondary)
                    }
                }
                .foregroundStyle(isSelected ? Color.white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentPurple : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.white.opacity(0.15) : Color.clear, lineWidth: isSelected ? 1 : 0)
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

}


// MARK: - Status Indicator
// ============================================================================
// Visual indicator showing session status with appropriate icon and animation.
// Used in terminal miniatures and other places where status needs display.
// ============================================================================

struct StatusIndicator: View {
    let status: SessionStatus
    @State private var isAnimating = false

    var body: some View {
        Group {
            switch status {
            case .thinking:
                // Pulsing brain icon when LLM is generating
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .opacity(isAnimating ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
                    .onAppear { isAnimating = true }
                    .onDisappear { isAnimating = false }

            case .blocked:
                // Attention-grabbing indicator for blocked state
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, options: .repeating)

            case .active:
                // Solid indicator for active (working but not generating)
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundStyle(status.color)

            case .idle:
                // Faded indicator for idle sessions
                Image(systemName: status.icon)
                    .font(.caption)
                    .foregroundStyle(status.color.opacity(0.7))

            case .dormant:
                // Minimal indicator for dormant sessions
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Terminal App Detection

/// Represents a terminal application that can be opened
struct TerminalApp: Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let iconName: String

    /// Check if this terminal is installed
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    /// Open this terminal with the given command
    func open(withCommand command: String) {
        // Escape backslashes first, then quotes for AppleScript
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        switch id {
        case "iterm2":
            // iTerm2 - use osascript for better reliability
            // Must capture the new window reference, otherwise current window points to old window
            let script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escapedCommand)"
                end tell
            end tell
            """
            runAppleScript(script)

        case "terminal":
            // Terminal.app AppleScript
            let script = """
            tell application "Terminal"
                activate
                do script "\(escapedCommand)"
            end tell
            """
            runAppleScript(script)

        case "warp":
            // Warp - open and use clipboard + paste for reliability
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let script = """
            tell application "Warp"
                activate
            end tell
            delay 0.3
            tell application "System Events"
                keystroke "v" using command down
                keystroke return
            end tell
            """
            runAppleScript(script)

        case "kitty":
            // Kitty - launch via command line
            if let kittyUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let kittyPath = kittyUrl.appendingPathComponent("Contents/MacOS/kitty").path
                let process = Process()
                process.executableURL = URL(fileURLWithPath: kittyPath)
                process.arguments = ["--single-instance", "-e", "bash", "-c", command]
                try? process.run()
            }

        case "alacritty":
            // Alacritty - launch via command line
            if let alacrittyUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let alacrittyPath = alacrittyUrl.appendingPathComponent("Contents/MacOS/alacritty").path
                let process = Process()
                process.executableURL = URL(fileURLWithPath: alacrittyPath)
                process.arguments = ["-e", "bash", "-c", command]
                try? process.run()
            }

        default:
            break
        }
    }

    private func runAppleScript(_ script: String) {
        // Run via osascript process asynchronously to avoid blocking main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let pipe = Pipe()
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let errorString = String(data: errorData, encoding: .utf8) {
                        print("[TerminalApp] osascript error: \(errorString)")
                    }
                }
            } catch {
                print("[TerminalApp] Failed to run osascript: \(error)")
            }
        }
    }

    /// All known terminal apps
    static let allApps: [TerminalApp] = [
        TerminalApp(id: "iterm2", name: "iTerm", bundleId: "com.googlecode.iterm2", iconName: "rectangle.topthird.inset.filled"),
        TerminalApp(id: "terminal", name: "Terminal", bundleId: "com.apple.Terminal", iconName: "terminal"),
        TerminalApp(id: "warp", name: "Warp", bundleId: "dev.warp.Warp-Stable", iconName: "bolt.horizontal"),
        TerminalApp(id: "kitty", name: "Kitty", bundleId: "net.kovidgoyal.kitty", iconName: "cat"),
        TerminalApp(id: "alacritty", name: "Alacritty", bundleId: "org.alacritty", iconName: "a.square"),
    ]

    /// Get installed terminal apps
    static var installedApps: [TerminalApp] {
        allApps.filter { $0.isInstalled }
    }
}

// MARK: - Agents Scene (Right Panel)

struct AgentsScene: View {
    let session: TerminalSession
    @Binding var selection: TerminalSession?
    let onRequestClose: (TerminalSession) -> Void
    @State private var installedTerminals: [TerminalApp] = []
    @State private var isHoveringPill = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Full terminal view
                terminalSurface
                    .id(session.id)

                // Floating glass pill toolbar
                TerminalGlassPill(
                    session: session,
                    installedTerminals: installedTerminals,
                    isHovering: $isHoveringPill,
                    onStop: { onRequestClose(session) }
                )
                .frame(maxWidth: geometry.size.width / 3)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        .background(backgroundColor)
        .onAppear {
            installedTerminals = TerminalApp.installedApps
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(hex: "292F30")! : Color.white
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let surfaceView = session.surfaceView {
            TerminalFullView(surfaceView: surfaceView)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 8)
                .padding(.bottom, 8)
                .padding(.trailing, 8)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 0)
        } else {
            ZStack {
                backgroundColor
                Text("Terminal not available")
                    .foregroundStyle(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 8)
            .padding(.bottom, 8)
            .padding(.trailing, 8)
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 0)
        }
    }

}

// MARK: - Floating Glass Pill Toolbar

struct TerminalGlassPill: View {
    let session: TerminalSession
    let installedTerminals: [TerminalApp]
    @Binding var isHovering: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left section: Task info
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.5), radius: 4)

                Text(session.taskTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)

            // Divider
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 20)

            // Right section: Actions
            HStack(spacing: 0) {
                // Open in external terminal
                if !installedTerminals.isEmpty, let paneId = session.paneId {
                    Menu {
                        ForEach(installedTerminals) { terminal in
                            Button {
                                let axelPath = AxelSetupService.shared.executablePath
                                terminal.open(withCommand: "\(axelPath) session join \(paneId)")
                            } label: {
                                Label(terminal.name, systemImage: terminal.iconName)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Stop button
                Button {
                    onStop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 4)
        }
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(
            GlassPillBackground()
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.1), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Glass Pill Background

struct GlassPillBackground: View {
    var body: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: NSViewRepresentableContext<Self>) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Terminal Full View

struct TerminalFullView: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView

    var body: some View {
        GeometryReader { geo in
            TerminalEmulator.SurfaceRepresentable(view: surfaceView, size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .onTapGesture {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
        }
        .onAppear {
            // Auto-focus the terminal when it appears (e.g., when selected via keyboard)
            focusTerminal(surfaceView: surfaceView, retryCount: 0)
        }
    }

    /// Attempts to focus the terminal, retrying if the window isn't ready yet
    private func focusTerminal(surfaceView: TerminalEmulator.SurfaceView, retryCount: Int) {
        let maxRetries = 5
        let delay = 0.05 // 50ms between retries

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = surfaceView.window {
                window.makeFirstResponder(surfaceView)
                surfaceView.focus()
            } else if retryCount < maxRetries {
                // Window not ready yet, retry
                focusTerminal(surfaceView: surfaceView, retryCount: retryCount + 1)
            }
        }
    }
}

// MARK: - Empty Running Selection

struct EmptyRunningSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Terminal Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a running task to view its terminal")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#endif

// MARK: - Token Histogram Overlay (Cross-platform)

struct TokenHistogramOverlay: View {
    let paneId: String?
    var foregroundColor: Color = .secondary
    @State private var costTracker = CostTracker.shared

    private var provider: AIProvider {
        guard let paneId = paneId else { return .claude }
        return costTracker.provider(forPaneId: paneId)
    }

    private var histogramValues: [Double] {
        guard let paneId = paneId else {
            return Array(repeating: 0.1, count: 12)
        }
        return costTracker.histogramValues(forTerminal: paneId)
    }

    private var totalTokens: Int {
        guard let paneId = paneId else { return 0 }
        return costTracker.currentSessionTokens(forTerminal: paneId)
    }

    var body: some View {
        HStack(spacing: 6) {
            AIProviderIcon(provider: provider, size: 14)
                .opacity(foregroundColor == .secondary ? 0.7 : 1.0)

            // Histogram bars
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 1)
                        .fill(foregroundColor == .secondary ? provider.color : foregroundColor)
                        .frame(width: 5, height: max(2, value * 10))
                }
            }
            .frame(height: 10)

            Text(formatTokenCount(totalTokens))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0)
        .foregroundStyle(foregroundColor)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

#if os(macOS)
// MARK: - Worker Picker Panel
// ============================================================================
// Two-pane panel for selecting an agent when running a task.
// Left pane: "New session" + all existing sessions
// Right pane: Worktree selection (if new) or session details (if session selected)
// ============================================================================

/// Selection state for the left pane
enum SessionPickerSelection: Equatable {
    case newSession
    case existingSession(TerminalSession)

    static func == (lhs: SessionPickerSelection, rhs: SessionPickerSelection) -> Bool {
        switch (lhs, rhs) {
        case (.newSession, .newSession):
            return true
        case let (.existingSession(l), .existingSession(r)):
            return l.id == r.id
        default:
            return false
        }
    }
}

/// Panel for selecting an available agent when running a task
struct WorkerPickerPanel: View {
    let workspaceId: UUID?
    let workspacePath: String?
    let onSelect: (TerminalSession?, AIProvider, String?) -> Void  // nil = create new agent, String? = grid name
    let onCreateWorktreeAgent: ((String, AIProvider, String?) -> Void)?  // Branch name for worktree agent, String? = grid name
    @Environment(\.dismiss) private var dismiss
    @Environment(\.terminalSessionManager) private var sessionManager
    @State private var selection: SessionPickerSelection = .newSession
    @State private var newWorktreeBranch: String = ""
    @State private var availableWorktrees: [WorktreeInfo] = []
    @State private var selectedWorktreeIndex: Int = 0  // 0 = main, then existing worktrees
    @State private var panes: [PaneInfo] = []
    @State private var grids: [GridInfo] = []
    @State private var selectedPaneIndex: Int = 0
    @State private var selectedGridIndex: Int = 0
    @State private var isGridModeSelected: Bool = false
    @FocusState private var isFocused: Bool
    @FocusState private var isWorktreeFieldFocused: Bool

    // Use centralized status service
    private let statusService = SessionStatusService.shared

    private var selectedPane: PaneInfo? {
        guard selectedPaneIndex < panes.count else { return nil }
        return panes[selectedPaneIndex]
    }

    private var selectedGrid: GridInfo? {
        guard selectedGridIndex < grids.count else { return nil }
        return grids[selectedGridIndex]
    }

    /// The grid name to pass (nil means single pane mode)
    private var selectedGridName: String? {
        guard isGridModeSelected, let grid = selectedGrid else { return nil }
        return grid.name
    }

    private var selectedProvider: AIProvider {
        selectedPane?.provider ?? .claude
    }

    /// All sessions for this workspace (sorted by start time, newest first)
    private var allSessions: [TerminalSession] {
        guard let workspaceId else { return [] }
        return sessionManager.sessions(for: workspaceId).sorted { $0.startedAt > $1.startedAt }
    }

    /// Total sessions count
    private var totalSessionsCount: Int {
        allSessions.count
    }

    init(workspaceId: UUID?, workspacePath: String? = nil, onSelect: @escaping (TerminalSession?, AIProvider, String?) -> Void, onCreateWorktreeAgent: ((String, AIProvider, String?) -> Void)? = nil) {
        self.workspaceId = workspaceId
        self.workspacePath = workspacePath
        self.onSelect = onSelect
        self.onCreateWorktreeAgent = onCreateWorktreeAgent
    }

    // Backwards compatibility initializer
    init(workspaceId: UUID?, onSelect: @escaping (TerminalSession?, AIProvider, String?) -> Void) {
        self.workspaceId = workspaceId
        self.workspacePath = nil
        self.onSelect = onSelect
        self.onCreateWorktreeAgent = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Assign to Agent")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Two-pane layout
            HStack(spacing: 0) {
                // Left pane: New session + all sessions
                sessionListPane
                    .frame(width: 200)

                Divider()

                // Right pane: Details based on selection
                detailPane
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 360)
        }
        .frame(width: 600)
        .background(.background)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
            // Load available worktrees, panes, and grids (only AI panes for assignment)
            if let path = workspacePath {
                Task {
                    async let worktreesTask = WorktreeService.shared.listWorktrees(in: path)
                    async let panesTask = LayoutService.shared.listPanes(in: path)
                    async let gridsTask = LayoutService.shared.listGrids(in: path)
                    availableWorktrees = await worktreesTask
                    panes = await panesTask.filter { $0.isAi }
                    grids = await gridsTask
                }
            }
        }
        .onKeyPress(.upArrow) {
            navigateUp()
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigateDown()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigateLeft()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateRight()
            return .handled
        }
        .onKeyPress(.return) {
            confirmSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Left Pane: Session List

    private var sessionListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sessions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 2) {
                    // New session option
                    newSessionRow

                    if !allSessions.isEmpty {
                        Divider()
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                    }

                    // All existing sessions
                    ForEach(allSessions) { session in
                        sessionRow(for: session)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .background(Color.primary.opacity(0.03))
    }

    private var newSessionRow: some View {
        let isSelected = selection == .newSession

        return Button {
            selection = .newSession
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : Color.green)

                Text("New session")
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sessionRow(for session: TerminalSession) -> some View {
        let isSelected = selection == .existingSession(session)
        let status = session.status

        Button {
            selection = .existingSession(session)
        } label: {
            HStack(spacing: 8) {
                // Status indicator
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    // Session name / current task
                    Text(session.taskTitle)
                        .font(.body)
                        .lineLimit(1)

                    // Worktree badge
                    HStack(spacing: 4) {
                        Image(systemName: session.worktreeBranch == nil ? "folder" : "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(session.worktreeDisplayName)
                            .font(.caption2)
                    }
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                }

                Spacer()

                // Queue count if any
                if session.queueCount > 0 {
                    Text("\(session.queueCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.2) : Color.orange.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Right Pane: Detail View

    private var detailPane: some View {
        VStack(spacing: 0) {
            switch selection {
            case .newSession:
                newSessionDetailPane
            case .existingSession(let session):
                sessionDetailPane(for: session)
            }
        }
    }

    // MARK: - New Session Detail Pane

    private var newSessionDetailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "plus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("New Session")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Layout selection - panes on left, grids on right
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Layout")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        if panes.isEmpty && grids.isEmpty {
                            Text("Loading...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: 16) {
                                // Panes on the left
                                HStack(spacing: 8) {
                                    ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                                        CompactPaneChip(
                                            pane: pane,
                                            isSelected: !isGridModeSelected && index == selectedPaneIndex,
                                            isFocused: !isGridModeSelected
                                        )
                                        .onTapGesture {
                                            selectedPaneIndex = index
                                            isGridModeSelected = false
                                        }
                                    }
                                }

                                // Separator and grid visualizations
                                if !grids.isEmpty {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 1)
                                        .frame(height: 40)

                                    // Grid visualizations on the right
                                    HStack(spacing: 12) {
                                        ForEach(Array(grids.enumerated()), id: \.element.id) { index, grid in
                                            GridVisualization(
                                                grid: grid,
                                                isSelected: isGridModeSelected && (grids.count == 1 || index == selectedGridIndex),
                                                isFocused: isGridModeSelected
                                            )
                                            .onTapGesture {
                                                selectedGridIndex = index
                                                isGridModeSelected = true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Worktree selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select worktree")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        // Main worktree option
                        worktreeOption(name: "main", isMain: true, index: 0)

                        // Existing worktrees
                        ForEach(Array(availableWorktrees.filter { !$0.isMain }.enumerated()), id: \.element.id) { index, worktree in
                            worktreeOption(name: worktree.displayName, isMain: false, index: index + 1)
                        }
                    }

                    Divider()

                    // Create new worktree
                    if onCreateWorktreeAgent != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Or create new worktree")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            HStack {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.body)
                                    .foregroundStyle(.accentPurple)
                                    .frame(width: 24)

                                TextField("Branch name (e.g., feat-auth)", text: $newWorktreeBranch)
                                    .textFieldStyle(.plain)
                                    .font(.body)
                                    .focused($isWorktreeFieldFocused)
                                    .onSubmit {
                                        if !newWorktreeBranch.isEmpty {
                                            createWorktreeAgent()
                                        }
                                    }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentPurple.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Action button
            HStack {
                Spacer()
                Button {
                    if !newWorktreeBranch.isEmpty {
                        createWorktreeAgent()
                    } else if selectedWorktreeIndex == 0 {
                        // Main worktree - create new session
                        onSelect(nil, selectedProvider, selectedGridName)
                        dismiss()
                    } else {
                        // Existing worktree - create worktree agent
                        let worktrees = availableWorktrees.filter { !$0.isMain }
                        if selectedWorktreeIndex - 1 < worktrees.count {
                            onCreateWorktreeAgent?(worktrees[selectedWorktreeIndex - 1].displayName, selectedProvider, selectedGridName)
                            dismiss()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption)
                        Text(newWorktreeBranch.isEmpty ? "Create Session" : "Create Worktree")
                            .font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func worktreeOption(name: String, isMain: Bool, index: Int) -> some View {
        let isSelected = selectedWorktreeIndex == index && newWorktreeBranch.isEmpty

        Button {
            selectedWorktreeIndex = index
            newWorktreeBranch = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? .green : .secondary)

                Image(systemName: isMain ? "folder.fill" : "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(isMain ? .orange : .accentPurple)

                Text(name)
                    .font(.body)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.green.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Existing Session Detail Pane

    private func sessionDetailPane(for session: TerminalSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with session info
            HStack {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 8, height: 8)
                Text(session.taskTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(session.status.label)
                    .font(.caption)
                    .foregroundStyle(session.status.color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Session info
                    VStack(alignment: .leading, spacing: 12) {
                        // Worktree
                        HStack(spacing: 8) {
                            Image(systemName: session.worktreeBranch == nil ? "folder.fill" : "arrow.triangle.branch")
                                .font(.caption)
                                .foregroundStyle(session.worktreeBranch == nil ? .orange : .accentPurple)
                                .frame(width: 20)
                            Text("Worktree:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(session.worktreeDisplayName)
                                .font(.subheadline.weight(.medium))
                        }

                        // Started at
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Running:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(session.startedAt, style: .relative)
                                .font(.subheadline)
                        }

                        // Queue count
                        if session.queueCount > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "list.bullet")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: 20)
                                Text("Queued:")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("\(session.queueCount) task\(session.queueCount == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    // Current task (if running)
                    if session.hasTask {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current Task")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Image(systemName: "play.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(.green)
                                Text(session.taskTitle)
                                    .font(.body)
                                    .lineLimit(2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.green.opacity(0.1))
                            )
                        }
                    }

                    // Task history
                    if !session.taskHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Tasks")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            VStack(spacing: 6) {
                                ForEach(session.taskHistory.prefix(3), id: \.self) { taskTitle in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                        Text(taskTitle)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                    }

                    // Thumbnail preview
                    if let thumbnail = session.currentThumbnail {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            // Action button
            HStack {
                Spacer()
                Button {
                    onSelect(session, selectedProvider, nil)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: session.hasTask ? "plus.circle" : "play.fill")
                            .font(.caption)
                        Text(session.hasTask ? "Add to Queue" : "Run")
                            .font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(session.hasTask ? Color.orange : Color.green)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    // MARK: - Navigation

    private func navigateUp() {
        switch selection {
        case .newSession:
            // Already at top
            break
        case .existingSession(let session):
            if let index = allSessions.firstIndex(where: { $0.id == session.id }) {
                if index == 0 {
                    selection = .newSession
                } else {
                    selection = .existingSession(allSessions[index - 1])
                }
            }
        }
    }

    private func navigateDown() {
        switch selection {
        case .newSession:
            if let first = allSessions.first {
                selection = .existingSession(first)
            }
        case .existingSession(let session):
            if let index = allSessions.firstIndex(where: { $0.id == session.id }),
               index < allSessions.count - 1 {
                selection = .existingSession(allSessions[index + 1])
            }
        }
    }

    private func navigateLeft() {
        // Only cycle panes/grids when "New Session" is selected
        guard case .newSession = selection else { return }
        let totalItems = panes.count + grids.count
        guard totalItems > 0 else { return }

        // Calculate current position across panes and grids
        let currentPosition = isGridModeSelected ? panes.count + selectedGridIndex : selectedPaneIndex

        // Move left (with wrap around)
        let newPosition = currentPosition > 0 ? currentPosition - 1 : totalItems - 1

        // Update selection based on new position
        if newPosition < panes.count {
            isGridModeSelected = false
            selectedPaneIndex = newPosition
        } else {
            isGridModeSelected = true
            selectedGridIndex = newPosition - panes.count
        }
    }

    private func navigateRight() {
        // Only cycle panes/grids when "New Session" is selected
        guard case .newSession = selection else { return }
        let totalItems = panes.count + grids.count
        guard totalItems > 0 else { return }

        // Calculate current position across panes and grids
        let currentPosition = isGridModeSelected ? panes.count + selectedGridIndex : selectedPaneIndex

        // Move right (with wrap around)
        let newPosition = currentPosition < totalItems - 1 ? currentPosition + 1 : 0

        // Update selection based on new position
        if newPosition < panes.count {
            isGridModeSelected = false
            selectedPaneIndex = newPosition
        } else {
            isGridModeSelected = true
            selectedGridIndex = newPosition - panes.count
        }
    }

    private func confirmSelection() {
        switch selection {
        case .newSession:
            if !newWorktreeBranch.isEmpty {
                createWorktreeAgent()
            } else if selectedWorktreeIndex == 0 {
                onSelect(nil, selectedProvider, selectedGridName)
                dismiss()
            } else {
                let worktrees = availableWorktrees.filter { !$0.isMain }
                if selectedWorktreeIndex - 1 < worktrees.count {
                    onCreateWorktreeAgent?(worktrees[selectedWorktreeIndex - 1].displayName, selectedProvider, selectedGridName)
                    dismiss()
                }
            }
        case .existingSession(let session):
            onSelect(session, selectedProvider, nil)
            dismiss()
        }
    }

    private func createWorktreeAgent() {
        let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        onCreateWorktreeAgent?(branch, selectedProvider, selectedGridName)
        dismiss()
    }
}

// NOTE: WorkerStatus enum removed - now using SessionStatus from SessionStatusService
// This provides consistent status across all UI components

/// Row displaying a worker in the picker panel
struct WorkerPickerRow: View {
    let session: TerminalSession
    var status: SessionStatus = .active
    var isSelected: Bool = false

    /// Label for the action button based on terminal state
    var actionLabel: String {
        session.hasTask ? "Add to Queue" : "Run"
    }

    /// Subtitle showing queue count if any tasks are queued
    var queueSubtitle: String? {
        let count = session.queueCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 task queued" : "\(count) tasks queued"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0x18/255.0, green: 0x26/255.0, blue: 0x2F/255.0))
                    .frame(width: 60, height: 40)

                if let thumbnail = session.currentThumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "terminal")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                // Current task / status
                HStack(spacing: 6) {
                    Image(systemName: status.icon)
                        .font(.caption2)
                        .foregroundStyle(status.color)
                    Text(session.taskTitle)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }

                // Queue count (if any tasks queued)
                if let queueInfo = queueSubtitle {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                        Text(queueInfo)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                // Task history (last 3 tasks)
                else if !session.taskHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(session.taskHistory.prefix(3), id: \.self) { taskTitle in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                Text(taskTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    // Show running time if no history
                    Text("Running for \(session.startedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Status badge (shows "Add to Queue" or status)
            VStack(alignment: .trailing, spacing: 4) {
                if session.hasTask {
                    // Show "Add to Queue" for busy terminals
                    Text("Add to Queue")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    // Show "Run" for idle terminals
                    Text("Run")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15))
                        .clipShape(Capsule())
                }

                // Status badge below action
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(status.color.opacity(0.8))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
        )
    }
}

// MARK: - Floating Terminal Miniature

/// Floating miniature that appears in bottom-right when a new terminal launches
struct FloatingTerminalMiniature: View {
    let session: TerminalSession
    let onDismiss: () -> Void
    let onTap: () -> Void
    @State private var isVisible = true

    var body: some View {
        if isVisible {
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .padding(.top, 4)

                Button {
                    onTap()
                } label: {
                    VStack(spacing: 0) {
                        TerminalMiniatureView(session: session, width: 280)

                        HStack {
                            Image(systemName: "terminal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("New agent started")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text("Click to view")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.03))
                    }
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .frame(width: 280)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
            .onAppear {
                // Auto-dismiss after 4.5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isVisible = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        onDismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Pane Info (from axel CLI)

/// Pane configuration from AXEL.md via axel CLI
struct PaneInfo: Codable, Identifiable, Equatable {
    let type: String
    let name: String
    let color: String?
    let isAi: Bool

    var id: String { type }

    enum CodingKeys: String, CodingKey {
        case type, name, color
        case isAi = "is_ai"
    }

    /// Convert to AIProvider for compatibility
    var provider: AIProvider {
        AIProvider(shellType: type)
    }

    /// Get SwiftUI color from pane color name
    var swiftUIColor: Color {
        guard let colorName = color else { return .gray }
        switch colorName {
        case "orange": return .orange
        case "green": return .green
        case "blue": return .blue
        case "purple": return .accentPurple
        case "yellow": return .yellow
        case "red": return .red
        case "gray", "grey": return .gray
        default: return .gray
        }
    }
}

/// Grid cell information from axel CLI
struct GridCellInfo: Codable, Equatable {
    let paneType: String
    let col: Int
    let row: Int
    let width: Int?
    let height: Int?
    let color: String?

    enum CodingKeys: String, CodingKey {
        case paneType = "pane_type"
        case col, row, width, height, color
    }

    /// Get the color for this cell, falling back to a default
    var swiftUIColor: Color {
        guard let colorName = color else { return .gray }
        switch colorName.lowercased() {
        case "purple": return .accentPurple
        case "yellow": return .yellow
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "gray", "grey": return .gray
        default: return .gray
        }
    }
}

/// Grid layout information from axel CLI
struct GridInfo: Codable, Identifiable, Equatable {
    let name: String
    let type: String  // tmux, tmux_cc, shell
    let paneCount: Int
    let cells: [GridCellInfo]

    var id: String { name }

    var displayName: String {
        name == "default" ? "Default" : name.capitalized
    }

    var typeLabel: String {
        switch type {
        case "tmux_cc": return "iTerm2"
        case "shell": return "No tmux"
        default: return "tmux"
        }
    }

    /// Number of columns in this grid
    var columnCount: Int {
        (cells.map(\.col).max() ?? 0) + 1
    }

    /// Number of rows in this grid
    var rowCount: Int {
        (cells.map(\.row).max() ?? 0) + 1
    }

    /// Get cells organized by column
    var cellsByColumn: [[GridCellInfo]] {
        var columns: [[GridCellInfo]] = Array(repeating: [], count: columnCount)
        for cell in cells {
            if cell.col < columns.count {
                columns[cell.col].append(cell)
            }
        }
        // Sort each column by row
        return columns.map { $0.sorted { $0.row < $1.row } }
    }

    enum CodingKeys: String, CodingKey {
        case name, type, cells
        case paneCount = "pane_count"
    }
}

/// Combined layout output from axel CLI
struct LayoutOutput: Codable {
    let panes: [PaneInfo]
    let grids: [GridInfo]
}

// MARK: - Layout Service

/// Service to fetch layout configurations from axel CLI
@MainActor
final class LayoutService {
    static let shared = LayoutService()
    private init() {}

    /// Cached layout output to avoid redundant CLI calls
    private var cachedLayout: (path: String, output: LayoutOutput)?

    /// Fetch layout from axel CLI (cached)
    private func fetchLayout(in workspacePath: String) async -> LayoutOutput? {
        // Return cached if same path
        if let cached = cachedLayout, cached.path == workspacePath {
            return cached.output
        }

        let axelPath = AxelSetupService.shared.executablePath
        let manifestPath = (workspacePath as NSString).appendingPathComponent("AXEL.md")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [axelPath, "layout", "ls", "--json", "-m", manifestPath]
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let layout = try JSONDecoder().decode(LayoutOutput.self, from: data)
            cachedLayout = (workspacePath, layout)
            return layout
        } catch {
            print("[LayoutService] Failed to fetch layout: \(error)")
            return nil
        }
    }

    /// Clear cached layout (call when AXEL.md changes)
    func clearCache() {
        cachedLayout = nil
    }

    /// Fetch panes from AXEL.md via axel CLI
    func listPanes(in workspacePath: String) async -> [PaneInfo] {
        if let layout = await fetchLayout(in: workspacePath) {
            return layout.panes
        }
        // Return default panes as fallback
        return [
            PaneInfo(type: "claude", name: "Claude", color: "orange", isAi: true),
            PaneInfo(type: "codex", name: "Codex", color: "green", isAi: true),
            PaneInfo(type: "shell", name: "Shell", color: "gray", isAi: false)
        ]
    }

    /// Fetch grids from AXEL.md via axel CLI
    func listGrids(in workspacePath: String) async -> [GridInfo] {
        if let layout = await fetchLayout(in: workspacePath) {
            return layout.grids
        }
        // Return default grid as fallback
        return [GridInfo(
            name: "default",
            type: "tmux",
            paneCount: 2,
            cells: [
                GridCellInfo(paneType: "claude", col: 0, row: 0, width: 50, height: nil, color: "orange"),
                GridCellInfo(paneType: "shell", col: 1, row: 0, width: 50, height: nil, color: "gray")
            ]
        )]
    }
}

// MARK: - New Terminal Sheet

/// Sheet for creating a new terminal with worktree and shell selection
/// Supports keyboard navigation: arrow keys to move, Enter to confirm, Escape to cancel
struct NewTerminalSheet: View {
    let workspacePath: String
    let onCreateTerminal: (String?, AIProvider, String?) -> Void  // branch name (nil = main), provider, grid name (nil = default)
    @Environment(\.dismiss) private var dismiss

    @State private var worktrees: [WorktreeInfo] = []
    @State private var panes: [PaneInfo] = []
    @State private var grids: [GridInfo] = []
    @State private var selectedWorktreeIndex: Int = 0
    @State private var selectedPaneIndex: Int = 0
    @State private var selectedGridIndex: Int = 0
    @State private var focusedRow: Int = 0  // 0 = worktrees, 1 = layout, 2 = new branch input
    @State private var isGridModeSelected: Bool = false  // false = pane mode, true = grid mode
    @State private var isLoading = true
    @State private var newBranchName: String = ""
    @FocusState private var isNewBranchFieldFocused: Bool

    /// Whether the "New worktree" option is selected (last index after worktrees)
    private var isNewWorktreeSelected: Bool {
        selectedWorktreeIndex == worktrees.count
    }

    private var selectedWorktree: WorktreeInfo? {
        guard selectedWorktreeIndex < worktrees.count else { return nil }
        return worktrees[selectedWorktreeIndex]
    }

    /// The branch name to use - either from selected worktree or new branch input
    private var selectedBranchName: String? {
        if isNewWorktreeSelected {
            return newBranchName.isEmpty ? nil : newBranchName
        }
        guard let worktree = selectedWorktree else { return nil }
        return worktree.isMain ? nil : worktree.displayName
    }

    private var selectedPane: PaneInfo? {
        guard selectedPaneIndex < panes.count else { return nil }
        return panes[selectedPaneIndex]
    }

    private var selectedGrid: GridInfo? {
        guard selectedGridIndex < grids.count else { return nil }
        return grids[selectedGridIndex]
    }

    /// The grid name to pass (nil means single pane mode)
    private var selectedGridName: String? {
        // Only return grid name when user has selected grid mode
        guard isGridModeSelected, let grid = selectedGrid else { return nil }
        return grid.name
    }

    /// Whether the Create button should be disabled
    private var cannotConfirm: Bool {
        // For new worktree, require a branch name
        if isNewWorktreeSelected && newBranchName.isEmpty { return true }
        // Either a pane or a grid must be selected
        if isGridModeSelected {
            return selectedGrid == nil
        } else {
            return selectedPane == nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                VStack(spacing: 24) {
                    // Worktree selection
                    VStack(spacing: 8) {
                        Label("Worktree", systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(Array(worktrees.enumerated()), id: \.element.id) { index, worktree in
                                CompactWorktreeChip(
                                    worktree: worktree,
                                    isSelected: index == selectedWorktreeIndex && !isNewWorktreeSelected,
                                    isFocused: focusedRow == 0
                                )
                                .onTapGesture {
                                    selectedWorktreeIndex = index
                                    focusedRow = 0
                                    isNewBranchFieldFocused = false
                                }
                            }

                            // "New worktree" option
                            NewWorktreeChip(
                                isSelected: isNewWorktreeSelected,
                                isFocused: focusedRow == 0 || focusedRow == 2
                            )
                            .onTapGesture {
                                selectedWorktreeIndex = worktrees.count
                                focusedRow = 2
                                isNewBranchFieldFocused = true
                            }
                        }

                        // New branch name input (shown when "New worktree" is selected)
                        if isNewWorktreeSelected {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                TextField("Branch name (e.g., feat/auth)", text: $newBranchName)
                                    .textFieldStyle(.plain)
                                    .focused($isNewBranchFieldFocused)
                                    .onSubmit {
                                        confirmSelection()
                                    }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(focusedRow == 2 ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                            .frame(maxWidth: 300)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -8)),
                                removal: .scale(scale: 0.9, anchor: .top).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNewWorktreeSelected)

                    // Layout selection - panes on left, grids on right
                    VStack(spacing: 8) {
                        Label("Layout", systemImage: "rectangle.split.2x1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            // Panes on the left
                            HStack(spacing: 8) {
                                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                                    CompactPaneChip(
                                        pane: pane,
                                        isSelected: !isGridModeSelected && index == selectedPaneIndex,
                                        isFocused: focusedRow == 1 && !isGridModeSelected
                                    )
                                    .onTapGesture {
                                        selectedPaneIndex = index
                                        isGridModeSelected = false
                                        focusedRow = 1
                                    }
                                }
                            }

                            // Separator and grid visualizations (always show)
                            if !grids.isEmpty {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 1)
                                    .frame(height: 40)

                                // Grid visualizations on the right
                                HStack(spacing: 12) {
                                    ForEach(Array(grids.enumerated()), id: \.element.id) { index, grid in
                                        GridVisualization(
                                            grid: grid,
                                            isSelected: isGridModeSelected && (grids.count == 1 || index == selectedGridIndex),
                                            isFocused: focusedRow == 1 && isGridModeSelected
                                        )
                                        .onTapGesture {
                                            selectedGridIndex = index
                                            isGridModeSelected = true
                                            focusedRow = 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Divider()

            // Action buttons
            HStack {
                Text("↑↓ row  ←→ select  ⏎ create  esc cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    confirmSelection()
                } label: {
                    Text("Create")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cannotConfirm)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(height: 56)
        }
        .frame(width: 1000, height: isNewWorktreeSelected ? 420 : 380)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNewWorktreeSelected)
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(
            onUp: { moveRow(-1) },
            onDown: { moveRow(1) },
            onLeft: { moveSelection(-1) },
            onRight: { moveSelection(1) },
            onEnter: { confirmSelection() },
            onEscape: { dismiss() }
        )
        .task {
            async let worktreesTask = WorktreeService.shared.listWorktrees(in: workspacePath)
            async let panesTask = LayoutService.shared.listPanes(in: workspacePath)
            async let gridsTask = LayoutService.shared.listGrids(in: workspacePath)

            worktrees = await worktreesTask
            panes = await panesTask.filter { $0.isAi }  // Only show AI panes
            grids = await gridsTask
            isLoading = false
        }
    }

    private func moveRow(_ delta: Int) {
        let oldRow = focusedRow
        // Row 0 = worktrees, Row 1 = panes, Row 2 = new branch input (only when new worktree selected)
        if isNewWorktreeSelected {
            // When new worktree is selected, allow moving to row 2 (input field)
            if delta > 0 && focusedRow == 0 {
                focusedRow = 2  // Go to input field
                isNewBranchFieldFocused = true
            } else if delta > 0 && focusedRow == 2 {
                focusedRow = 1  // Go to panes
                isNewBranchFieldFocused = false
            } else if delta < 0 && focusedRow == 1 {
                focusedRow = 2  // Go back to input field
                isNewBranchFieldFocused = true
            } else if delta < 0 && focusedRow == 2 {
                focusedRow = 0  // Go back to worktrees
                isNewBranchFieldFocused = false
            }
        } else {
            focusedRow = max(0, min(1, focusedRow + delta))
            isNewBranchFieldFocused = false
        }
    }

    private func moveSelection(_ delta: Int) {
        if focusedRow == 0 {
            let newIndex = selectedWorktreeIndex + delta
            // Include the "New worktree" option (at index worktrees.count)
            selectedWorktreeIndex = max(0, min(worktrees.count, newIndex))
            // If we selected "New worktree", focus the text field
            if isNewWorktreeSelected {
                focusedRow = 2
                isNewBranchFieldFocused = true
            }
        } else if focusedRow == 1 {
            // Row 1 has both panes and grids
            // Total items = panes.count + grids.count
            let totalItems = panes.count + grids.count

            // Current position depends on whether we're in grid mode or pane mode
            let currentPosition: Int
            if isGridModeSelected {
                currentPosition = panes.count + selectedGridIndex
            } else {
                currentPosition = selectedPaneIndex
            }
            let newPosition = max(0, min(totalItems - 1, currentPosition + delta))

            if newPosition < panes.count {
                // Moving to pane
                selectedPaneIndex = newPosition
                isGridModeSelected = false
            } else {
                // Moving to grid
                selectedGridIndex = newPosition - panes.count
                isGridModeSelected = true
            }
        }
        // Row 2 (input field) doesn't have left/right selection
    }

    private func confirmSelection() {
        // For new worktree, require a branch name
        if isNewWorktreeSelected && newBranchName.isEmpty { return }

        if isGridModeSelected, let grid = selectedGrid {
            // Grid mode - launch the full grid
            // Use the first pane's provider for tracking, or default to .claude
            let provider = panes.first?.provider ?? .claude
            onCreateTerminal(selectedBranchName, provider, grid.name)
        } else if let pane = selectedPane {
            // Pane mode - launch single pane
            onCreateTerminal(selectedBranchName, pane.provider, nil)
        }
        dismiss()
    }
}

// MARK: - Keyboard Navigation Modifier

/// View modifier that adds keyboard navigation support
struct KeyboardNavigationModifier: ViewModifier {
    let onUp: () -> Void
    let onDown: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) { onUp(); return .handled }
            .onKeyPress(.downArrow) { onDown(); return .handled }
            .onKeyPress(.leftArrow) { onLeft(); return .handled }
            .onKeyPress(.rightArrow) { onRight(); return .handled }
            .onKeyPress(.return) { onEnter(); return .handled }
            .onKeyPress(.escape) { onEscape(); return .handled }
    }
}

extension View {
    func keyboardNavigation(
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void,
        onLeft: @escaping () -> Void,
        onRight: @escaping () -> Void,
        onEnter: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardNavigationModifier(
            onUp: onUp,
            onDown: onDown,
            onLeft: onLeft,
            onRight: onRight,
            onEnter: onEnter,
            onEscape: onEscape
        ))
    }
}

// MARK: - Compact Worktree Chip

/// Compact chip with icon on top and small label beneath
struct CompactWorktreeChip: View {
    let worktree: WorktreeInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: worktree.isMain ? "folder.fill" : "arrow.triangle.branch")
                .font(.system(size: 36))
                .foregroundStyle(worktree.isMain ? .orange : .accentPurple)

            Text(worktree.displayName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - New Worktree Chip

/// Chip for creating a new worktree with a custom branch name
struct NewWorktreeChip: View {
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("New")
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - Compact Pane Chip

/// Compact chip with icon on top and small label beneath
struct CompactPaneChip: View {
    let pane: PaneInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return pane.swiftUIColor
        } else if isSelected {
            return pane.swiftUIColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if pane.isAi {
                    AIProviderIcon(provider: pane.provider, size: 40)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(pane.swiftUIColor)
                }
            }
            .frame(height: 50)  // Match grid visualization height

            Text(pane.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? pane.swiftUIColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - Grid Visualization

/// Visual representation of a grid layout (same size as CompactPaneChip: 112x104)
struct GridVisualization: View {
    let grid: GridInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Grid visualization - larger to fill the cell
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(grid.cellsByColumn.enumerated()), id: \.offset) { colIndex, columnCells in
                    let colWidth = columnCells.first?.width ?? (100 / grid.columnCount)

                    VStack(spacing: 3) {
                        ForEach(Array(columnCells.enumerated()), id: \.offset) { rowIndex, cell in
                            // Calculate height as proportion of total column height (47 = 50 - 3 spacing)
                            let totalHeight: CGFloat = 47
                            let spacing: CGFloat = CGFloat(columnCells.count - 1) * 3
                            let availableHeight = totalHeight - spacing
                            let rowHeight = cell.height ?? (100 / columnCells.count)
                            let cellHeight = availableHeight * CGFloat(rowHeight) / 100

                            RoundedRectangle(cornerRadius: 4)
                                .fill(cell.swiftUIColor.opacity(isSelected ? 0.7 : 0.4))
                                .frame(
                                    width: CGFloat(colWidth) * 0.8,
                                    height: cellHeight
                                )
                        }
                    }
                }
            }
            .frame(width: 80, height: 50)

            Text(grid.displayName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}
#endif
