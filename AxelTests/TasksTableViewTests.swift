import XCTest
@testable import Axel

final class TasksTableViewTests: XCTestCase {
    func testStructuralChangeDetectsHeaderCountChange() {
        let oldRows: [TaskTableRow] = [
            .header("Running", 1, nil, .running),
            .task(UUID(), .running, nil)
        ]
        let newRows: [TaskTableRow] = [
            .header("Running", 2, nil, .running),
            .task(UUID(), .running, nil),
            .task(UUID(), .running, nil)
        ]

        XCTAssertTrue(TaskTableView.hasStructuralChange(old: oldRows, new: newRows))
    }

    func testStructuralChangeDetectsStatusOrTitleChange() {
        let oldRows: [TaskTableRow] = [
            .header("Running", 1, nil, .running),
            .task(UUID(), .running, nil)
        ]
        let newRows: [TaskTableRow] = [
            .header("Backlog", 1, nil, .backlog),
            .task(UUID(), .backlog, nil)
        ]

        XCTAssertTrue(TaskTableView.hasStructuralChange(old: oldRows, new: newRows))
    }

    func testStructuralChangeIgnoresTaskReorder() {
        let taskA = UUID()
        let taskB = UUID()
        let oldRows: [TaskTableRow] = [
            .header("Running", 2, nil, .running),
            .task(taskA, .running, nil),
            .task(taskB, .running, nil)
        ]
        let newRows: [TaskTableRow] = [
            .header("Running", 2, nil, .running),
            .task(taskB, .running, nil),
            .task(taskA, .running, nil)
        ]

        XCTAssertFalse(TaskTableView.hasStructuralChange(old: oldRows, new: newRows))
    }
}
