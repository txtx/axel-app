import XCTest
@testable import Axel

@MainActor
final class TasksSceneViewModelTests: XCTestCase {
    func testSectionsSortsByPriorityThenCreatedAt() {
        let taskA = WorkTask(title: "A")
        taskA.priority = 10
        taskA.createdAt = Date(timeIntervalSince1970: 200)

        let taskB = WorkTask(title: "B")
        taskB.priority = 10
        taskB.createdAt = Date(timeIntervalSince1970: 100)

        let viewModel = TasksSceneViewModel()
        let sections = viewModel.sections(for: [taskA, taskB], filter: .backlog)

        XCTAssertEqual(sections.backlog.map(\.id), [taskB.id, taskA.id])
    }

    func testReorderTaskUpdatesPriorities() {
        let task1 = WorkTask(title: "Task 1")
        task1.priority = 10
        let task2 = WorkTask(title: "Task 2")
        task2.priority = 20
        let task3 = WorkTask(title: "Task 3")
        task3.priority = 30

        let viewModel = TasksSceneViewModel()
        let reordered = viewModel.reorderTask(task3, before: task2, tasksInSection: [task1, task2, task3])
        XCTAssertEqual(reordered.map(\.id), [task1.id, task3.id, task2.id])

        let didChange = viewModel.applyPriorities(to: reordered)
        XCTAssertTrue(didChange)
        XCTAssertEqual(task1.priority, 10)
        XCTAssertEqual(task3.priority, 20)
        XCTAssertEqual(task2.priority, 30)
    }

    func testSelectionAndExtension() {
        let task1 = WorkTask(title: "Task 1")
        let task2 = WorkTask(title: "Task 2")
        let task3 = WorkTask(title: "Task 3")
        let visible = [task1, task2, task3]

        let viewModel = TasksSceneViewModel()
        viewModel.selectTask(task1)
        XCTAssertEqual(viewModel.selectedTaskIds, [task1.id])
        XCTAssertEqual(viewModel.highlightedTaskId, task1.id)

        viewModel.extendSelectionTo(task3, visibleTasks: visible)
        XCTAssertTrue(viewModel.selectedTaskIds.contains(task1.id))
        XCTAssertTrue(viewModel.selectedTaskIds.contains(task2.id))
        XCTAssertTrue(viewModel.selectedTaskIds.contains(task3.id))
        XCTAssertEqual(viewModel.highlightedTaskId, task3.id)
    }

    func testMoveSelectionUpAndDown() {
        let task1 = WorkTask(title: "Task 1")
        let task2 = WorkTask(title: "Task 2")
        let task3 = WorkTask(title: "Task 3")
        let visible = [task1, task2, task3]

        let viewModel = TasksSceneViewModel()
        viewModel.selectTask(task2)
        viewModel.moveSelectionUp(visibleTasks: visible, extendSelection: false)
        XCTAssertEqual(viewModel.highlightedTaskId, task1.id)

        viewModel.moveSelectionDown(visibleTasks: visible, extendSelection: false)
        XCTAssertEqual(viewModel.highlightedTaskId, task2.id)
    }
}
