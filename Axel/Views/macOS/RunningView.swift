import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

// MARK: - Terminal Session Manager Environment Key

private struct TerminalSessionManagerKey: EnvironmentKey {
    static let defaultValue = TerminalSessionManager.shared
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
final class TerminalSessionManager {
    static let shared = TerminalSessionManager()

    var sessions: [TerminalSession] = []

    private init() {}

    /// Start a session for a task (or standalone with paneId), scoped to a workspace
    func startSession(for task: WorkTask?, paneId: String? = nil, command: String? = nil, workingDirectory: String? = nil, workspaceId: UUID) -> TerminalSession {
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

        let session = TerminalSession(task: task, paneId: paneId, command: command, workingDirectory: workingDirectory, workspaceId: workspaceId)
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

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let paneId: String?
    let taskId: PersistentIdentifier?
    let workspaceId: UUID  // Workspace this session belongs to
    let taskTitle: String
    let startedAt: Date
    var surfaceView: TerminalEmulator.SurfaceView?
    var isReady: Bool = false  // Terminal is ready to be displayed
    let initialCommand: String?

    // Current and previous thumbnails for smooth crossfade
    var currentThumbnail: NSImage?
    var previousThumbnail: NSImage?
    var thumbnailGeneration: Int = 0  // Increments on each new screenshot

    private var screenshotTimer: Timer?

    // Offscreen window to host terminal view for screenshot capture
    // This allows bitmapImageRepForCachingDisplay to work even when
    // the terminal isn't displayed in the main UI
    private var offscreenWindow: NSWindow?

    init(task: WorkTask?, paneId: String? = nil, command: String? = nil, workingDirectory: String? = nil, workspaceId: UUID) {
        self.paneId = paneId
        self.taskId = task?.persistentModelID
        self.workspaceId = workspaceId
        self.taskTitle = task?.title ?? "Terminal"
        self.startedAt = Date()
        self.initialCommand = command

        // Defer terminal creation to next run loop to avoid blocking UI
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let surface = TerminalEmulator.App.shared.createSurface(
                config: TerminalEmulator.SurfaceConfiguration(workingDirectory: workingDirectory)
            )
            self.surfaceView = surface

            // Create offscreen window to host terminal view for screenshot capture
            // This ensures terminalView.window != nil so bitmapImageRepForCachingDisplay works
            self.setupOffscreenWindow(for: surface)
            self.startScreenshotCapture()

            // Mark as ready after shell has time to initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isReady = true

                // Run initial command after shell is ready
                if let command = command {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.surfaceView?.sendCommand(command)
                    }
                }
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
        let terminalView = surface.terminalView
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
    }

    private func cleanupOffscreenWindow() {
        // Remove terminal view from offscreen window and close it
        surfaceView?.terminalView.removeFromSuperview()
        offscreenWindow?.close()
        offscreenWindow = nil
    }

    func captureScreenshot() {
        guard let terminalView = surfaceView?.terminalView else { return }

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

    nonisolated func cleanup() {
        // Called from deinit - use MainActor.assumeIsolated since deinit
        // happens on the main thread for MainActor-isolated classes
        MainActor.assumeIsolated {
            screenshotTimer?.invalidate()
            surfaceView?.terminalView.removeFromSuperview()
            offscreenWindow?.close()
        }
    }

    deinit {
        cleanup()
    }
}

// MARK: - Running List View (Middle Column)

struct RunningListView: View {
    @Binding var selection: TerminalSession?
    var workspaceId: UUID? = nil
    @Environment(\.terminalSessionManager) private var sessionManager

    // Minimum item width for column calculation (doubled from 150)
    private let minItemWidth: CGFloat = 280

