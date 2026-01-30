import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

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
                color: NSColor.systemGreen,
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
                .foregroundStyle(.blue)

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
            TaskTableView(
                sections: tableSections,
                isDragging: viewModel.draggingTaskId != nil,
                dropTargetEndStatus: dropTargetEndStatus,
                expandedTaskId: viewModel.expandedTaskId,
                selectedTaskIds: viewModel.selectedTaskIds,
                rowView: { task, position in
                    AnyView(makeTaskRow(
                        task: task,
                        position: position,
                        isDragTarget: viewModel.dropTargetTaskId == task.id,
                        disableTapGesture: true
                    ))
                },
                headerView: { title, count, color in
                    AnyView(sectionHeader(
                        title,
                        count: count,
                        color: color.map { Color(nsColor: $0) }
                    ))
                },
                placeholderView: { text in
                    AnyView(emptySectionPlaceholder(text))
                },
                dropZoneView: { _, isActive in
                    AnyView(
                        ZStack(alignment: .top) {
                            Color.clear
                                .frame(height: 26)
                            if isActive {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: 3)
                                    .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
                                    .padding(.horizontal, 10)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    )
                },
                onReorder: handleTableDrop,
                onDropAtEnd: handleTableDropAtEnd,
                onDragStart: handleTableDragStart,
                onDragEnd: handleTableDragEnd,
                onDropTargetChange: handleTableDropTargetChange,
                onBackgroundClick: clearSelection,
                onTaskClick: { taskId, modifiers in
                    guard let task = workspace.tasks.first(where: { $0.id == taskId }) else { return }
                    // Collapse expanded task when selecting a different one
                    if let expandedId = viewModel.expandedTaskId, expandedId != taskId {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            viewModel.expandedTaskId = nil
                        }
                    }
                    // Handle selection based on modifiers
                    if modifiers.contains(.shift) {
                        extendSelectionTo(task)
                    } else if modifiers.contains(.command) {
                        toggleTaskSelection(task)
                    } else {
                        selectTask(task)
                    }
                },
                onTaskDoubleClick: { taskId in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if viewModel.expandedTaskId == taskId {
                            viewModel.expandedTaskId = nil
                        } else {
                            viewModel.expandedTaskId = taskId
                        }
                    }
                },
                onKeyDown: { event in
                    handleTableKeyDown(event)
                }
            )
            .frame(maxWidth: 1000)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    taskListContent
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: allFilteredTasks.map(\.id))
            .onTapGesture {
                clearSelection()
            }
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

    private func makeTaskRow(task: WorkTask, position: Int?, isDragTarget: Bool = false, disableTapGesture: Bool = false) -> some View {
        TaskRow(
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

    private var backgroundView: some View {
        (colorScheme == .dark ? Color(white: 27.0 / 255.0) : Color.white)
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

    /// Handle keyboard events from NSTableView
    private func handleTableKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        // Escape - collapse expanded task or clear selection
        if keyCode == 53 { // Escape
            if viewModel.expandedTaskId != nil {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    viewModel.expandedTaskId = nil
                }
                return true
            }
            if !viewModel.selectedTaskIds.isEmpty {
                viewModel.clearSelection()
                setHighlightedTask(nil)
                return true
            }
            return false
        }

        // Up arrow
        if keyCode == 126 {
            if viewModel.expandedTaskId != nil { return false }
            if modifiers.contains(.command) {
                moveSelectedPriorityUp()
            } else {
                moveSelectionUp(extendSelection: modifiers.contains(.shift))
            }
            return true
        }

        // Down arrow
        if keyCode == 125 {
            if viewModel.expandedTaskId != nil { return false }
            if modifiers.contains(.command) {
                moveSelectedPriorityDown()
            } else {
                moveSelectionDown(extendSelection: modifiers.contains(.shift))
            }
            return true
        }

        // Return/Enter - toggle expand
        if keyCode == 36 {
            if !viewModel.selectedTaskIds.isEmpty {
                toggleSelectedTaskExpansion()
                return true
            }
            return false
        }

        // Cmd+K - mark complete, Cmd+Option+K - mark cancelled
        if keyCode == 40 && modifiers.contains(.command) {
            if viewModel.expandedTaskId != nil { return false }
            if modifiers.contains(.option) {
                markSelectedCancelled()
            } else {
                markSelectedComplete()
            }
            return true
        }

        // Cmd+A - select all
        if keyCode == 0 && modifiers.contains(.command) {
            selectAllTasks()
            return true
        }

        // Cmd+Delete - delete
        if keyCode == 51 && modifiers.contains(.command) {
            if !viewModel.selectedTaskIds.isEmpty {
                showDeleteConfirmation = true
                return true
            }
            return false
        }

        return false
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
                                colors: [Color.orange.opacity(0.15), Color.clear],
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
                                colors: [.orange, .orange.opacity(0.7)],
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
                        .fill(Color.orange.opacity(0.9))
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

// MARK: - Task Row

struct TaskRow: View {
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
    @State private var showNotes: Bool = false
    @State private var isHovering: Bool = false
    @State private var isTitleFocused: Bool = false
    @State private var isDescriptionFocused: Bool = false
    @State private var isStatusHovering: Bool = false
    @State private var showSkillPicker: Bool = false
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

    private var checkboxSize: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row - only this part handles taps for selection/expansion
            HStack(spacing: 12) {
                // Leading indicator
                ZStack {
                    if isRunning {
                        // Claude icon with hover to mark complete
                        RunningTaskIndicator(
                            size: checkboxSize,
                            isHovering: isStatusHovering,
                            onMarkComplete: {
                                onToggleComplete?()
                            }
                        )
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isStatusHovering = hovering
                            }
                        }
                    } else if isCompleted {
                        Button(action: { onToggleComplete?() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: checkboxSize, height: checkboxSize)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    } else if isQueued {
                        QueuedTaskIndicator(
                            size: checkboxSize,
                            isHovering: isStatusHovering,
                            position: position,
                            onRun: onRun
                        )
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isStatusHovering = hovering
                            }
                        }
                    } else {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: checkboxSize, height: checkboxSize)
                    }
                }

                // Title
                ZStack(alignment: .leading) {
                    // Static text - only shown when collapsed (single line, truncated)
                    if !showNotes {
                        Text(task.title)
                            .font(.system(size: 14))
                            .foregroundStyle(isCompleted ? .tertiary : .primary)
                            .strikethrough(isCompleted, color: .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }

                    // Editable field - shown when expanded (supports multiple lines)
                    if showNotes {
                        MultilineTitleField(
                            text: Binding(
                                get: { task.title },
                                set: { task.updateTitle($0) }
                            ),
                            font: .systemFont(ofSize: 14),
                            shouldFocus: isTitleFocused,
                            onEscape: onCollapse,
                            onTab: {
                                isTitleFocused = false
                                isDescriptionFocused = true
                            }
                        )
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.15), value: showNotes)
                .allowsHitTesting(showNotes) // Allow text field interaction when expanded

                // Queue badge - shown when task is queued on a terminal
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
                }

                // Attachment indicator - shown when task has attachments
                if !task.attachments.isEmpty {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                if isQueued, let onRun = onRun {
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    Divider()
                }

                Button {
                    onToggleComplete?()
                } label: {
                    if isCompleted {
                        Label("Mark as Incomplete", systemImage: "circle")
                    } else {
                        Label("Mark as Complete", systemImage: "checkmark.circle.fill")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            // Description - visible in both states
            if isExpanded {
                // Editable in expanded state
                GrowingTextView(
                    text: Binding(
                        get: { task.taskDescription ?? "" },
                        set: { task.updateDescription($0.isEmpty ? nil : $0) }
                    ),
                    placeholder: "Notes",
                    font: .systemFont(ofSize: 13),
                    shouldFocus: isDescriptionFocused,
                    onEscape: onCollapse,
                    onShiftTab: {
                        isDescriptionFocused = false
                        isTitleFocused = true
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .padding(.top, 6)
                .padding(.leading, 32)
                .opacity(showNotes ? 1 : 0)
                .offset(y: showNotes ? 0 : -8)
                .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showNotes)
            } else if let description = task.taskDescription, !description.isEmpty {
                // Read-only preview in collapsed state
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                    .padding(.leading, 32)
            }

            // Attachments row - only in expanded state
            if isExpanded && !task.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(task.attachments, id: \.id) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(attachment.fileName)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                modelContext.delete(attachment)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 32)
                .opacity(showNotes ? 1 : 0)
                .offset(y: showNotes ? 0 : -8)
                .animation(.spring(response: 0.25, dampingFraction: 0.85).delay(0.05), value: showNotes)
            }

            // Skills and Status row - only in expanded state
            if isExpanded {
                HStack(spacing: 8) {
                    // Attached skills chips
                    ForEach(task.taskSkills, id: \.id) { taskSkill in
                        if let skill = taskSkill.skill {
                            HStack(spacing: 4) {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 9))
                                Text(skill.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Button {
                                    // Remove skill
                                    modelContext.delete(taskSkill)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.8))
                            )
                        }
                    }

                    // Add skill button
                    Button {
                        showSkillPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Attach skill")
                    .sheet(isPresented: $showSkillPicker) {
                        TaskSkillPickerView(task: task)
                    }

                    Spacer()

                    // Status dropdown
                    Menu {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            Button(action: {
                                // First collapse the task, then update status after animation completes
                                if task.taskStatus != status {
                                    onCollapse?()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        // Clear selection FIRST in its own render cycle
                                        onStatusChange?()
                                        // Update status in the next run loop iteration
                                        // so SwiftUI processes the selection clear first
                                        DispatchQueue.main.async {
                                            task.updateStatusWithUndo(status)
                                        }
                                    }
                                }
                            }) {
                                HStack {
                                    Text(status.menuLabel)
                                    if task.taskStatus == status {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(task.taskStatus.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .tracking(0.5)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: "9A9C9D")!)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(hex: "9A9C9D")!.opacity(isStatusHovering ? 0.5 : 0), lineWidth: 1)
                        )
                        .scaleEffect(isStatusHovering ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isStatusHovering)
                        .onHover { hovering in
                            isStatusHovering = hovering
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                .padding(.horizontal, 12)
                .opacity(showNotes ? 1 : 0)
                .offset(y: showNotes ? 0 : -8)
                .animation(.spring(response: 0.25, dampingFraction: 0.85).delay(0.08), value: showNotes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .fill(isExpanded ? (colorScheme == .dark ? Color(white: 0.20) : Color(hex: "F7F7F7")!) : (isHighlighted ? Color.orange.opacity(0.08) : .clear))
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
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.top, isExpanded ? 24 : 0)
        .padding(.bottom, isExpanded ? 32 : 0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                // Shorter delay for smoother feel
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showNotes = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isTitleFocused = true
                        isDescriptionFocused = false
                    }
                }
            } else {
                withAnimation(.easeIn(duration: 0.1)) {
                    showNotes = false
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
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTarget) { providers in
            guard !isReordering else { return false }
            return handleFileDrop(providers: providers)
        }
        .accessibilityIdentifier("TaskRow")
        .accessibilityLabel(task.title)
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

    @State private var rotation: Double = 0
    @State private var isAnimating: Bool = false

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
                // Animated spinning dashed circle
                Circle()
                    .strokeBorder(
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            lineCap: .round,
                            dash: [2, 3]
                        )
                    )
                    .foregroundStyle(provider.color.opacity(0.6))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(rotation))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            startAnimation()
        }
        .onChange(of: isHovering) { _, hovering in
            if hovering {
                // Stop animation when hovering
                isAnimating = false
            } else {
                // Resume animation when not hovering
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            rotation += 360
        }
    }
}

/// Indicator for queued tasks - play icon in a circle with hover effect
struct QueuedTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    let position: Int?
    var onRun: (() -> Void)?

    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            if isHovering {
                // Play circle on hover - ready to start
                Button(action: { onRun?() }) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: size, height: size)

                        Circle()
                            .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Subtle play indicator in a circle
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15 + pulsePhase * 0.1), lineWidth: 1.5)
                        .frame(width: size, height: size)

                    if let pos = position {
                        Text("\(pos)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.35))
                            .foregroundStyle(.secondary.opacity(0.6))
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

#endif
