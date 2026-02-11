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
    case worktree(WorktreeInfo)

    var id: String {
        switch self {
        case .newWorktree: return "__new_worktree__"
        case .mainWorktree: return "__main__"
        case .worktree(let info): return "__worktree__\(info.id)"
        }
    }
}

// MARK: - Right Pane Item

/// Unified items for the horizontal right-pane picker
enum RightPaneItem: Identifiable {
    case pane(PaneInfo)
    case grid(GridInfo)
    case existingSession(TerminalSession)

    var id: String {
        switch self {
        case .pane(let info): return "pane_\(info.id)"
        case .grid(let info): return "grid_\(info.id)"
        case .existingSession(let session): return "session_\(session.id.uuidString)"
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
            let totalContentHeight = CGFloat(items.count) * rowHeight
            let fitsWithoutScrolling = totalContentHeight <= geo.size.height

            if fitsWithoutScrolling {
                // Few items: center the group, highlight selection in place
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == selectedIndex
                        ZStack {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.1))
                                    .padding(.horizontal, 8)
                            }
                            content(item, isSelected)
                                .frame(height: rowHeight)
                                .frame(maxWidth: .infinity)
                                .opacity(isSelected ? 1.0 : 0.5)
                        }
                        .frame(height: rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                selectedIndex = index
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                // Many items: slot-machine with scrolling offset
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
}

// MARK: - Horizontal Slot Picker

/// Horizontal slot-machine style picker: selected item at center, neighbors clipped by edges.
struct HorizontalSlotPickerView<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @Binding var selectedIndex: Int
    let itemWidth: CGFloat
    let spacing: CGFloat
    let content: (Item, Bool) -> Content

