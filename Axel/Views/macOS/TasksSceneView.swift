import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

private let secondListAccentColor = Color(hex: "693EFE")!

extension WorkTask: ExpandableListItem, Equatable {
    static func == (lhs: WorkTask, rhs: WorkTask) -> Bool {
        lhs.id == rhs.id
    }

    var isChecked: Bool {
        get { taskStatus == .completed }
        set {
            if newValue != isChecked {
                Task { @MainActor in
                    updateStatusWithUndo(newValue ? .completed : .backlog)
                }
            }
        }
    }
}

// MARK: - Tasks Scene View
// Extracted from WorkspaceContentView.swift

struct WorkspaceQueueListView: View {
    @Bindable var workspace: Workspace
    @Environment(\.modelContext) private var modelContext
    let filter: TaskFilter
    @Binding var highlightedTask: WorkTask?
    var onNewTask: () -> Void
    var onStartTerminal: ((WorkTask) -> Void)?
    var onDeleteTasks: (([WorkTask]) -> Void)?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapTaskId: UUID?
    @State private var viewModel = TasksSceneViewModel()
    @State private var showDeleteConfirmation = false
    @State private var isSyncingHighlightedBinding = false
    @State private var dropTargetEndStatus: TaskStatus?
    @FocusState private var isListFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var sections: TasksSceneViewModel.TaskSections {
        viewModel.sections(for: workspace.tasks, filter: filter)
    }

    // Running tasks (sorted by priority)
    private var runningTasks: [WorkTask] { sections.running }

    // Up Next: tasks queued on a terminal (assigned, waiting their turn)
    private var upNextTasks: [WorkTask] { sections.upNext }

    // Backlog: unassigned tasks in the general pool
    private var backlogTasks: [WorkTask] { sections.backlog }

    /// Get terminal name for display (uses paneId prefix if no name set)
    private func terminalNameFor(_ task: WorkTask) -> String? {
        // Only show badge for tasks with .queued status (assigned to a terminal)
        guard task.taskStatus == .queued else { return nil }

        guard let paneId = TaskQueueService.shared.terminalForTask(taskId: task.id) else {
            return nil
        }

        // Find terminal to get its name
        if let terminal = workspace.terminals.first(where: { $0.paneId == paneId }) {
            if let name = terminal.name, !name.isEmpty {
                return name
            }
        }
        // Use first 8 chars of paneId as fallback
        return String(paneId.prefix(8))
    }

    private var allFilteredTasks: [WorkTask] { sections.allFiltered }

    /// All visible tasks in display order (Running → Up Next → Backlog)
    private var visibleTasksInOrder: [WorkTask] { sections.visibleInOrder }

    /// Selected tasks based on selectedTaskIds
    private var selectedTasks: [WorkTask] {
        visibleTasksInOrder.filter { viewModel.selectedTaskIds.contains($0.id) }
    }

    private func setHighlightedTask(_ task: WorkTask?) {
        isSyncingHighlightedBinding = true
        highlightedTask = task
        DispatchQueue.main.async {
            isSyncingHighlightedBinding = false
        }
    }

    private var tableSections: [TaskTableSection] {
        var result: [TaskTableSection] = []
        if !runningTasks.isEmpty {
            result.append(TaskTableSection(
                title: "Running",
                color: NSColor.systemPurple,
                status: .running,
                tasks: runningTasks,
                placeholderText: nil
            ))
        }
        if !upNextTasks.isEmpty {
            result.append(TaskTableSection(
                title: "Up Next",
                color: NSColor.systemOrange,
                status: .queued,
                tasks: upNextTasks,
                placeholderText: nil
            ))
        }

        result.append(TaskTableSection(
            title: "Backlog",
            color: NSColor.secondaryLabelColor,
            status: .backlog,
            tasks: backlogTasks,
            placeholderText: backlogTasks.isEmpty ? "No tasks in backlog" : nil
        ))

        return result
    }

    /// Select a single task (clears other selections)
    private func selectTask(_ task: WorkTask) {
        viewModel.selectTask(task)
        setHighlightedTask(task)
    }

