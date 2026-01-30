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
    @State private var expandedTask: WorkTask?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapTaskId: UUID?
    @State private var viewModel = TodoViewModel()
    @State private var showTerminal = false
    @State private var draggingTask: WorkTask?
    @State private var dropTargetTaskId: UUID?
    @State private var selectedTaskIds: Set<UUID> = []
    @State private var lastSelectedTaskId: UUID?
    @State private var showDeleteConfirmation = false
    @State private var isClearingSelection = false  // Prevents onChange handlers from re-adding during clear
    @FocusState private var isListFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    // Running tasks (sorted by priority)
    private var runningTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus == .running }
            .sorted { $0.priority < $1.priority }
    }

    // Up Next: tasks queued on a terminal (assigned, waiting their turn)
    private var upNextTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus == .queued }
            .sorted { $0.priority < $1.priority }
    }

    // Backlog: unassigned tasks in the general pool
    private var backlogTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus == .backlog }
            .sorted { $0.priority < $1.priority }
    }

    // All pending tasks (for backwards compatibility with drag/drop)
    private var queuedTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus.isPending }
            .sorted { $0.priority < $1.priority }
    }

    /// Find which terminal (if any) has a task in its queue (via TaskQueueService)
    private func terminalQueuedOn(task: WorkTask) -> Terminal? {
        guard let paneId = TaskQueueService.shared.terminalForTask(taskId: task.id) else {
            return nil
        }
        return workspace.terminals.first { $0.paneId == paneId }
    }

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

    private var allFilteredTasks: [WorkTask] {
        let tasks = workspace.tasks.sorted { $0.priority < $1.priority }
        switch filter {
        case .backlog: return tasks.filter { $0.taskStatus == .backlog }
        case .upNext: return tasks.filter { $0.taskStatus == .queued }
        case .running: return tasks.filter { $0.taskStatus == .running }
        case .completed: return tasks.filter { $0.taskStatus == .completed }
        case .all: return tasks
        }
    }

    /// All visible tasks in display order (Running → Up Next → Backlog)
    private var visibleTasksInOrder: [WorkTask] {
        if filter == .backlog || filter == .upNext {
            // Match the visual section order: Running, then Up Next, then Backlog
            return runningTasks + upNextTasks + backlogTasks
        }
        return allFilteredTasks
    }

    /// Selected tasks based on selectedTaskIds
    private var selectedTasks: [WorkTask] {
        visibleTasksInOrder.filter { selectedTaskIds.contains($0.id) }
    }

    /// Check if a task is selected
    private func isTaskSelected(_ task: WorkTask) -> Bool {
        selectedTaskIds.contains(task.id)
    }

    /// Select a single task (clears other selections)
    private func selectTask(_ task: WorkTask) {
        selectedTaskIds = [task.id]
        lastSelectedTaskId = task.id
        highlightedTask = task
    }

    /// Toggle selection of a task (Cmd+click behavior)
    private func toggleTaskSelection(_ task: WorkTask) {
        if selectedTaskIds.contains(task.id) {
            selectedTaskIds.remove(task.id)
            if selectedTaskIds.isEmpty {
                highlightedTask = nil
                lastSelectedTaskId = nil
            } else if highlightedTask?.id == task.id {
                highlightedTask = visibleTasksInOrder.first { selectedTaskIds.contains($0.id) }
            }
        } else {
            selectedTaskIds.insert(task.id)
            lastSelectedTaskId = task.id
            highlightedTask = task
        }
    }

    /// Extend selection to a task (Shift+click behavior)
    private func extendSelectionTo(_ task: WorkTask) {
        guard let lastId = lastSelectedTaskId,
              let lastIndex = visibleTasksInOrder.firstIndex(where: { $0.id == lastId }),
              let targetIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) else {
            selectTask(task)
            return
        }

        let range = lastIndex < targetIndex ? lastIndex...targetIndex : targetIndex...lastIndex
        for i in range {
            selectedTaskIds.insert(visibleTasksInOrder[i].id)
        }
        highlightedTask = task
    }

    /// Select all tasks in current filter
    private func selectAllTasks() {
        selectedTaskIds = Set(visibleTasksInOrder.map(\.id))
        if let first = visibleTasksInOrder.first {
            highlightedTask = first
        }
    }

    /// Sync selection state - ensures highlightedTask and selectedTaskIds are in sync
    private func syncSelectionState() {
        // Skip sync if we're in the middle of clearing selection
        guard !isClearingSelection else { return }

        // First, check if selectedTaskIds has a valid selection
        if let selectedTask = visibleTasksInOrder.first(where: { selectedTaskIds.contains($0.id) }) {
            // Update highlightedTask to match the visual selection
            highlightedTask = selectedTask
        } else if let task = highlightedTask, visibleTasksInOrder.contains(where: { $0.id == task.id }) {
            // selectedTaskIds is empty but highlightedTask has a valid value (e.g., after view recreation)
            // Initialize selectedTaskIds from highlightedTask
            selectedTaskIds = [task.id]
            lastSelectedTaskId = task.id
        } else {
            // No valid selection anywhere - clear everything
            highlightedTask = nil
            selectedTaskIds.removeAll()
            lastSelectedTaskId = nil
        }
    }

    /// Clean up selection state when tasks are removed from visible list
    private func cleanupSelectionState(removedTaskIds: Set<UUID>) {
        // Remove from selection
        selectedTaskIds.subtract(removedTaskIds)

        // Clear highlighted if it was removed
        if let highlighted = highlightedTask, removedTaskIds.contains(highlighted.id) {
            // Try to select next available task
            if let nextTask = visibleTasksInOrder.first(where: { selectedTaskIds.contains($0.id) }) {
                highlightedTask = nextTask
            } else {
                highlightedTask = nil
            }
        }

        // Clear lastSelectedTaskId if it was removed
        if let lastId = lastSelectedTaskId, removedTaskIds.contains(lastId) {
            lastSelectedTaskId = selectedTaskIds.first
        }

        // Clear expanded if it was removed
        if let expanded = expandedTask, removedTaskIds.contains(expanded.id) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedTask = nil
            }
        }
    }

    /// Handle task status change - collapse and clear selection
    private func handleTaskStatusChange(_ task: WorkTask) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedTask = nil
        }
        // Set flag to prevent onChange handlers from re-adding the task during clear
        isClearingSelection = true
        // Clear selection for this task to avoid stuck state when it moves between sections
        if highlightedTask?.id == task.id {
            highlightedTask = nil
        }
        if lastSelectedTaskId == task.id {
            lastSelectedTaskId = nil
        }
        selectedTaskIds.remove(task.id)
        // Reset flag after a brief delay to allow SwiftUI state updates to settle
        DispatchQueue.main.async {
            isClearingSelection = false
        }
    }

    /// Toggle expansion of the currently selected task
    private func toggleSelectedTaskExpansion() {
        // Use selectedTaskIds as the source of truth to find the task to expand
        guard let task = visibleTasksInOrder.first(where: { selectedTaskIds.contains($0.id) }) else {
            return
        }

        // Also sync highlightedTask to ensure consistency
        highlightedTask = task

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedTask?.id == task.id {
                expandedTask = nil
            } else {
                expandedTask = task
            }
        }
    }

    /// Move selection up
    private func moveSelectionUp(extendSelection: Bool = false) {
        guard !visibleTasksInOrder.isEmpty else { return }

        // When extending selection, use highlightedTask (cursor position)
        // Otherwise, use first selected task
        let currentIndex: Int?
        if extendSelection, let highlighted = highlightedTask {
            currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == highlighted.id })
        } else {
            currentIndex = visibleTasksInOrder.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex > 0 {
            let newTask = visibleTasksInOrder[currentIndex - 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTask = newTask
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil {
            // No selection in current list - select last task
            if let last = visibleTasksInOrder.last {
                selectedTaskIds = [last.id]
                highlightedTask = last
                lastSelectedTaskId = last.id
            }
        }
        // If at top (currentIndex == 0), do nothing (don't wrap around)
    }

    /// Move selection down
    private func moveSelectionDown(extendSelection: Bool = false) {
        guard !visibleTasksInOrder.isEmpty else { return }

        // When extending selection, use highlightedTask (cursor position)
        // Otherwise, use first selected task
        let currentIndex: Int?
        if extendSelection, let highlighted = highlightedTask {
            currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == highlighted.id })
        } else {
            currentIndex = visibleTasksInOrder.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex < visibleTasksInOrder.count - 1 {
            let newTask = visibleTasksInOrder[currentIndex + 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTask = newTask
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil {
            // No selection in current list - select first task
            if let first = visibleTasksInOrder.first {
                selectedTaskIds = [first.id]
                highlightedTask = first
                lastSelectedTaskId = first.id
            }
        }
        // If at bottom, do nothing (don't wrap around)
    }

    /// Delete selected tasks
    private func deleteSelectedTasks() {
        let tasksToDelete = selectedTasks
        guard !tasksToDelete.isEmpty else { return }

        // Clear selection first
        selectedTaskIds.removeAll()
        highlightedTask = nil
        expandedTask = nil
        lastSelectedTaskId = nil

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
        guard let task = highlightedTask else { return }
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
        guard let task = highlightedTask else { return }

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
        guard let task = highlightedTask else { return }
        guard let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }),
              currentIndex > 0 else { return }

        let taskAbove = visibleTasksInOrder[currentIndex - 1]
        let tempPriority = task.priority
        task.priority = taskAbove.priority
        taskAbove.priority = tempPriority

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    /// Move selected task down in priority (higher priority number = lower in list)
    private func moveSelectedPriorityDown() {
        guard let task = highlightedTask else { return }
        guard let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }),
              currentIndex < visibleTasksInOrder.count - 1 else { return }

        let taskBelow = visibleTasksInOrder[currentIndex + 1]
        let tempPriority = task.priority
        task.priority = taskBelow.priority
        taskBelow.priority = tempPriority

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
        if let expanded = expandedTask, expanded.id != task.id {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedTask = nil
            }
        }

        let now = Date()
        let isDoubleTap = lastTapTaskId == task.id && now.timeIntervalSince(lastTapTime) < 0.3

        if isDoubleTap {
            // Double-click: toggle expansion
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if expandedTask?.id == task.id {
                    expandedTask = nil
                } else {
                    expandedTask = task
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
            expandedTask: $expandedTask,
            selectedTaskIds: $selectedTaskIds,
            highlightedTask: $highlightedTask,
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
            Text("Are you sure you want to delete \(selectedTaskIds.count) \(selectedTaskIds.count == 1 ? "task" : "tasks")? This action cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .runTaskTriggered)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedTask = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteTasksTriggered)) { _ in
            if !selectedTaskIds.isEmpty {
                showDeleteConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .completeTaskTriggered)) { _ in
            markSelectedComplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelTaskTriggered)) { _ in
            markSelectedCancelled()
        }
        .onChange(of: highlightedTask) { _, newValue in
            // Skip sync if we're in the middle of clearing selection
            guard !isClearingSelection else { return }
            if let task = newValue, !selectedTaskIds.contains(task.id) {
                selectedTaskIds = [task.id]
                lastSelectedTaskId = task.id
            }
        }
        .onChange(of: selectedTaskIds) { _, newValue in
            // Skip sync if we're in the middle of clearing selection
            guard !isClearingSelection else { return }

            // Ensure highlightedTask stays in sync with selectedTaskIds
            // But don't reset it if it's already part of the selection (preserves cursor for multi-select)
            if let highlighted = highlightedTask, newValue.contains(highlighted.id) {
                // highlightedTask is valid and in selection - leave it alone
                return
            }

            // highlightedTask is not in selection - sync it to first selected task
            if let firstSelected = visibleTasksInOrder.first(where: { newValue.contains($0.id) }) {
                highlightedTask = firstSelected
            } else if newValue.isEmpty {
                highlightedTask = nil
            }
        }
        .onChange(of: expandedTask) { oldValue, newValue in
            // Restore focus to list when task collapses
            if oldValue != nil && newValue == nil {
                // Need async to let the view hierarchy update before restoring focus
                DispatchQueue.main.async {
                    isListFocused = true
                }
            }
        }
        .onChange(of: draggingTask) { _, newValue in
            // When a task starts being dragged, select it and unselect all others
            if let task = newValue {
                selectTask(task)
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
        if filter == .backlog {
            runningTasksSection
            upNextTasksSection
            backlogTasksSection
        } else {
            filteredTasksSection
        }
    }

    @ViewBuilder
    private var runningTasksSection: some View {
        if !runningTasks.isEmpty {
            sectionHeader("Running", count: runningTasks.count, color: .green)
            // Use composite ID (status + task.id) to force fresh view when task moves between sections
            ForEach(runningTasks, id: \.compositeId) { task in
                makeTaskRow(task: task, position: nil, isDraggable: false)
            }
        }
    }

    @ViewBuilder
    private var upNextTasksSection: some View {
        if !upNextTasks.isEmpty {
            sectionHeader("Up Next", count: upNextTasks.count, color: .orange)
            // Use composite ID to force fresh view when task moves between sections
            ForEach(Array(upNextTasks.enumerated()), id: \.element.compositeId) { index, task in
                makeDraggableTaskRow(task: task, position: index + 1)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: draggingTask?.id)
        }
    }

    @ViewBuilder
    private var backlogTasksSection: some View {
        sectionHeader("Backlog", count: backlogTasks.count, color: .secondary)
        if backlogTasks.isEmpty {
            emptySectionPlaceholder("No tasks in backlog")
        } else {
            // Use composite ID to force fresh view when task moves between sections
            ForEach(backlogTasks, id: \.compositeId) { task in
                makeDraggableTaskRow(task: task)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: draggingTask?.id)
        }

        // Drop zone at the end of the list to allow dropping to last position
        if draggingTask != nil && !backlogTasks.isEmpty {
            Color.clear
                .frame(height: 40)
                .dropDestination(for: String.self) { items, _ in
                    handleDropAtEnd(items: items)
                } isTargeted: { isTargeted in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        dropTargetTaskId = isTargeted ? UUID() : nil  // Use a dummy ID to show we're targeting end
                    }
                }
        }
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
            makeTaskRow(task: task, position: nil, isDraggable: false)
        }
    }

    private func makeTaskRow(task: WorkTask, position: Int?, isDraggable: Bool) -> some View {
        TaskRow(
            task: task,
            position: position,
            isHighlighted: isTaskSelected(task),
            isExpanded: expandedTask?.id == task.id,
            isDragTarget: false,
            queuedOnTerminalName: terminalNameFor(task),
            onTap: { modifiers in handleTap(on: task, modifiers: modifiers) },
            onRun: task.taskStatus.isPending ? { onStartTerminal?(task) } : nil,
            onToggleComplete: { toggleComplete(task) },
            onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onStatusChange: { handleTaskStatusChange(task) },
            onDelete: {
                selectTask(task)
                showDeleteConfirmation = true
            }
        )
    }

    @ViewBuilder
    private func makeDraggableTaskRow(task: WorkTask, position: Int? = nil) -> some View {
        let isDragging = draggingTask?.id == task.id

        // When dragging, hide the task visually but keep it in the hierarchy
        // Using opacity instead of conditional rendering preserves view identity
        TaskRow(
            task: task,
            position: position,
            isHighlighted: isTaskSelected(task),
            isExpanded: expandedTask?.id == task.id,
            isDragTarget: dropTargetTaskId == task.id,
            queuedOnTerminalName: terminalNameFor(task),
            onTap: { modifiers in handleTap(on: task, modifiers: modifiers) },
            onRun: { onStartTerminal?(task) },
            onToggleComplete: { toggleComplete(task) },
            onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onStatusChange: { handleTaskStatusChange(task) },
            onDelete: {
                selectTask(task)
                showDeleteConfirmation = true
            }
        )
        .opacity(isDragging ? 0 : 1)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .draggable(task.id.uuidString) {
            dragPreview(for: task)
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items: items, targetTask: task)
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetTaskId = isTargeted ? task.id : nil
            }
        }
    }

    private func dragPreview(for task: WorkTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(task.title)
                .font(.system(size: 14))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.25))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .onAppear {
            draggingTask = task
            // Select the dragged task (clears other selections)
            selectTask(task)
        }
    }

    private func handleDrop(items: [String], targetTask: WorkTask) -> Bool {
        guard let droppedIdString = items.first,
              let droppedId = UUID(uuidString: droppedIdString) else {
            return false
        }

        // Find the dropped task in the same section as the target
        let tasksInSection = targetTask.taskStatus == .queued ? upNextTasks : backlogTasks
        guard let droppedTask = tasksInSection.first(where: { $0.id == droppedId }),
              droppedTask.id != targetTask.id else {
            return false
        }
        reorderTask(droppedTask, before: targetTask)
        return true
    }

    private func handleDropAtEnd(items: [String]) -> Bool {
        guard let droppedIdString = items.first,
              let droppedId = UUID(uuidString: droppedIdString) else {
            return false
        }

        // Look in both sections to find the dragged task
        if let droppedTask = upNextTasks.first(where: { $0.id == droppedId }) {
            reorderTaskToEnd(droppedTask)
            return true
        }
        if let droppedTask = backlogTasks.first(where: { $0.id == droppedId }) {
            reorderTaskToEnd(droppedTask)
            return true
        }
        return false
    }

    private var backgroundView: some View {
        (colorScheme == .dark ? Color(white: 27.0 / 255.0) : Color.white)
            .onTapGesture {
                clearSelection()
            }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedTask = nil
        }
        isClearingSelection = true
        highlightedTask = nil
        selectedTaskIds.removeAll()
        DispatchQueue.main.async {
            isClearingSelection = false
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
        .padding(.top, 16)
        .padding(.bottom, 4)
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

    private func reorderTask(_ movedTask: WorkTask, before targetTask: WorkTask) {
        // Clear drag state
        draggingTask = nil
        dropTargetTaskId = nil

        // Use the correct task list based on the moved task's status
        // This ensures reordering within a section works correctly
        var tasks: [WorkTask]
        if movedTask.taskStatus == .queued {
            tasks = upNextTasks
        } else {
            tasks = backlogTasks
        }

        // Find indices
        guard let fromIndex = tasks.firstIndex(where: { $0.id == movedTask.id }),
              let toIndex = tasks.firstIndex(where: { $0.id == targetTask.id }) else {
            return
        }

        // Don't do anything if same position
        if fromIndex == toIndex { return }

        // Remove from current position and insert at new position
        tasks.remove(at: fromIndex)
        let insertIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        tasks.insert(movedTask, at: insertIndex)

        // Reassign priorities based on new order
        // Use increments of 10 to leave room for future insertions
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            for (index, task) in tasks.enumerated() {
                let newPriority = (index + 1) * 10
                if task.priority != newPriority {
                    task.updatePriority(newPriority)
                }
            }
        }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private func reorderTaskToEnd(_ movedTask: WorkTask) {
        // Clear drag state
        draggingTask = nil
        dropTargetTaskId = nil

        // Use the correct task list based on the moved task's status
        var tasks: [WorkTask]
        if movedTask.taskStatus == .queued {
            tasks = upNextTasks
        } else {
            tasks = backlogTasks
        }

        // Find index of moved task
        guard let fromIndex = tasks.firstIndex(where: { $0.id == movedTask.id }) else {
            return
        }

        // Don't do anything if already at end
        if fromIndex == tasks.count - 1 { return }

        // Remove from current position and append to end
        tasks.remove(at: fromIndex)
        tasks.append(movedTask)

        // Reassign priorities based on new order
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            for (index, task) in tasks.enumerated() {
                let newPriority = (index + 1) * 10
                if task.priority != newPriority {
                    task.updatePriority(newPriority)
                }
            }
        }

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
    @Binding var expandedTask: WorkTask?
    @Binding var selectedTaskIds: Set<UUID>
    @Binding var highlightedTask: WorkTask?
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
                if expandedTask != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTask = nil
                    }
                    return .handled
                }
                if !selectedTaskIds.isEmpty {
                    highlightedTask = nil
                    selectedTaskIds.removeAll()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                // Don't capture arrow keys when a task is expanded (let text fields handle them)
                guard expandedTask == nil else { return .ignored }

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
                guard expandedTask == nil else { return .ignored }

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
                guard expandedTask == nil else { return .ignored }

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
    var onTap: ((EventModifiers) -> Void)?
    var onRun: (() -> Void)?
    var onToggleComplete: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onDelete: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
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
                    // Static text (always present for stable layout)
                    Text(task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isCompleted ? .tertiary : .primary)
                        .strikethrough(isCompleted, color: .secondary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(showNotes ? 0 : 1)

                    // Editable field (appears after expand animation)
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
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .animation(.easeIn(duration: 0.12), value: showNotes)
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
                .animation(.easeIn(duration: 0.12), value: showNotes)
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
                .animation(.easeIn(duration: 0.12), value: showNotes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .fill(isExpanded ? Color(white: 0.20) : (isHighlighted ? Color.orange.opacity(0.08) : .clear))
                .shadow(color: isExpanded ? .black.opacity(0.3) : .clear, radius: isExpanded ? 8 : 0, y: isExpanded ? 4 : 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .strokeBorder(Color.blue.opacity(isFileDropTarget ? 0.6 : 0), lineWidth: 2)
        )
        .animation(.easeInOut(duration: 0.15), value: isFileDropTarget)
        .padding(.top, isDragTarget ? 44 : 0)
        .overlay(alignment: .top) {
            if isDragTarget {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x14 / 255.0))
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragTarget)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let onTap = onTap else { return }
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.shift) {
                onTap(.shift)
            } else if modifiers.contains(.command) {
                onTap(.command)
            } else {
                onTap([])
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.top, isExpanded ? 30 : 0)
        .padding(.bottom, isExpanded ? 45 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showNotes = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isTitleFocused = true
                        isDescriptionFocused = false
                    }
                }
            } else {
                isTitleFocused = false
                isDescriptionFocused = false
                showNotes = false
            }
        }
        .onChange(of: task.taskStatus) { oldStatus, newStatus in
            // Collapse and notify when status changes (e.g., running -> queued)
            if oldStatus != newStatus {
                onStatusChange?()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTarget) { providers in
            handleFileDrop(providers: providers)
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

/// Claude icon that pulses from white to orange, shows checkmark on hover
struct RunningTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    var onMarkComplete: (() -> Void)?

    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            if isHovering {
                // Checkmark circle on hover
                Button(action: { onMarkComplete?() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.45, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Pulsing Claude icon - plain orange
                ClaudeShape()
                    .fill(Color.orange.opacity(0.7 + pulsePhase * 0.3))
                    .frame(width: size * 0.85, height: size * 0.6)
                    .shadow(color: .orange.opacity(pulsePhase * 0.4), radius: 3)
                    .frame(width: size, height: size)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsePhase = 1.0
            }
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