    /// Sessions filtered to this workspace (or all sessions if no workspace specified)
    private var workspaceSessions: [TerminalSession] {
        if let workspaceId {
            return sessionManager.sessions(for: workspaceId)
        }
        return sessionManager.sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Running")
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
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: columnCount),
                            spacing: spacing
                        ) {
                            ForEach(workspaceSessions) { session in
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
                                    Button(role: .destructive) {
                                        if selection?.id == session.id {
                                            selection = nil
                                        }
                                        sessionManager.stopSession(session)
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("No Running Tasks")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Start a task from Inbox to see it here")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                // Token histogram overlay (bottom-right)
                TokenHistogramOverlay(paneId: session.paneId)
                    .padding(8)
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(12)

            // Task info
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)

                Text(session.taskTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.orange.opacity(0.15) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 2)
        )
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
            let script = """
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
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
        // Run via osascript process for better reliability
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

// MARK: - Running Detail View (Right Panel)

struct RunningDetailView: View {
    let session: TerminalSession
    @Binding var selection: TerminalSession?
    @Environment(\.terminalSessionManager) private var sessionManager
    @State private var showStopConfirmation = false
    @State private var installedTerminals: [TerminalApp] = []
    @State private var isHoveringPill = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Full terminal view
            if let surfaceView = session.surfaceView {
                TerminalFullView(surfaceView: surfaceView)
                    .id(session.id)
            } else {
                Color(red: 0x18/255.0, green: 0x26/255.0, blue: 0x2F/255.0)
                Text("Terminal not available")
                    .foregroundStyle(.secondary)
            }

            // Floating glass pill toolbar
            TerminalGlassPill(
                session: session,
                installedTerminals: installedTerminals,
                isHovering: $isHoveringPill,
                onStop: { showStopConfirmation = true }
            )
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .background(Color(red: 0x18/255.0, green: 0x26/255.0, blue: 0x2F/255.0))
        .onAppear {
            installedTerminals = TerminalApp.installedApps
        }
        .confirmationDialog(
            "Stop Terminal",
            isPresented: $showStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Terminal", role: .destructive) {
                stopAndSelectPrevious()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to stop this terminal session?")
        }
    }

    private func stopAndSelectPrevious() {
        let sessions = sessionManager.sessions
        if let currentIndex = sessions.firstIndex(where: { $0.id == session.id }) {
            if currentIndex > 0 {
                selection = sessions[currentIndex - 1]
            } else if sessions.count > 1 {
                selection = sessions[currentIndex + 1]
            } else {
                selection = nil
            }
        }
        sessionManager.stopSession(session)
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
            HStack(spacing: 2) {
                // Open in external terminal
                if !installedTerminals.isEmpty, let paneId = session.paneId {
                    Menu {
                        ForEach(installedTerminals) { terminal in
                            Button {
                                terminal.open(withCommand: "axel session join \(paneId)")
                            } label: {
                                Label(terminal.name, systemImage: terminal.iconName)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11, weight: .medium))
                            Text("Join tmux")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                    )
                }

                // Stop button
                Button {
                    onStop()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red.opacity(0.15))
                )
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
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
                    surfaceView.terminalView.window?.makeFirstResponder(surfaceView.terminalView)
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

/// Claude logo shape for the histogram overlay
struct ClaudeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 128
        let scaleY = rect.height / 88

        var path = Path()

        // Main shape
        path.move(to: CGPoint(x: 112 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 128 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 128 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 104 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 104 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 80 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 80 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 48 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 48 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 24 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 24 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 0 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 0 * scaleY))
        path.closeSubpath()

        // Left eye (cutout)
        path.move(to: CGPoint(x: 32 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 17 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 17 * scaleY))
        path.closeSubpath()

        // Right eye (cutout)
        path.move(to: CGPoint(x: 88 * scaleX, y: 17 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 17 * scaleY))
        path.closeSubpath()

        return path
    }
}

struct TokenHistogramOverlay: View {
    let paneId: String?
    @State private var costTracker = CostTracker.shared

    private var histogramValues: [Double] {
        guard let paneId = paneId else {
            return Array(repeating: 0.1, count: 12)
        }
        return costTracker.histogramValues(forTerminal: paneId)
    }

    private var totalTokens: Int {
        guard let paneId = paneId else { return 0 }
        return costTracker.totalTokens(forTerminal: paneId)
    }

    var body: some View {
        HStack(spacing: 6) {
            ClaudeShape()
                .fill(.white.opacity(0.7))
                .frame(width: 14, height: 10)

            // Histogram bars
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 1)
                        .fill(Color.orange)
                        .frame(width: 5, height: max(2, value * 12))
                }
            }
            .frame(height: 12)

            Text(formatTokenCount(totalTokens))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                )
        )
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

/// Panel for selecting an available agent when multiple inactive workers exist
struct WorkerPickerPanel: View {
    let workers: [TerminalSession]
    let onSelect: (TerminalSession?) -> Void  // nil = create new agent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select an Agent")
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

            // Available workers
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(workers) { worker in
                        Button {
                            onSelect(worker)
                            dismiss()
                        } label: {
                            WorkerPickerRow(session: worker)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 300)

            Divider()

            // New agent button
            Button {
                onSelect(nil)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                    Text("New Agent")
                        .font(.body.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 320)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }
}

/// Row displaying a worker in the picker panel
struct WorkerPickerRow: View {
    let session: TerminalSession

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

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Running for \(session.startedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
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
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
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
#endif