    /// Toggle selection of a task (Cmd+click behavior)
    private func toggleTaskSelection(_ task: WorkTask) {
        viewModel.toggleTaskSelection(task, visibleTasks: visibleTasksInOrder)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Extend selection to a task (Shift+click behavior)
    private func extendSelectionTo(_ task: WorkTask) {
        viewModel.extendSelectionTo(task, visibleTasks: visibleTasksInOrder)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Select all tasks in current filter
    private func selectAllTasks() {
        viewModel.selectAll(visibleTasks: visibleTasksInOrder)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Sync selection state - ensures highlightedTask and selectedTaskIds are in sync
    private func syncSelectionState() {
        viewModel.syncSelectionState(visibleTasks: visibleTasksInOrder)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Clean up selection state when tasks are removed from visible list
    private func cleanupSelectionState(removedTaskIds: Set<UUID>) {
        viewModel.cleanupSelectionState(removedTaskIds: removedTaskIds, visibleTasks: visibleTasksInOrder)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Handle task status change - collapse and clear selection
    private func handleTaskStatusChange(_ task: WorkTask) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            viewModel.expandedTaskId = nil
        }
        viewModel.isClearingSelection = true
        viewModel.handleTaskStatusChange(taskId: task.id)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
        DispatchQueue.main.async {
            viewModel.endClearingSelection()
        }
    }

    /// Toggle expansion of the currently selected task
    private func toggleSelectedTaskExpansion() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            viewModel.toggleSelectedTaskExpansion(visibleTasks: visibleTasksInOrder)
        }
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Move selection up
    private func moveSelectionUp(extendSelection: Bool = false) {
        viewModel.moveSelectionUp(visibleTasks: visibleTasksInOrder, extendSelection: extendSelection)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Move selection down
    private func moveSelectionDown(extendSelection: Bool = false) {
        viewModel.moveSelectionDown(visibleTasks: visibleTasksInOrder, extendSelection: extendSelection)
        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
    }

    /// Delete selected tasks
    private func deleteSelectedTasks() {
        let tasksToDelete = selectedTasks
        guard !tasksToDelete.isEmpty else { return }

        // Clear selection first
        viewModel.clearSelection()
        setHighlightedTask(nil)
        DispatchQueue.main.async {
            viewModel.endClearingSelection()
        }

        // Clean up and delete each task
        for task in tasksToDelete {
            // Clean up TaskQueueService and other state
            task.prepareForDeletion()
            // Remove from workspace relationship
            workspace.tasks.removeAll { $0.id == task.id }
            modelContext.delete(task)
        }
        try? modelContext.save()

        // Sync changes (detached to avoid main actor contention)
        let workspaceId = workspace.syncId ?? workspace.id
        Task.detached {
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: self.modelContext)
        }
    }

    /// Mark selected task(s) as completed and select next task
    private func markSelectedComplete() {
        guard let task = viewModel.highlightedTask(in: visibleTasksInOrder) else { return }
        let newStatus: TaskStatus = task.taskStatus == .completed ? .queued : .completed

        // Find next task before changing status (which may remove it from visible list)
        if let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) {
            let nextTask = currentIndex < visibleTasksInOrder.count - 1
                ? visibleTasksInOrder[currentIndex + 1]
                : (currentIndex > 0 ? visibleTasksInOrder[currentIndex - 1] : nil)

            task.updateStatusWithUndo(newStatus)

            // Select next task if the current one will disappear from this view
            if let next = nextTask, newStatus == .completed && filter != .completed && filter != .all {
                selectTask(next)
            }
        } else {
            task.updateStatusWithUndo(newStatus)
        }
    }

    /// Mark selected task(s) as cancelled/aborted and select next task
    private func markSelectedCancelled() {
        guard let task = viewModel.highlightedTask(in: visibleTasksInOrder) else { return }

        // Find next task before changing status
        if let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) {
            let nextTask = currentIndex < visibleTasksInOrder.count - 1
                ? visibleTasksInOrder[currentIndex + 1]
                : (currentIndex > 0 ? visibleTasksInOrder[currentIndex - 1] : nil)

            task.updateStatusWithUndo(.aborted)

            // Select next task if the current one will disappear from this view
            if let next = nextTask, filter != .all {
                selectTask(next)
            }
        } else {
            task.updateStatusWithUndo(.aborted)
        }
    }

    /// Move selected task up in priority (lower priority number = higher in list)
    private func moveSelectedPriorityUp() {
        guard let task = viewModel.highlightedTask(in: visibleTasksInOrder) else { return }
        let tasksInSection = tasksForStatus(task.taskStatus)
        guard let currentIndex = tasksInSection.firstIndex(where: { $0.id == task.id }),
              currentIndex > 0 else { return }

        let reordered = viewModel.moveTask(task, direction: -1, tasksInSection: tasksInSection)
        var didChange = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            didChange = viewModel.applyPriorities(to: reordered)
        }
        guard didChange else { return }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    /// Move selected task down in priority (higher priority number = lower in list)
    private func moveSelectedPriorityDown() {
        guard let task = viewModel.highlightedTask(in: visibleTasksInOrder) else { return }
        let tasksInSection = tasksForStatus(task.taskStatus)
        guard let currentIndex = tasksInSection.firstIndex(where: { $0.id == task.id }),
              currentIndex < tasksInSection.count - 1 else { return }

        let reordered = viewModel.moveTask(task, direction: 1, tasksInSection: tasksInSection)
        var didChange = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            didChange = viewModel.applyPriorities(to: reordered)
        }
        guard didChange else { return }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private var headerTitle: String {
        switch filter {
        case .backlog: "Tasks"
        case .upNext: "Up Next"
        case .running: "Agents"
        case .completed: "Completed"
        case .all: "All Tasks"
        }
    }

    private func handleTap(on task: WorkTask, modifiers: EventModifiers = []) {
        // Collapse expanded task when selecting a different one
        if let expandedId = viewModel.expandedTaskId, expandedId != task.id {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                viewModel.expandedTaskId = nil
            }
        }

        let now = Date()
        let isDoubleTap = lastTapTaskId == task.id && now.timeIntervalSince(lastTapTime) < 0.3

