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

// MARK: - Picker Item

/// Items in the left-pane slot-machine picker
enum AgentPickerItem: Identifiable {
    case newWorktree
    case mainWorktree
    case session(TerminalSession)

    var id: String {
        switch self {
        case .newWorktree: return "__new_worktree__"
        case .mainWorktree: return "__main__"
        case .session(let session): return session.id.uuidString
        }
    }
}

// MARK: - Slot Machine Picker

/// Slot-machine style picker: fixed selection band at vertical center, items scroll through it.
struct SlotPickerView<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @Binding var selectedIndex: Int
    let rowHeight: CGFloat
    let visibleCount: Int
    let content: (Item, Bool) -> Content

    init(
        items: [Item],
        selectedIndex: Binding<Int>,
        rowHeight: CGFloat = 58,
        visibleCount: Int = 5,
        @ViewBuilder content: @escaping (Item, Bool) -> Content
    ) {
        self.items = items
        self._selectedIndex = selectedIndex
        self.rowHeight = rowHeight
        self.visibleCount = visibleCount
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let centerY = geo.size.height / 2
            let contentOffset = centerY - (CGFloat(selectedIndex) * rowHeight) - (rowHeight / 2)

            ZStack {
                // Fixed selection band at center
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: geo.size.width - 16, height: rowHeight)
                    .position(x: geo.size.width / 2, y: centerY)

                // Scrolling items
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == selectedIndex
                        let distance = abs(index - selectedIndex)
                        content(item, isSelected)
                            .frame(height: rowHeight)
                            .frame(maxWidth: .infinity)
                            .opacity(distance == 0 ? 1.0 : max(0.15, 1.0 - Double(distance) * 0.35))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                    selectedIndex = index
                                }
                            }
                    }
                }
                .offset(y: contentOffset)
                .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selectedIndex)
            }
            .clipped()
        }
    }
}

// MARK: - Agent Picker Panel

/// Unified panel for Cmd+T (new terminal) and Cmd+R (assign task).
/// Left pane: slot-machine picker with worktrees + sessions.
/// Right pane: layout picker (for new) or session detail (for existing).
struct AgentPickerPanel: View {
    let workspaceId: UUID?
    let workspacePath: String?
    let task: WorkTask?
    let onCreateTerminal: (String?, AIProvider, String?) -> Void  // branchName?, provider, gridName?
    let onAssignToSession: ((WorkTask, TerminalSession) -> Void)?
    let onGoToSession: ((TerminalSession) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.terminalSessionManager) private var sessionManager

    @State private var selectedIndex: Int = 0
    @State private var pickerItems: [AgentPickerItem] = []
    @State private var panes: [PaneInfo] = []
    @State private var grids: [GridInfo] = []
    @State private var selectedPaneIndex: Int = 0
    @State private var selectedGridIndex: Int = 0
    @State private var isGridModeSelected: Bool = false
    @State private var newWorktreeBranch: String = ""
    @State private var isLoading = true
    @FocusState private var isFocused: Bool
    @FocusState private var isWorktreeFieldFocused: Bool

    private var selectedItem: AgentPickerItem? {
        guard selectedIndex >= 0 && selectedIndex < pickerItems.count else { return nil }
        return pickerItems[selectedIndex]
    }

    private var selectedPane: PaneInfo? {
        guard selectedPaneIndex < panes.count else { return nil }
        return panes[selectedPaneIndex]
    }

    private var selectedGrid: GridInfo? {
        guard selectedGridIndex < grids.count else { return nil }
        return grids[selectedGridIndex]
    }

    private var selectedGridName: String? {
        guard isGridModeSelected, let grid = selectedGrid else { return nil }
        return grid.name
    }

    private var selectedProvider: AIProvider {
        selectedPane?.provider ?? .claude
    }

    /// Whether we show layout picker (new session) vs session detail (existing)
    private var showsLayoutPicker: Bool {
        guard let item = selectedItem else { return true }
        switch item {
        case .mainWorktree, .newWorktree: return true
        case .session: return false
        }
    }

    /// Build picker items: new worktree, main, then sessions
    private func buildPickerItems() -> [AgentPickerItem] {
        var items: [AgentPickerItem] = []
        items.append(.newWorktree)
        items.append(.mainWorktree)
        if let workspaceId {
            let sessions = sessionManager.sessions(for: workspaceId)
                .sorted { $0.startedAt > $1.startedAt }
            for session in sessions {
                items.append(.session(session))
            }
        }
        return items
    }

