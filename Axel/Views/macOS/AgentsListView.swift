import SwiftUI

#if os(macOS)
import AppKit

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

#endif