        if isDoubleTap {
            // Double-click: toggle expansion
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if viewModel.expandedTaskId == task.id {
                    viewModel.expandedTaskId = nil
                } else {
                    viewModel.expandedTaskId = task.id
                }
            }
            lastTapTime = .distantPast
            lastTapTaskId = nil
        } else if modifiers.contains(.shift) {
            // Shift+click: extend selection
            extendSelectionTo(task)
            lastTapTime = now
            lastTapTaskId = task.id
        } else if modifiers.contains(.command) {
            // Cmd+click: toggle selection
            toggleTaskSelection(task)
            lastTapTime = now
            lastTapTaskId = task.id
        } else {
            // Single click: select
            selectTask(task)
            lastTapTime = now
            lastTapTaskId = task.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            taskListView
        }
        .background(backgroundView)
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onAppear {
            // Focus the list and sync selection state on appear
            DispatchQueue.main.async {
                isListFocused = true
                syncSelectionState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTasks)) { _ in
            // Restore focus and sync selection when switching back to tasks via Cmd+1
            DispatchQueue.main.async {
                isListFocused = true
                syncSelectionState()
            }
        }
        .modifier(TaskListKeyboardModifier(
            expandedTaskId: $viewModel.expandedTaskId,
            selectedTaskIds: $viewModel.selectedTaskIds,
            highlightedTaskId: $viewModel.highlightedTaskId,
            showDeleteConfirmation: $showDeleteConfirmation,
            onMoveUp: { extendSelection in moveSelectionUp(extendSelection: extendSelection) },
            onMoveDown: { extendSelection in moveSelectionDown(extendSelection: extendSelection) },
            onSelectAll: selectAllTasks,
            onToggleExpand: toggleSelectedTaskExpansion,
            onMarkComplete: markSelectedComplete,
            onMarkCancelled: markSelectedCancelled,
            onMovePriorityUp: moveSelectedPriorityUp,
            onMovePriorityDown: moveSelectedPriorityDown
        ))
        .alert("Delete Tasks?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedTasks()
            }
        } message: {
            Text("Are you sure you want to delete \(viewModel.selectedTaskIds.count) \(viewModel.selectedTaskIds.count == 1 ? "task" : "tasks")? This action cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .runTaskTriggered)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                viewModel.expandedTaskId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteTasksTriggered)) { _ in
            if !viewModel.selectedTaskIds.isEmpty {
                showDeleteConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .completeTaskTriggered)) { _ in
            markSelectedComplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelTaskTriggered)) { _ in
            markSelectedCancelled()
        }
        .onChange(of: highlightedTask?.id) { _, newValue in
            guard !viewModel.isClearingSelection else { return }
            guard !isSyncingHighlightedBinding else { return }
            if let newValue, viewModel.selectedTaskIds.contains(newValue) {
                return
            }
            viewModel.applyExternalHighlightedTaskId(newValue, visibleTasks: visibleTasksInOrder)
            setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
        }
        .onChange(of: viewModel.selectedTaskIds) { _, _ in
            guard !viewModel.isClearingSelection else { return }
            setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
        }
        .onChange(of: viewModel.expandedTaskId) { oldValue, newValue in
            // Restore focus to list when task collapses
            if oldValue != nil && newValue == nil {
                // Need async to let the view hierarchy update before restoring focus
                DispatchQueue.main.async {
                    isListFocused = true
                }
            }
        }
        .onChange(of: visibleTasksInOrder.map(\.id)) { oldIds, newIds in
            // When tasks leave the visible list (status change, deletion, etc.), clean up their selection
            let removedFromVisible = Set(oldIds).subtracting(Set(newIds))
            if !removedFromVisible.isEmpty {
                cleanupSelectionState(removedTaskIds: removedFromVisible)
            }
        }
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 16))
                .foregroundStyle(secondListAccentColor)

            Text(headerTitle)
                .font(.system(size: 20, weight: .bold))

            Text("\(allFilteredTasks.count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            Spacer()

            Button(action: onNewTask) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: 1000)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var taskListView: some View {
        if allFilteredTasks.isEmpty && filter != .backlog {
            emptyView
        } else if filter == .backlog && runningTasks.isEmpty && upNextTasks.isEmpty && backlogTasks.isEmpty {
            emptyView
        } else if filter == .backlog {
            ExpandableListContainer(
                hasExpandedItem: Binding(
                    get: { viewModel.expandedTaskId != nil },
                    set: { newValue in
                        if !newValue {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.expandedTaskId = nil
                            }
                        }
                    }
                ),
                onDismiss: {
                    clearSelection()
                }
            ) {
                LazyVStack(spacing: 8) {
                    secondListContent
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: visibleTasksInOrder.map(\.id))
        } else {
            ExpandableListContainer(
                hasExpandedItem: Binding(
                    get: { viewModel.expandedTaskId != nil },
                    set: { newValue in
                        if !newValue {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.expandedTaskId = nil
                            }
                        }
                    }
                ),
                onDismiss: {
                    clearSelection()
                }
            ) {
                LazyVStack(spacing: 1) {
                    secondListContent
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: allFilteredTasks.map(\.id))
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        filteredTasksSection
    }

    @ViewBuilder
    private func emptySectionPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var filteredTasksSection: some View {
        ForEach(allFilteredTasks, id: \.compositeId) { task in
            makeTaskRow(task: task, position: nil)
        }
    }

    @ViewBuilder
    private var secondListContent: some View {
        if filter == .backlog {
            ForEach(tableSections, id: \.status) { section in
                VStack(alignment: .leading, spacing: 6) {
                    sectionHeader(
                        section.title,
                        count: section.tasks.count,
                        color: section.status == .running
                            ? secondListAccentColor
                            : section.color.map { Color(nsColor: $0) }
                    )

                    ForEach(Array(section.tasks.enumerated()), id: \.element.id) { index, task in
                        ExpandableRow(
                            item: bindingForExpandableItem(task),
                            isExpanded: Binding(
                                get: { viewModel.expandedTaskId == task.id },
                                set: { newValue in
                                    viewModel.expandedTaskId = newValue ? task.id : nil
                                }
                            ),
                            isSelected: Binding(
                                get: { viewModel.selectedTaskIds.contains(task.id) },
                                set: { newValue in
                                    if newValue {
                                        viewModel.expandedTaskId = nil
                                        viewModel.selectTask(task)
                                        setHighlightedTask(task)
                                        return
                                    }
                                    if viewModel.selectedTaskIds.contains(task.id) {
                                        viewModel.toggleTaskSelection(task, visibleTasks: visibleTasksInOrder)
                                        setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
                                    }
                                }
                            ),
                            position: section.status == .queued ? index + 1 : nil,
                            onRun: task.taskStatus.isPending ? { onStartTerminal?(task) } : nil
                        ) {
                            TextField(
                                "Note details",
                                text: Binding(
                                    get: { task.taskDescription ?? "" },
                                    set: { task.updateDescription($0.isEmpty ? nil : $0) }
                                ),
                                axis: .vertical
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textFieldStyle(.plain)
                        }
                    }
                }
            }
        } else {
            ForEach(allFilteredTasks, id: \.id) { task in
                ExpandableRow(
                    item: bindingForExpandableItem(task),
                    isExpanded: Binding(
                        get: { viewModel.expandedTaskId == task.id },
                        set: { newValue in
                            viewModel.expandedTaskId = newValue ? task.id : nil
                        }
                    ),
                    isSelected: Binding(
                        get: { viewModel.selectedTaskIds.contains(task.id) },
                        set: { newValue in
                            if newValue {
                                viewModel.expandedTaskId = nil
                                viewModel.selectTask(task)
                                setHighlightedTask(task)
                                return
                            }
                            if viewModel.selectedTaskIds.contains(task.id) {
                                viewModel.toggleTaskSelection(task, visibleTasks: visibleTasksInOrder)
                                setHighlightedTask(viewModel.highlightedTask(in: visibleTasksInOrder))
                            }
                        }
                    ),
                    onRun: task.taskStatus.isPending ? { onStartTerminal?(task) } : nil
                ) {
                    TextField(
                        "Note details",
                        text: Binding(
                            get: { task.taskDescription ?? "" },
                            set: { task.updateDescription($0.isEmpty ? nil : $0) }
                        ),
                        axis: .vertical
                    )
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textFieldStyle(.plain)
                }
            }
        }
    }

    private func makeTaskRow(task: WorkTask, position: Int?, isDragTarget: Bool = false, disableTapGesture: Bool = false) -> some View {
        ExpandableTaskRow(
            task: task,
            position: position,
            isHighlighted: viewModel.isTaskSelected(task),
            isExpanded: viewModel.expandedTaskId == task.id,
            isDragTarget: isDragTarget,
            queuedOnTerminalName: terminalNameFor(task),
            isReordering: viewModel.draggingTaskId != nil,
            disableTapGesture: disableTapGesture,
            onTap: { modifiers in handleTap(on: task, modifiers: modifiers) },
            onRun: task.taskStatus.isPending ? { onStartTerminal?(task) } : nil,
            onToggleComplete: { toggleComplete(task) },
            onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { viewModel.expandedTaskId = nil } },
            onStatusChange: { handleTaskStatusChange(task) },
            onDelete: {
                selectTask(task)
                showDeleteConfirmation = true
            }
        )
    }

    private func bindingForExpandableItem(_ task: WorkTask) -> Binding<WorkTask> {
        Binding(
            get: { task },
            set: { newValue in
                if newValue.title != task.title {
                    task.updateTitle(newValue.title)
                }
                if newValue.isChecked != task.isChecked {
                    task.isChecked = newValue.isChecked
                }
            }
        )
    }

    private func isReorderable(_ status: TaskStatus) -> Bool {
        status == .queued || status == .backlog
    }

    @ViewBuilder
    private var backlogSectionsView: some View {
        ForEach(tableSections, id: \.status) { section in
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(
                    section.title,
                    count: section.tasks.count,
                    color: section.color.map { Color(nsColor: $0) }
                )
                .dropDestination(
                    for: String.self,
                    action: { items, _ in
                        guard isReorderable(section.status),
                              let draggedId = items.first,
                              let uuid = UUID(uuidString: draggedId) else {
                            return false
                        }
                        if let firstTask = section.tasks.first {
                            handleTableDrop(draggedId: uuid, targetTask: firstTask, targetStatus: section.status)
                        } else {
                            handleTableDropAtEnd(draggedId: uuid, targetStatus: section.status)
                        }
                        handleTableDragEnd()
                        handleTableDropTargetChange(nil, nil)
                        return true
                    },
                    isTargeted: { isTargeted in
                        guard isReorderable(section.status) else { return }
                        if isTargeted {
                            handleTableDropTargetChange(nil, section.status)
                        } else if dropTargetEndStatus == section.status {
                            handleTableDropTargetChange(nil, nil)
                        }
                    }
                )

                if section.tasks.isEmpty {
                    emptySectionPlaceholder(section.placeholderText ?? "No tasks")
                        .dropDestination(
                            for: String.self,
                            action: { items, _ in
                                guard isReorderable(section.status),
                                      let draggedId = items.first,
                                      let uuid = UUID(uuidString: draggedId) else {
                                    return false
                                }
                                handleTableDropAtEnd(draggedId: uuid, targetStatus: section.status)
                                handleTableDragEnd()
                                handleTableDropTargetChange(nil, nil)
                                return true
                            },
                            isTargeted: { isTargeted in
                                guard isReorderable(section.status) else { return }
                                if isTargeted {
                                    handleTableDropTargetChange(nil, section.status)
                                } else if dropTargetEndStatus == section.status {
                                    handleTableDropTargetChange(nil, nil)
                                }
                            }
                        )
                } else {
                    ForEach(Array(section.tasks.enumerated()), id: \.element.id) { index, task in
                        let position = section.status == .queued ? index + 1 : nil
                        makeTaskRow(
                            task: task,
                            position: position,
                            isDragTarget: viewModel.dropTargetTaskId == task.id
                        )
                        .onDrag {
                            guard isReorderable(section.status) else { return NSItemProvider() }
                            handleTableDragStart(task.id)
                            return NSItemProvider(object: task.id.uuidString as NSString)
                        }
                        .dropDestination(
                            for: String.self,
                            action: { items, _ in
                                guard isReorderable(section.status),
                                      let draggedId = items.first,
                                      let uuid = UUID(uuidString: draggedId) else {
                                    return false
                                }
                                handleTableDrop(draggedId: uuid, targetTask: task, targetStatus: section.status)
                                handleTableDragEnd()
                                handleTableDropTargetChange(nil, nil)
                                return true
                            },
                            isTargeted: { isTargeted in
                                guard isReorderable(section.status) else { return }
                                if isTargeted {
                                    handleTableDropTargetChange(task.id, nil)
                                } else if viewModel.dropTargetTaskId == task.id {
                                    handleTableDropTargetChange(nil, nil)
                                }
                            }
                        )
                    }

                    sectionDropZone(status: section.status)
                        .dropDestination(
                            for: String.self,
                            action: { items, _ in
                                guard isReorderable(section.status),
                                      let draggedId = items.first,
                                      let uuid = UUID(uuidString: draggedId) else {
                                    return false
                                }
                                handleTableDropAtEnd(draggedId: uuid, targetStatus: section.status)
                                handleTableDragEnd()
                                handleTableDropTargetChange(nil, nil)
                                return true
                            },
                            isTargeted: { isTargeted in
                                guard isReorderable(section.status) else { return }
                                if isTargeted {
                                    handleTableDropTargetChange(nil, section.status)
                                } else if dropTargetEndStatus == section.status {
                                    handleTableDropTargetChange(nil, nil)
                                }
                            }
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func sectionDropZone(status: TaskStatus) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .frame(height: 26)
            if dropTargetEndStatus == status {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                    .padding(.horizontal, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var backgroundView: some View {
        let isExpanded = viewModel.expandedTaskId != nil
        return Group {
            if colorScheme == .dark {
                isExpanded ? Color(hex: "27292B")! : Color(hex: "292F30")!
            } else {
                isExpanded ? Color(hex: "F9FAFB")! : Color.white
            }
        }
        .onTapGesture {
            clearSelection()
        }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            viewModel.expandedTaskId = nil
        }
        viewModel.clearSelection()
        setHighlightedTask(nil)
        DispatchQueue.main.async {
            viewModel.endClearingSelection()
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil, color: Color? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color ?? Color.secondary.opacity(0.7))
                .textCase(.uppercase)
                .tracking(0.5)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(color ?? .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((color ?? .secondary).opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func tasksForStatus(_ status: TaskStatus) -> [WorkTask] {
        switch status {
        case .queued:
            return upNextTasks
        case .backlog:
            return backlogTasks
        case .running:
            return runningTasks
        case .completed:
            return allFilteredTasks.filter { $0.taskStatus == .completed }
        case .inReview, .aborted:
            return allFilteredTasks.filter { $0.taskStatus == status }
        }
    }

    private func toggleComplete(_ task: WorkTask) {
        withAnimation(.easeInOut(duration: 0.2)) {
            task.toggleCompleteWithUndo()
        }
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private func handleTableDragStart(_ taskId: UUID) {
        guard let task = workspace.tasks.first(where: { $0.id == taskId }) else { return }
        viewModel.beginDragging(task: task)
        setHighlightedTask(task)
    }

    private func handleTableDragEnd() {
        viewModel.endDragging()
        dropTargetEndStatus = nil
    }

    private func handleTableDropTargetChange(_ taskId: UUID?, _ endStatus: TaskStatus?) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.dropTargetTaskId = taskId
            dropTargetEndStatus = endStatus
        }
    }

    private func handleTableDrop(draggedId: UUID, targetTask: WorkTask, targetStatus: TaskStatus) {
        guard let droppedTask = workspace.tasks.first(where: { $0.id == draggedId }),
              droppedTask.id != targetTask.id else {
            return
        }

        if droppedTask.taskStatus != targetStatus {
            handleTaskStatusChange(droppedTask)
            droppedTask.updateStatusWithUndo(targetStatus)
        }

        reorderTask(droppedTask, before: targetTask)
    }

    private func handleTableDropAtEnd(draggedId: UUID, targetStatus: TaskStatus) {
        guard let droppedTask = workspace.tasks.first(where: { $0.id == draggedId }) else {
            return
        }

        if droppedTask.taskStatus != targetStatus {
            handleTaskStatusChange(droppedTask)
            droppedTask.updateStatusWithUndo(targetStatus)
        }

        reorderTaskToEnd(droppedTask)
    }

    private func reorderTask(_ movedTask: WorkTask, before targetTask: WorkTask) {
        viewModel.endDragging()
        dropTargetEndStatus = nil
        var tasks = tasksForStatus(movedTask.taskStatus)
        if !tasks.contains(where: { $0.id == movedTask.id }) {
            tasks.append(movedTask)
        }
        let reordered = viewModel.reorderTask(movedTask, before: targetTask, tasksInSection: tasks)
        var didChange = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            didChange = viewModel.applyPriorities(to: reordered)
        }
        guard didChange else { return }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private func reorderTaskToEnd(_ movedTask: WorkTask) {
        viewModel.endDragging()
        dropTargetEndStatus = nil
        var tasks = tasksForStatus(movedTask.taskStatus)
        if !tasks.contains(where: { $0.id == movedTask.id }) {
            tasks.append(movedTask)
        }
        let reordered = viewModel.reorderTaskToEnd(movedTask, tasksInSection: tasks)
        var didChange = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            didChange = viewModel.applyPriorities(to: reordered)
        }
        guard didChange else { return }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Hero section
            VStack(spacing: 16) {
                // App icon with glow
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.purple.opacity(0.15), Color.clear],
                                center: .center,
                                startRadius: 20,
                                endRadius: 60
                            )
                        )
                        .frame(width: 120, height: 120)

                    Image(systemName: "rectangle.stack.badge.play")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .purple.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("Task Queue")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Create tasks and dispatch them to coding agents.\nAxel runs your work queue autonomously.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
            }

            Spacer()
                .frame(height: 40)

            // Keyboard shortcuts section
            VStack(spacing: 12) {
                Text("KEYBOARD SHORTCUTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(1.5)

                HStack(spacing: 24) {
                    KeyboardShortcutHint(keys: ["⌘", "N"], label: "New Task")
                    KeyboardShortcutHint(keys: ["⌘", "R"], label: "Run Task")
                    KeyboardShortcutHint(keys: ["⌘", "T"], label: "New Terminal")
                }

                HStack(spacing: 24) {
                    KeyboardShortcutHint(keys: ["⌘", "1"], label: "Tasks")
                    KeyboardShortcutHint(keys: ["⌘", "2"], label: "Agents")
                    KeyboardShortcutHint(keys: ["⌘", "3"], label: "Inbox")
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 32)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.03))
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )

            Spacer()

            // Call to action
            Button(action: onNewTask) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                    Text("Create First Task")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.purple.opacity(0.9))
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Task List Keyboard Modifier

struct TaskListKeyboardModifier: ViewModifier {
    @Binding var expandedTaskId: UUID?
    @Binding var selectedTaskIds: Set<UUID>
    @Binding var highlightedTaskId: UUID?
    @Binding var showDeleteConfirmation: Bool
    var onMoveUp: (_ extendSelection: Bool) -> Void
    var onMoveDown: (_ extendSelection: Bool) -> Void
    var onSelectAll: () -> Void
    var onToggleExpand: () -> Void
    var onMarkComplete: () -> Void
    var onMarkCancelled: () -> Void
    var onMovePriorityUp: () -> Void
    var onMovePriorityDown: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.escape) {
                if expandedTaskId != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTaskId = nil
                    }
                    return .handled
                }
                if !selectedTaskIds.isEmpty {
                    highlightedTaskId = nil
                    selectedTaskIds.removeAll()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                // Don't capture arrow keys when a task is expanded (let text fields handle them)
                guard expandedTaskId == nil else { return .ignored }

                if keyPress.modifiers.contains(.command) {
                    // Cmd+Up: move task priority up
                    onMovePriorityUp()
                    return .handled
                }
                onMoveUp(keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { keyPress in
                // Don't capture arrow keys when a task is expanded (let text fields handle them)
                guard expandedTaskId == nil else { return .ignored }

                if keyPress.modifiers.contains(.command) {
                    // Cmd+Down: move task priority down
                    onMovePriorityDown()
                    return .handled
                }
                onMoveDown(keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard !selectedTaskIds.isEmpty else { return .ignored }
                onToggleExpand()
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { keyPress in
                guard expandedTaskId == nil else { return .ignored }

                if keyPress.modifiers == [.command, .option] {
                    // Alt+Cmd+K: mark as cancelled
                    onMarkCancelled()
                    return .handled
                } else if keyPress.modifiers == .command {
                    // Cmd+K: mark as completed
                    onMarkComplete()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) {
                    onSelectAll()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [KeyEquivalent("r")], phases: .down) { keyPress in
                // Cmd+R: collapse expanded task (run will be handled by menu command)
                if keyPress.modifiers == .command && expandedTaskId != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTaskId = nil
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.delete], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) && !selectedTaskIds.isEmpty {
                    showDeleteConfirmation = true
                    return .handled
                }
                return .ignored
            }
    }
}

// MARK: - Expandable List Container (from ExpandableView sample)

protocol ExpandableListItem: Identifiable, Equatable {
    var id: UUID { get }
    var title: String { get set }
    var isChecked: Bool { get set }
}

struct ExpandableRowStyle {
    var animationDuration: Double = 0.25
    var selectedColor: Color = Color(red: 203 / 255, green: 226 / 255, blue: 255 / 255)
    var expandedColor: Color = .white
    var shadowColor: Color = .black.opacity(0.08)
    var shadowRadius: CGFloat = 2
    var shadowY: CGFloat = 2
    var cornerRadius: CGFloat = 10
    var verticalPadding: CGFloat = 8

    static let `default` = ExpandableRowStyle()
}

struct ExpandableRow<Item: ExpandableListItem, ExpandedContent: View>: View {
    @Binding var item: Item
    @Binding var isExpanded: Bool
    @Binding var isSelected: Bool

    var position: Int? = nil
    var onRun: (() -> Void)? = nil
    let style: ExpandableRowStyle
    let expandedContent: () -> ExpandedContent
    @State private var isStatusHovering: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        item: Binding<Item>,
        isExpanded: Binding<Bool>,
        isSelected: Binding<Bool>,
        position: Int? = nil,
        onRun: (() -> Void)? = nil,
        style: ExpandableRowStyle = .default,
        @ViewBuilder expandedContent: @escaping () -> ExpandedContent
    ) {
        self._item = item
        self._isExpanded = isExpanded
        self._isSelected = isSelected
        self.position = position
        self.onRun = onRun
        self.style = style
        self.expandedContent = expandedContent
    }

    private var backgroundColor: Color {
        if isExpanded {
            return colorScheme == .dark ? Color(hex: "33383A")! : Color.white
        } else if isSelected {
            return secondListAccentColor
        } else {
            return .clear
        }
    }

    private var selectedForeground: Color {
        isSelected ? Color.white.opacity(0.90) : .primary
    }

    private var indicatorAccent: Color {
        isExpanded ? secondListAccentColor : selectedForeground
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Group {
                    if let task = item as? WorkTask, task.taskStatus == .running {
                        RunningDotIndicator(size: indicatorSize, color: indicatorAccent)
                    } else if let task = item as? WorkTask, task.taskStatus == .queued || task.taskStatus == .backlog {
                        QueuedTaskIndicator(
                            size: indicatorSize,
                            isHovering: isStatusHovering,
                            position: task.taskStatus == .queued ? position : nil,
                            onRun: onRun,
                            accentColor: indicatorAccent
                        )
                    } else {
                        Button(action: {
                            withAnimation(.easeInOut(duration: style.animationDuration)) {
                                item.isChecked.toggle()
                            }
                        }) {
                            Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isExpanded ? secondListAccentColor : (isSelected ? Color.white.opacity(0.90) : (item.isChecked ? .blue : .gray)))
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: indicatorSize, height: indicatorSize, alignment: .center)
                .onHover { hovering in
                    isStatusHovering = hovering
                }

                if isExpanded {
                    TextField("Title", text: $item.title, axis: .vertical)
                        .font(.system(size: 14))
                        .textFieldStyle(.plain)
                        .lineLimit(nil)
                        .offset(y: 1)
                    Spacer()
                } else {
                    Text(item.title)
                        .font(.system(size: 14))
                        .foregroundColor(selectedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .offset(y: 1)
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, style.verticalPadding)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: style.animationDuration)) {
                    isExpanded = true
                    isSelected = false
                }
            }
            .onTapGesture(count: 1) {
                if !isExpanded {
                    withAnimation(.easeInOut(duration: style.animationDuration)) {
                        isSelected = true
                    }
                }
            }

            if isExpanded {
                expandedContent()
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .background(backgroundColor)
        .cornerRadius(style.cornerRadius)
        .shadow(
            color: isExpanded ? style.shadowColor : .clear,
            radius: style.shadowRadius,
            x: 0,
            y: style.shadowY
        )
        .padding(.horizontal)
    }

    private var indicatorSize: CGFloat { 20 }
}

struct RunningDotIndicator: View {
    let size: CGFloat
    let color: Color

    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .strokeBorder(
                style: StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    dash: [2, 3]
                )
            )
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct ExpandableListContainer<Content: View>: View {
    @Binding var hasExpandedItem: Bool
    let style: ExpandableRowStyle
    let onDismiss: () -> Void
    let content: () -> Content

    private var backgroundColor: Color {
        .clear
    }

    init(
        hasExpandedItem: Binding<Bool>,
        style: ExpandableRowStyle = .default,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._hasExpandedItem = hasExpandedItem
        self.style = style
        self.onDismiss = onDismiss
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                content()
            }
            .padding()
        }
        .background(backgroundColor)
        .animation(.easeInOut(duration: style.animationDuration), value: hasExpandedItem)
        .onTapGesture {
            withAnimation(.easeInOut(duration: style.animationDuration)) {
                onDismiss()
            }
        }
    }
}