    var body: some View {
        Group {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                HStack(spacing: 0) {
                    // Left pane: slot-machine picker
                    slotPickerPane
                        .frame(width: 280)

                    Divider().opacity(0.3)

                    // Right pane: layout or session detail
                    rightPane
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(width: 700, height: 340)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .presentationBackground(.clear)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .task {
            if let path = workspacePath {
                async let panesTask = LayoutService.shared.listPanes(in: path)
                async let gridsTask = LayoutService.shared.listGrids(in: path)
                panes = await panesTask.filter { $0.isAi }
                grids = await gridsTask
            }
            pickerItems = buildPickerItems()
            // Default to main (index 1)
            selectedIndex = pickerItems.count > 1 ? 1 : 0
            isLoading = false
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
            if !isWorktreeFieldFocused {
                navigateLeft()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if !isWorktreeFieldFocused {
                navigateRight()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if !isWorktreeFieldFocused || !newWorktreeBranch.isEmpty {
                confirmSelection()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    // MARK: - Left Pane

    private var slotPickerPane: some View {
        SlotPickerView(
            items: pickerItems,
            selectedIndex: $selectedIndex,
            rowHeight: 58,
            visibleCount: 5
        ) { item, isSelected in
            pickerRow(for: item, isSelected: isSelected)
        }
    }

    @ViewBuilder
    private func pickerRow(for item: AgentPickerItem, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                switch item {
                case .mainWorktree:
                    Text("main")
                        .font(.title.weight(.bold))

                case .newWorktree:
                    if isSelected {
                        TextField("branch name", text: $newWorktreeBranch)
                            .textFieldStyle(.plain)
                            .font(.title.weight(.bold))
                            .focused($isWorktreeFieldFocused)
                            .onSubmit {
                                if !newWorktreeBranch.isEmpty {
                                    confirmSelection()
                                }
                            }
                    } else {
                        Text(newWorktreeBranch.isEmpty ? "New worktree" : newWorktreeBranch)
                            .font(.title.weight(.bold))
                    }

                case .session(let session):
                    Text(session.taskTitle)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(session.status.color)
                            .frame(width: 6, height: 6)
                        Text(session.worktreeDisplayName)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .session(let session) = item, session.queueCount > 0 {
                Text("\(session.queueCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - Right Pane

    private var rightPane: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                switch item {
                case .mainWorktree, .newWorktree:
                    newSessionRightPane(item: item)
                case .session(let session):
                    sessionDetailRightPane(session: session)
                }
            }
        }
    }

    // MARK: - Right Pane: New Session

    private func newSessionRightPane(item: AgentPickerItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Layout selection
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

                            if !grids.isEmpty {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 1)
                                    .frame(height: 40)

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
            }
            .padding(16)
        }
        .padding(.top, 16)
    }

    // MARK: - Right Pane: Session Detail

    private func sessionDetailRightPane(session: TerminalSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Session info
                VStack(alignment: .leading, spacing: 12) {
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
        .padding(.top, 16)
    }

    // MARK: - Navigation

    private func navigateUp() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }
        if case .newWorktree = selectedItem {
            isWorktreeFieldFocused = true
        } else {
            isWorktreeFieldFocused = false
        }
    }

    private func navigateDown() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if selectedIndex < pickerItems.count - 1 {
                selectedIndex += 1
            }
        }
        if case .newWorktree = selectedItem {
            isWorktreeFieldFocused = true
        } else {
            isWorktreeFieldFocused = false
        }
    }

    private func navigateLeft() {
        guard showsLayoutPicker else { return }
        let totalItems = panes.count + grids.count
        guard totalItems > 0 else { return }

        let currentPosition = isGridModeSelected ? panes.count + selectedGridIndex : selectedPaneIndex
        let newPosition = currentPosition > 0 ? currentPosition - 1 : totalItems - 1

        if newPosition < panes.count {
            isGridModeSelected = false
            selectedPaneIndex = newPosition
        } else {
            isGridModeSelected = true
            selectedGridIndex = newPosition - panes.count
        }
    }

    private func navigateRight() {
        guard showsLayoutPicker else { return }
        let totalItems = panes.count + grids.count
        guard totalItems > 0 else { return }

        let currentPosition = isGridModeSelected ? panes.count + selectedGridIndex : selectedPaneIndex
        let newPosition = currentPosition < totalItems - 1 ? currentPosition + 1 : 0

        if newPosition < panes.count {
            isGridModeSelected = false
            selectedPaneIndex = newPosition
        } else {
            isGridModeSelected = true
            selectedGridIndex = newPosition - panes.count
        }
    }

    private func confirmSelection() {
        guard let item = selectedItem else { return }

        switch item {
        case .mainWorktree:
            if isGridModeSelected, let grid = selectedGrid {
                let provider = panes.first?.provider ?? .claude
                onCreateTerminal(nil, provider, grid.name)
            } else {
                onCreateTerminal(nil, selectedProvider, nil)
            }
            dismiss()

        case .newWorktree:
            let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return }
            if isGridModeSelected, let grid = selectedGrid {
                let provider = panes.first?.provider ?? .claude
                onCreateTerminal(branch, provider, grid.name)
            } else {
                onCreateTerminal(branch, selectedProvider, nil)
            }
            dismiss()

        case .session(let session):
            if let task, let onAssignToSession {
                onAssignToSession(task, session)
            } else {
                onGoToSession?(session)
            }
            dismiss()
        }
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
