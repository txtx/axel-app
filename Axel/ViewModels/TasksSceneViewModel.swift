import Foundation

@MainActor
@Observable
final class TasksSceneViewModel {
    struct TaskSections {
        let running: [WorkTask]
        let upNext: [WorkTask]
        let backlog: [WorkTask]
        let allFiltered: [WorkTask]
        let visibleInOrder: [WorkTask]
    }

    var expandedTaskId: UUID?
    var draggingTaskId: UUID?
    var dropTargetTaskId: UUID?
    var selectedTaskIds: Set<UUID> = []
    var highlightedTaskId: UUID?
    var lastSelectedTaskId: UUID?
    var isClearingSelection = false

    func sections(for tasks: [WorkTask], filter: TaskFilter) -> TaskSections {
        let sorted = sortTasks(tasks)
        let running = sorted.filter { $0.taskStatus == .running }
        let upNext = sorted.filter { $0.taskStatus == .queued }
        let backlog = sorted.filter { $0.taskStatus == .backlog }

        let allFiltered: [WorkTask]
        switch filter {
        case .backlog:
            allFiltered = backlog
        case .upNext:
            allFiltered = upNext
        case .running:
            allFiltered = running
        case .completed:
            allFiltered = sorted.filter { $0.taskStatus == .completed }
        case .all:
            allFiltered = sorted
        }

        let visibleInOrder: [WorkTask]
        if filter == .backlog {
            visibleInOrder = running + upNext + backlog
        } else {
            visibleInOrder = allFiltered
        }

        return TaskSections(
            running: running,
            upNext: upNext,
            backlog: backlog,
            allFiltered: allFiltered,
            visibleInOrder: visibleInOrder
        )
    }

    func isTaskSelected(_ task: WorkTask) -> Bool {
        selectedTaskIds.contains(task.id)
    }

    func highlightedTask(in visibleTasks: [WorkTask]) -> WorkTask? {
        guard let highlightedTaskId else { return nil }
        return visibleTasks.first { $0.id == highlightedTaskId }
    }

    func selectTask(_ task: WorkTask) {
        selectedTaskIds = [task.id]
        highlightedTaskId = task.id
        lastSelectedTaskId = task.id
    }

    func toggleTaskSelection(_ task: WorkTask, visibleTasks: [WorkTask]) {
        if selectedTaskIds.contains(task.id) {
            selectedTaskIds.remove(task.id)
            if selectedTaskIds.isEmpty {
                highlightedTaskId = nil
                lastSelectedTaskId = nil
            } else if highlightedTaskId == task.id {
                highlightedTaskId = visibleTasks.first { selectedTaskIds.contains($0.id) }?.id
            }
        } else {
            selectedTaskIds.insert(task.id)
            highlightedTaskId = task.id
            lastSelectedTaskId = task.id
        }
    }

    func extendSelectionTo(_ task: WorkTask, visibleTasks: [WorkTask]) {
        guard let lastId = lastSelectedTaskId,
              let lastIndex = visibleTasks.firstIndex(where: { $0.id == lastId }),
              let targetIndex = visibleTasks.firstIndex(where: { $0.id == task.id }) else {
            selectTask(task)
            return
        }

        let range = lastIndex < targetIndex ? lastIndex...targetIndex : targetIndex...lastIndex
        for i in range {
            selectedTaskIds.insert(visibleTasks[i].id)
        }
        highlightedTaskId = task.id
    }

    func selectAll(visibleTasks: [WorkTask]) {
        selectedTaskIds = Set(visibleTasks.map(\.id))
        highlightedTaskId = visibleTasks.first?.id
    }

    func syncSelectionState(visibleTasks: [WorkTask]) {
        guard !isClearingSelection else { return }

        if let selectedTask = visibleTasks.first(where: { selectedTaskIds.contains($0.id) }) {
            highlightedTaskId = selectedTask.id
        } else if let highlightedTaskId,
                  visibleTasks.contains(where: { $0.id == highlightedTaskId }) {
            selectedTaskIds = [highlightedTaskId]
            lastSelectedTaskId = highlightedTaskId
        } else {
            highlightedTaskId = nil
            selectedTaskIds.removeAll()
            lastSelectedTaskId = nil
        }
    }

    func applyExternalHighlightedTaskId(_ taskId: UUID?, visibleTasks: [WorkTask]) {
        guard !isClearingSelection else { return }

        if let taskId {
            if selectedTaskIds != [taskId] {
                selectedTaskIds = [taskId]
            }
            highlightedTaskId = taskId
            lastSelectedTaskId = taskId
        } else {
            highlightedTaskId = nil
            selectedTaskIds.removeAll()
            lastSelectedTaskId = nil
        }
    }

