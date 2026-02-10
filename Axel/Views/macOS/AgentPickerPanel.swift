import SwiftUI
import SwiftData

#if os(macOS)

// MARK: - Agent Picker Mode

/// Mode for the agent picker panel, used as a sheet item
enum AgentPickerMode: Identifiable {
    case newTerminal
    case assignTask(WorkTask)

    var id: String {
        switch self {
        case .newTerminal: return "newTerminal"
        case .assignTask(let task): return "assignTask-\(task.title)"
        }
    }

    var task: WorkTask? {
        switch self {
        case .newTerminal: return nil
        case .assignTask(let task): return task
        }
    }
}

// MARK: - Agent Picker Panel
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
struct AgentPickerPanel: View {
    let workspaceId: UUID?
    let workspacePath: String?
    let task: WorkTask?
    let onCreateTerminal: (String?, AIProvider, String?) -> Void  // branchName?, provider, gridName?
    let onAssignToSession: ((WorkTask, TerminalSession) -> Void)?
    let onGoToSession: ((TerminalSession) -> Void)?
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(task != nil ? "Assign to Agent" : "New Terminal")
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
                                        createWorktreeTerminal()
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
                .padding(16)
            }

            Divider()

            // Action button
            HStack {
                Spacer()
                Button {
                    if !newWorktreeBranch.isEmpty {
                        createWorktreeTerminal()
                    } else if selectedWorktreeIndex == 0 {
                        // Main worktree - create new session
                        onCreateTerminal(nil, selectedProvider, selectedGridName)
                        dismiss()
                    } else {
                        // Existing worktree - create worktree terminal
                        let worktrees = availableWorktrees.filter { !$0.isMain }
                        if selectedWorktreeIndex - 1 < worktrees.count {
                            onCreateTerminal(worktrees[selectedWorktreeIndex - 1].displayName, selectedProvider, selectedGridName)
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
                    if let task, let onAssignToSession {
                        onAssignToSession(task, session)
                    } else {
                        onGoToSession?(session)
                    }
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: task != nil ? (session.hasTask ? "plus.circle" : "play.fill") : "arrow.right.circle")
                            .font(.caption)
                        Text(task != nil ? (session.hasTask ? "Add to Queue" : "Run") : "Go to Session")
                            .font(.body.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(task != nil && session.hasTask ? Color.orange : Color.green)
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
                createWorktreeTerminal()
            } else if selectedWorktreeIndex == 0 {
                onCreateTerminal(nil, selectedProvider, selectedGridName)
                dismiss()
            } else {
                let worktrees = availableWorktrees.filter { !$0.isMain }
                if selectedWorktreeIndex - 1 < worktrees.count {
                    onCreateTerminal(worktrees[selectedWorktreeIndex - 1].displayName, selectedProvider, selectedGridName)
                    dismiss()
                }
            }
        case .existingSession(let session):
            if let task, let onAssignToSession {
                onAssignToSession(task, session)
            } else {
                onGoToSession?(session)
            }
            dismiss()
        }
    }

    private func createWorktreeTerminal() {
        let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        onCreateTerminal(branch, selectedProvider, selectedGridName)
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

#endif