// MARK: - Task Row

struct ExpandableTaskRow: View {
    let task: WorkTask
    var position: Int? = nil
    var isHighlighted: Bool = false
    var isExpanded: Bool = false
    var isDragTarget: Bool = false
    /// Optional terminal name if this task is queued on a terminal
    var queuedOnTerminalName: String? = nil
    var isReordering: Bool = false
    /// When true, tap gesture is disabled (clicks handled by parent NSTableView)
    var disableTapGesture: Bool = false
    var onTap: ((EventModifiers) -> Void)?
    var onRun: (() -> Void)?
    var onToggleComplete: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onDelete: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isDescriptionFocused: Bool
    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var showIndicator: Bool = true
    @State private var titleOffset: Bool = false
    @State private var showContent: Bool = false
    @State private var isFileDropTarget: Bool = false

    private var isRunning: Bool {
        task.taskStatus == .running
    }

    private var isCompleted: Bool {
        task.taskStatus == .completed
    }

    private var isQueued: Bool {
        task.taskStatus.isPending
    }

    private let indicatorSize: CGFloat = 22
    private let indicatorSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                statusIndicator
                    .frame(width: indicatorSize, height: indicatorSize)
                    .opacity(showIndicator ? 1 : 0)
                    .frame(width: titleOffset ? 0 : indicatorSize)
                    .padding(.trailing, titleOffset ? 0 : indicatorSpacing)