    func cleanupSelectionState(removedTaskIds: Set<UUID>, visibleTasks: [WorkTask]) {
        selectedTaskIds.subtract(removedTaskIds)

        if let currentHighlightedId = highlightedTaskId, removedTaskIds.contains(currentHighlightedId) {
            highlightedTaskId = visibleTasks.first(where: { selectedTaskIds.contains($0.id) })?.id
        }

        if let lastSelectedTaskId, removedTaskIds.contains(lastSelectedTaskId) {
            self.lastSelectedTaskId = selectedTaskIds.first
        }

        if let expandedTaskId, removedTaskIds.contains(expandedTaskId) {
            self.expandedTaskId = nil
        }
    }

    func handleTaskStatusChange(taskId: UUID) {
        expandedTaskId = nil
        selectedTaskIds.remove(taskId)
        if highlightedTaskId == taskId {
            highlightedTaskId = nil
        }
        if lastSelectedTaskId == taskId {
            lastSelectedTaskId = nil
        }
    }

    func toggleSelectedTaskExpansion(visibleTasks: [WorkTask]) {
        guard let task = visibleTasks.first(where: { selectedTaskIds.contains($0.id) }) else {
            return
        }

        highlightedTaskId = task.id
        expandedTaskId = (expandedTaskId == task.id) ? nil : task.id
    }

    func moveSelectionUp(visibleTasks: [WorkTask], extendSelection: Bool) {
        guard !visibleTasks.isEmpty else { return }

        let currentIndex: Int?
        if extendSelection, let highlightedTaskId {
            currentIndex = visibleTasks.firstIndex(where: { $0.id == highlightedTaskId })
        } else {
            currentIndex = visibleTasks.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex > 0 {
            let newTask = visibleTasks[currentIndex - 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTaskId = newTask.id
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil, let last = visibleTasks.last {
            selectedTaskIds = [last.id]
            highlightedTaskId = last.id
            lastSelectedTaskId = last.id
        }
    }

    func moveSelectionDown(visibleTasks: [WorkTask], extendSelection: Bool) {
        guard !visibleTasks.isEmpty else { return }

        let currentIndex: Int?
        if extendSelection, let highlightedTaskId {
            currentIndex = visibleTasks.firstIndex(where: { $0.id == highlightedTaskId })
        } else {
            currentIndex = visibleTasks.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex < visibleTasks.count - 1 {
            let newTask = visibleTasks[currentIndex + 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTaskId = newTask.id
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil, let first = visibleTasks.first {
            selectedTaskIds = [first.id]
            highlightedTaskId = first.id
            lastSelectedTaskId = first.id
        }
    }

    func clearSelection() {
        isClearingSelection = true
        expandedTaskId = nil
        highlightedTaskId = nil
        selectedTaskIds.removeAll()
        lastSelectedTaskId = nil
    }

    func endClearingSelection() {
        isClearingSelection = false
    }

    func beginDragging(task: WorkTask) {
        draggingTaskId = task.id
        selectTask(task)
    }

    func endDragging() {
        draggingTaskId = nil
        dropTargetTaskId = nil
    }

    func reorderTask(_ movedTask: WorkTask, before targetTask: WorkTask, tasksInSection: [WorkTask]) -> [WorkTask] {
        guard let fromIndex = tasksInSection.firstIndex(where: { $0.id == movedTask.id }),
              let toIndex = tasksInSection.firstIndex(where: { $0.id == targetTask.id }),
              fromIndex != toIndex else {
            return tasksInSection
        }

        var reordered = tasksInSection
        reordered.remove(at: fromIndex)
        let insertIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        reordered.insert(movedTask, at: insertIndex)
        return reordered
    }

    func reorderTaskToEnd(_ movedTask: WorkTask, tasksInSection: [WorkTask]) -> [WorkTask] {
        guard let fromIndex = tasksInSection.firstIndex(where: { $0.id == movedTask.id }) else {
            return tasksInSection
        }
        guard fromIndex != tasksInSection.count - 1 else {
            return tasksInSection
        }

        var reordered = tasksInSection
        reordered.remove(at: fromIndex)
        reordered.append(movedTask)
        return reordered
    }

    func moveTask(_ task: WorkTask, direction: Int, tasksInSection: [WorkTask]) -> [WorkTask] {
        guard let currentIndex = tasksInSection.firstIndex(where: { $0.id == task.id }) else {
            return tasksInSection
        }
        let newIndex = currentIndex + direction
        guard newIndex >= 0 && newIndex < tasksInSection.count else {
            return tasksInSection
        }

        var reordered = tasksInSection
        reordered.remove(at: currentIndex)
        reordered.insert(task, at: newIndex)
        return reordered
    }

    func applyPriorities(to tasks: [WorkTask], step: Int = 10) -> Bool {
        var changed = false
        for (index, task) in tasks.enumerated() {
            let newPriority = (index + 1) * step
            if task.priority != newPriority {
                task.updatePriority(newPriority)
                changed = true
            }
        }
        return changed
    }

    private func sortTasks(_ tasks: [WorkTask]) -> [WorkTask] {
        tasks.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