    init(
        items: [Item],
        selectedIndex: Binding<Int>,
        itemWidth: CGFloat = 300,
        spacing: CGFloat = 20,
        @ViewBuilder content: @escaping (Item, Bool) -> Content
    ) {
        self.items = items
        self._selectedIndex = selectedIndex
        self.itemWidth = itemWidth
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let step = itemWidth + spacing
            let contentOffset = centerX - (CGFloat(selectedIndex) * step) - (itemWidth / 2)

            HStack(spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let isSelected = index == selectedIndex
                    let distance = abs(index - selectedIndex)
                    content(item, isSelected)
                        .frame(width: itemWidth)
                        .frame(maxHeight: .infinity)
                        .opacity(distance == 0 ? 1.0 : max(0.15, 1.0 - Double(distance) * 0.35))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                selectedIndex = index
                            }
                        }
                }
            }
            .offset(x: contentOffset)
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selectedIndex)
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
    @State private var rightPaneItems: [RightPaneItem] = []
    @State private var rightPaneSelectedIndex: Int = 0
    @State private var newWorktreeBranch: String = ""
    @State private var worktrees: [WorktreeInfo] = []
    @State private var isLoading = true
    @FocusState private var isFocused: Bool
    @FocusState private var isWorktreeFieldFocused: Bool

    private var selectedItem: AgentPickerItem? {
        guard selectedIndex >= 0 && selectedIndex < pickerItems.count else { return nil }
        return pickerItems[selectedIndex]
    }

    private var selectedRightPaneItem: RightPaneItem? {
        guard rightPaneSelectedIndex >= 0 && rightPaneSelectedIndex < rightPaneItems.count else { return nil }
        return rightPaneItems[rightPaneSelectedIndex]
    }

    /// Whether the workspace has worktree support (is a git repo with worktrees discovered)
    private var hasWorktreeSupport: Bool {
        !worktrees.isEmpty
    }

    /// Build picker items: new worktree, main, existing worktrees, then sessions
    private func buildPickerItems() -> [AgentPickerItem] {
        guard hasWorktreeSupport else { return [] }
        var items: [AgentPickerItem] = []
        items.append(.newWorktree)
        items.append(.mainWorktree)
        // Add existing worktrees (excluding main)
        for wt in worktrees where !wt.isMain {
            items.append(.worktree(wt))
        }
        return items
    }

    /// Build right pane items: panes + grids + existing sessions for the selected worktree
    private func buildRightPaneItems() -> [RightPaneItem] {
        var items: [RightPaneItem] = []
        for pane in panes {
            items.append(.pane(pane))
        }
        for grid in grids {
            items.append(.grid(grid))
        }
        // Add existing sessions only in assign-task mode (Cmd+R)
        if task != nil, let workspaceId, let item = selectedItem {
            let branch: String? = {
                switch item {
                case .mainWorktree: return nil
                case .worktree(let info): return info.displayName
                default: return nil
                }
            }()
            let sessions = sessionManager.sessions(for: workspaceId)
                .filter { session in
                    if let branch {
                        return session.worktreeBranch == branch
                    } else {
                        return session.worktreeBranch == nil
                    }
                }
                .sorted { $0.startedAt > $1.startedAt }
            for session in sessions {
                items.append(.existingSession(session))
            }
        }
        return items
    }

    var body: some View {
        Group {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if hasWorktreeSupport {
                HStack(spacing: 0) {
                    // Left pane: slot-machine picker (worktrees)
                    slotPickerPane
                        .frame(width: 280)

                    Divider().opacity(0.3)

                    // Right pane: layout or session detail
                    rightPane
                        .frame(maxWidth: .infinity)
                }
            } else {
                // No worktree support: right pane only + optional branch input
                VStack(spacing: 0) {
                    rightPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().opacity(0.3)

                    // Optional worktree creation
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("branch name (optional)", text: $newWorktreeBranch)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .focused($isWorktreeFieldFocused)
                            .onSubmit {
                                confirmSelection()
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 760, height: 340)
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
                async let worktreesTask = WorktreeService.shared.listWorktrees(in: path)
                panes = await panesTask.filter { $0.isAi }
                grids = await gridsTask
                worktrees = await worktreesTask
            }
            pickerItems = buildPickerItems()
            // Default to main (index 1)
            selectedIndex = pickerItems.count > 1 ? 1 : 0
            rightPaneItems = buildRightPaneItems()
            isLoading = false
        }
        .onChange(of: selectedIndex) {
            rightPaneItems = buildRightPaneItems()
            rightPaneSelectedIndex = 0
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

                case .worktree(let info):
                    Text(info.displayName)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    // MARK: - Right Pane

    private var rightPane: some View {
        newSessionRightPane()
    }

    // MARK: - Right Pane: New Session

    private func newSessionRightPane() -> some View {
        VStack(spacing: 0) {
            if rightPaneItems.isEmpty {
                Spacer()
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                HorizontalSlotPickerView(
                    items: rightPaneItems,
                    selectedIndex: $rightPaneSelectedIndex,
                    itemWidth: 300
                ) { item, isSelected in
                    rightPaneMiniature(for: item, isSelected: isSelected)
                }
            }
        }
    }

    // MARK: - Miniature Card Renderer

    @ViewBuilder
    private func rightPaneMiniature(for item: RightPaneItem, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Card
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0x14/255.0, green: 0x14/255.0, blue: 0x14/255.0))

                switch item {
                case .pane(let pane):
                    VStack(spacing: 12) {
                        AIProviderIcon(provider: pane.provider, size: 40)
                    }

                case .grid(let grid):
                    miniGridVisualization(grid: grid)
                        .padding(8)

                case .existingSession(let session):
                    if let thumbnail = session.currentThumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "terminal.fill")
                                .font(.largeTitle)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .frame(width: 300, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.white.opacity(0.08),
                        lineWidth: isSelected ? 2 : 1
                    )
            )

            // Title + context below card
            VStack(alignment: .leading, spacing: 3) {
                switch item {
                case .pane(let pane):
                    Text(pane.name)
                        .font(.title.weight(.bold))
                    Text("New session")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .grid(let grid):
                    Text(grid.displayName)
                        .font(.title.weight(.bold))
                    Text("New grid session")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .existingSession(let session):
                    Text(session.taskTitle)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                    if session.hasTask {
                        Text("Enqueue task to session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Assign to idle session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.vertical, 8)
    }

    /// Grid layout visualization showing colored bordered cells with pane names
    private func miniGridVisualization(grid: GridInfo) -> some View {
        GeometryReader { geo in
            let cols = grid.columnCount
            let rows = grid.rowCount
            let gap: CGFloat = 4
            let totalW = geo.size.width
            let totalH = geo.size.height

            // Compute column widths from cell width percentages
            let colWidths: [CGFloat] = {
                var widths = Array(repeating: totalW / max(CGFloat(cols), 1), count: cols)
                // Use width hints from first cell in each column
                let byCol = grid.cellsByColumn
                let totalPct = byCol.reduce(0) { sum, colCells in
                    sum + (colCells.first?.width ?? 50)
                }
                if totalPct > 0 {
                    for c in 0..<cols {
                        let pct = byCol[c].first?.width ?? 50
                        widths[c] = (CGFloat(pct) / CGFloat(totalPct)) * (totalW - gap * CGFloat(cols - 1))
                    }
                }
                return widths
            }()

            // Compute row heights per column
            ForEach(Array(grid.cells.enumerated()), id: \.offset) { _, cell in
                let colRows = grid.cellsByColumn[cell.col].count
                let x = (0..<cell.col).reduce(CGFloat(0)) { $0 + colWidths[$1] + gap }
                let cellH = (totalH - gap * CGFloat(colRows - 1)) / max(CGFloat(colRows), 1)
                let y = CGFloat(cell.row) * (cellH + gap)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(cell.swiftUIColor.opacity(0.1))
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(cell.swiftUIColor.opacity(0.6), lineWidth: 1)

                    Text(cell.paneType)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(cell.swiftUIColor)
                        .padding(.horizontal, 5)
                        .padding(.top, 4)
                }
                .frame(width: colWidths[cell.col], height: cellH)
                .offset(x: x, y: y)
            }
        }
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
            isFocused = true
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
            isFocused = true
        }
    }

    private func navigateLeft() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if rightPaneSelectedIndex > 0 {
                rightPaneSelectedIndex -= 1
            }
        }
    }

    private func navigateRight() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if rightPaneSelectedIndex < rightPaneItems.count - 1 {
                rightPaneSelectedIndex += 1
            }
        }
    }

    private func confirmSelection() {
        // Determine branch from left pane selection (or inline field when no worktree support)
        let branch: String? = {
            if let item = selectedItem {
                switch item {
                case .mainWorktree: return nil
                case .newWorktree:
                    let b = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                    return b.isEmpty ? nil : b
                case .worktree(let info): return info.displayName
                }
            } else {
                // No worktree support — use inline branch field if filled
                let b = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                return b.isEmpty ? nil : b
            }
        }()

        // New worktree requires non-empty branch name
        if let item = selectedItem, case .newWorktree = item {
            guard branch != nil else { return }
        }

        guard let rightItem = selectedRightPaneItem else { return }

        switch rightItem {
        case .pane(let pane):
            onCreateTerminal(branch, pane.provider, nil)

        case .grid(let grid):
            let provider = panes.first?.provider ?? .claude
            onCreateTerminal(branch, provider, grid.name)

        case .existingSession(let session):
            if let task, let onAssignToSession {
                onAssignToSession(task, session)
            } else {
                onGoToSession?(session)
            }
        }
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