                Text(task.title)
                    .font(.system(size: 14))
                    .foregroundStyle(isCompleted ? .tertiary : .primary)
                    .strikethrough(isCompleted, color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(showContent ? 0 : 1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                if let terminalName = queuedOnTerminalName {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Queued on \(terminalName)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.leading, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())

            if showContent {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .fill(isExpanded ? (colorScheme == .dark ? Color(hex: "33383A")! : Color.white) : (isHighlighted ? Color.orange.opacity(0.08) : .clear))
                .shadow(color: isExpanded ? .black.opacity(colorScheme == .dark ? 0.3 : 0.1) : .clear, radius: isExpanded ? 6 : 0, y: isExpanded ? 3 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .strokeBorder(Color.blue.opacity(isFileDropTarget ? 0.6 : 0), lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isFileDropTarget)
        .overlay(alignment: .top) {
            if isDragTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 3)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                    .padding(.horizontal, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isDragTarget)
        .contentShape(Rectangle())
        .simultaneousGesture(disableTapGesture ? nil : TapGesture().onEnded {
            guard let onTap = onTap else { return }
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift) {
                onTap(.shift)
            } else if modifiers.contains(.command) {
                onTap(.command)
            } else {
                onTap([])
            }
        })
        .padding(.horizontal, isExpanded ? 8 : 0)
        .padding(.top, 0)
        .padding(.bottom, isExpanded ? 8 : 0)
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                withAnimation(.easeOut(duration: 0.15)) {
                    showIndicator = false
                }
                withAnimation(.easeInOut(duration: 0.2).delay(0.1)) {
                    titleOffset = true
                }
                withAnimation(.easeOut(duration: 0.2).delay(0.25)) {
                    showContent = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isTitleFocused = true
                    isDescriptionFocused = false
                }
            } else {
                withAnimation(.easeIn(duration: 0.15)) {
                    showContent = false
                }
                withAnimation(.easeInOut(duration: 0.2).delay(0.1)) {
                    titleOffset = false
                }
                withAnimation(.easeOut(duration: 0.15).delay(0.25)) {
                    showIndicator = true
                }
                isTitleFocused = false
                isDescriptionFocused = false
            }
        }
        .onChange(of: task.taskStatus) { oldStatus, newStatus in
            // Collapse and notify when status changes (e.g., running -> queued)
            if oldStatus != newStatus {
                onStatusChange?()
            }
        }
        .onAppear {
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
            showIndicator = !isExpanded
            titleOffset = isExpanded
            showContent = isExpanded
        }
        .onChange(of: task.title) { _, newValue in
            if editedTitle != newValue {
                editedTitle = newValue
            }
        }
        .onChange(of: task.taskDescription) { _, newValue in
            let newDesc = newValue ?? ""
            if editedDescription != newDesc {
                editedDescription = newDesc
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTarget) { providers in
            guard !isReordering else { return false }
            return handleFileDrop(providers: providers)
        }
        .accessibilityIdentifier("TaskRow")
        .accessibilityLabel(task.title)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            if isRunning {
                RunningTaskIndicator(size: indicatorSize, isHovering: false, onMarkComplete: {
                    onToggleComplete?()
                })
            } else if isCompleted {
                Button(action: { onToggleComplete?() }) {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: indicatorSize, height: indicatorSize)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            } else if isQueued {
                QueuedTaskIndicator(
                    size: indicatorSize,
                    isHovering: false,
                    position: position,
                    onRun: onRun
                )
            } else {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
                    .frame(width: indicatorSize, height: indicatorSize)
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Task title", text: $editedTitle, axis: .vertical)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isCompleted ? .tertiary : .primary)
                .focused($isTitleFocused)
                .onChange(of: editedTitle) { _, newValue in
                    if newValue != task.title {
                        task.updateTitle(newValue)
                    }
                }

            TextField("Notes", text: $editedDescription, axis: .vertical)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .focused($isDescriptionFocused)
                .onChange(of: editedDescription) { _, newValue in
                    let newDesc = newValue.isEmpty ? nil : newValue
                    if newDesc != task.taskDescription {
                        task.updateDescription(newDesc)
                    }
                }

            HStack(spacing: 10) {
                if isQueued, let onRun = onRun {
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }

                Button {
                    onToggleComplete?()
                } label: {
                    Label(isCompleted ? "Reopen" : "Complete", systemImage: isCompleted ? "arrow.uturn.backward" : "checkmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(isCompleted ? .secondary : .green)

                Spacer()

                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 2)
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        let fileName = url.lastPathComponent
                        let fileUrl = url.path
                        let attachment = TaskAttachment(
                            fileName: fileName,
                            fileUrl: fileUrl,
                            fileType: "file"
                        )
                        attachment.task = task
                        modelContext.insert(attachment)
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

// MARK: - Running Task Indicator

/// Animated dashed circle that spins, shows checkmark on hover
struct RunningTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    var provider: AIProvider = .claude
    var onMarkComplete: (() -> Void)?

    var body: some View {
        ZStack {
            if isHovering {
                // Checkmark circle on hover
                Button(action: { onMarkComplete?() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.green.opacity(0.5), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.45, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Animated spinning dashed circle using TimelineView for continuous animation
                TimelineView(.animation) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let rotation = seconds.truncatingRemainder(dividingBy: 8) / 8 * 360

                    Circle()
                        .strokeBorder(
                            style: StrokeStyle(
                                lineWidth: 1.5,
                                lineCap: .round,
                                dash: [2, 3]
                            )
                        )
                        .foregroundStyle(Color.purple.opacity(0.6))
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(rotation))
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}

/// Indicator for queued tasks - play icon in a circle with hover effect
struct QueuedTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    let position: Int?
    var onRun: (() -> Void)?
    var accentColor: Color = .orange

    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            if isHovering {
                // Play circle on hover - ready to start
                Button(action: { onRun?() }) {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.15))
                            .frame(width: size, height: size)

                        Circle()
                            .strokeBorder(accentColor.opacity(0.6), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(accentColor)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Subtle play indicator in a circle
                ZStack {
                    Circle()
                        .strokeBorder(accentColor.opacity(0.3 + pulsePhase * 0.2), lineWidth: 1.5)
                        .frame(width: size, height: size)

                    if let pos = position {
                        Text("\(pos)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.35))
                            .foregroundStyle(accentColor.opacity(0.8))
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulsePhase = 1.0
            }
        }
    }
}

// MARK: - Keyboard Shortcut Hint

/// A compact keyboard shortcut display with key symbols and label
struct KeyboardShortcutHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.8))
                        .frame(minWidth: 22, minHeight: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white.opacity(0.08))
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Flow Layout

/// A layout that arranges views in rows, wrapping to the next row when needed
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > containerWidth && currentX > 0 {
                // Move to next line
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
            totalHeight = currentY + lineHeight
        }

        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                // Move to next line
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size)
            )

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
        }
    }
}

#endif
