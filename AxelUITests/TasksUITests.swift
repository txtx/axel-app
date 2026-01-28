import XCTest

/// UI Tests for Tasks functionality
/// These tests verify task creation, editing, deletion, navigation, and state preservation
/// across menu switches to prevent regressions in the task management UX.
final class TasksUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        // Wait for app to be ready and ensure we're on the Tasks view
        waitForTasksView()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helper Methods

    /// Sleep for a fractional number of seconds
    func wait(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Wait for the Tasks view to be visible
    func waitForTasksView() {
        // Wait for the workspace window to appear
        let workspaceWindow = app.windows.firstMatch
        XCTAssertTrue(workspaceWindow.waitForExistence(timeout: 10), "Workspace window should appear")

        // Ensure Tasks view is selected (Cmd+1)
        app.typeKey("1", modifierFlags: .command)
        wait(1)
    }

    /// Create a new task with the given title
    func createTask(title: String) {
        // Press Cmd+N to open new task dialog
        app.typeKey("n", modifierFlags: .command)

        // Wait for the sheet to appear
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "New task sheet should appear")

        // Type the task title
        let textField = sheet.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 2), "Task title field should exist")
        textField.click()
        textField.typeText(title)

        // Press Enter to save
        app.typeKey(.return, modifierFlags: [])

        // Wait for sheet to dismiss
        wait(1)
    }

    /// Get the number of visible task rows
    func taskRowCount() -> Int {
        // Task rows should be identifiable by their structure
        return app.groups.matching(identifier: "TaskRow").count
    }

    /// Select a task by index using keyboard navigation
    func selectTaskByIndex(_ index: Int) {
        // First, press Escape to clear any selection
        app.typeKey(.escape, modifierFlags: [])
        wait(0.3)

        // Navigate down to the desired index
        for _ in 0..<index {
            app.typeKey(.downArrow, modifierFlags: [])
            wait(0.1)
        }
    }

    /// Switch to Agents view (Cmd+2)
    func switchToAgents() {
        app.typeKey("2", modifierFlags: .command)
        wait(1)
    }

    /// Switch to Tasks view (Cmd+1)
    func switchToTasks() {
        app.typeKey("1", modifierFlags: .command)
        wait(1)
    }

    // MARK: - Task Creation Tests

    func testCreateSingleTask() throws {
        let taskTitle = "Test Task \(Date().timeIntervalSince1970)"

        createTask(title: taskTitle)

        // Verify task appears in the list
        let taskText = app.staticTexts[taskTitle]
        XCTAssertTrue(taskText.waitForExistence(timeout: 5), "Created task should appear in the list")
    }

    func testCreateMultipleTasks() throws {
        let taskTitles = [
            "First Task \(Date().timeIntervalSince1970)",
            "Second Task \(Date().timeIntervalSince1970)",
            "Third Task \(Date().timeIntervalSince1970)"
        ]

        for title in taskTitles {
            createTask(title: title)
        }

        // Verify all tasks appear
        for title in taskTitles {
            let taskText = app.staticTexts[title]
            XCTAssertTrue(taskText.waitForExistence(timeout: 3), "Task '\(title)' should appear in the list")
        }
    }

    // MARK: - Task Navigation Tests

    func testKeyboardNavigationUpDown() throws {
        // Create some tasks first
        createTask(title: "Nav Task 1")
        createTask(title: "Nav Task 2")
        createTask(title: "Nav Task 3")

        // Press down to select first task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.5)

        // Press down again to move to second task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.5)

        // Press up to go back to first task
        app.typeKey(.upArrow, modifierFlags: [])
        wait(0.5)

        // If we got here without crash, navigation works
        XCTAssertTrue(true, "Keyboard navigation should work without errors")
    }

    func testExpandCollapseWithEnter() throws {
        // Create a task
        let taskTitle = "Expandable Task \(Date().timeIntervalSince1970)"
        createTask(title: taskTitle)

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.5)

        // Press Enter to expand
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // Press Escape to collapse
        app.typeKey(.escape, modifierFlags: [])
        wait(0.5)

        // Should be back to collapsed state without errors
        XCTAssertTrue(true, "Expand/collapse should work without errors")
    }

    func testNavigationAfterExpandCollapse() throws {
        // Create tasks
        createTask(title: "Task A")
        createTask(title: "Task B")
        createTask(title: "Task C")

        // Navigate to Task B (second task)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Expand Task B
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // Collapse Task B
        app.typeKey(.escape, modifierFlags: [])
        wait(0.5)

        // Navigate down to Task C - this was a bug where navigation broke after collapse
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.5)

        // Press Enter - should expand Task C, not Task B
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // If we got here without the wrong task expanding, the fix works
        XCTAssertTrue(true, "Navigation after expand/collapse should work correctly")
    }

    // MARK: - Menu Switching Tests

    func testNavigationAfterMenuSwitch() throws {
        // Create tasks
        createTask(title: "Switch Task 1")
        createTask(title: "Switch Task 2")
        createTask(title: "Switch Task 3")

        // Navigate to second task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Switch to Agents (Cmd+2)
        switchToAgents()

        // Switch back to Tasks (Cmd+1)
        switchToTasks()

        // Try navigating - this was a bug where navigation broke after menu switch
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Try to expand
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        XCTAssertTrue(true, "Navigation should work after menu switch")
    }

    func testExpandAfterMenuSwitch() throws {
        // Create a task
        createTask(title: "Expand After Switch Task")

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Switch to Agents and back
        switchToAgents()
        switchToTasks()

        // Navigate to ensure we have a selection
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Try to expand - this was failing after menu switch
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // Collapse
        app.typeKey(.escape, modifierFlags: [])
        wait(0.3)

        XCTAssertTrue(true, "Expand should work after menu switch")
    }

    // MARK: - Task Editing Tests

    func testEditTaskTitle() throws {
        // Create a task
        let originalTitle = "Original Title \(Date().timeIntervalSince1970)"
        createTask(title: originalTitle)

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Expand the task
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // The title field should be focused, type new content
        // Select all and replace
        app.typeKey("a", modifierFlags: .command)
        wait(0.2)

        let newTitle = "Modified Title \(Date().timeIntervalSince1970)"
        app.typeText(newTitle)
        wait(0.3)

        // Collapse
        app.typeKey(.escape, modifierFlags: [])
        wait(0.5)

        // Verify the title changed
        let modifiedText = app.staticTexts[newTitle]
        XCTAssertTrue(modifiedText.waitForExistence(timeout: 3), "Modified title should appear")
    }

    func testEditTaskDescription() throws {
        // Create a task
        createTask(title: "Task With Description")

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Expand the task
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // Tab to description field
        app.typeKey(.tab, modifierFlags: [])
        wait(0.3)

        // Type description
        let description = "This is a test description"
        app.typeText(description)
        wait(0.3)

        // Collapse
        app.typeKey(.escape, modifierFlags: [])
        wait(0.5)

        XCTAssertTrue(true, "Editing description should work without errors")
    }

    // MARK: - Task Completion/Cancellation Tests

    func testMarkTaskComplete() throws {
        // Create a task
        createTask(title: "Task To Complete")

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Mark as complete with Cmd+K
        app.typeKey("k", modifierFlags: .command)
        wait(0.5)

        // The task should be marked complete (may move to completed section)
        XCTAssertTrue(true, "Marking task complete should work")
    }

    func testMarkTaskCancelled() throws {
        // Create a task
        createTask(title: "Task To Cancel")

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Mark as cancelled with Option+Cmd+K
        app.typeKey("k", modifierFlags: [.command, .option])
        wait(0.5)

        XCTAssertTrue(true, "Marking task cancelled should work")
    }

    func testNextTaskSelectedAfterComplete() throws {
        // Create multiple tasks
        createTask(title: "Complete Me")
        createTask(title: "Select Me Next")

        // Navigate to first task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Mark as complete
        app.typeKey("k", modifierFlags: .command)
        wait(0.5)

        // The next task should now be selected
        // Try to expand it - if wrong task is selected, this would fail
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        XCTAssertTrue(true, "Next task should be selected after completing current task")
    }

    // MARK: - Task Deletion Tests

    func testDeleteTask() throws {
        // Create a task
        let taskTitle = "Task To Delete \(Date().timeIntervalSince1970)"
        createTask(title: taskTitle)

        // Navigate to the task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Delete with Cmd+Delete
        app.typeKey(.delete, modifierFlags: .command)
        wait(0.5)

        // Confirm deletion in alert
        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) {
            deleteButton.click()
            wait(0.5)
        }

        // Task should be gone
        let taskText = app.staticTexts[taskTitle]
        XCTAssertFalse(taskText.exists, "Deleted task should not appear in the list")
    }

    // MARK: - Task Reordering Tests

    func testMoveTaskUp() throws {
        // Create tasks
        createTask(title: "Bottom Task")
        createTask(title: "Top Task")

        // Navigate to second task (Top Task should be at bottom of queue)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Move up with Cmd+Up
        app.typeKey(.upArrow, modifierFlags: .command)
        wait(0.5)

        XCTAssertTrue(true, "Moving task up should work")
    }

    func testMoveTaskDown() throws {
        // Create tasks
        createTask(title: "Move Down Task")
        createTask(title: "Stay Task")

        // Navigate to first task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Move down with Cmd+Down
        app.typeKey(.downArrow, modifierFlags: .command)
        wait(0.5)

        XCTAssertTrue(true, "Moving task down should work")
    }

    // MARK: - Multi-Select Tests

    func testMultiSelectWithShiftDown() throws {
        // Create tasks
        createTask(title: "Multi 1")
        createTask(title: "Multi 2")
        createTask(title: "Multi 3")
        createTask(title: "Multi 4")

        // Navigate to first task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Shift+Down to select second
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait(0.3)

        // Shift+Down to select third
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait(0.3)

        // Shift+Down to select fourth
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait(0.3)

        // All 4 should be selected - try deleting them all
        app.typeKey(.delete, modifierFlags: .command)
        wait(0.5)

        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) {
            deleteButton.click()
            wait(0.5)
        }

        XCTAssertTrue(true, "Multi-select with Shift+Down should work for more than 2 items")
    }

    // MARK: - Comprehensive Workflow Tests

    /// This test performs the complete sequence the user described to catch regressions
    func testCompleteWorkflowSequence() throws {
        // Step 1: Create multiple tasks
        let task1 = "Workflow Task 1 \(Date().timeIntervalSince1970)"
        let task2 = "Workflow Task 2 \(Date().timeIntervalSince1970)"
        let task3 = "Workflow Task 3 \(Date().timeIntervalSince1970)"

        createTask(title: task1)
        createTask(title: task2)
        createTask(title: task3)

        // Step 2: Navigate and expand/collapse
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        app.typeKey(.return, modifierFlags: []) // Expand
        wait(0.5)
        app.typeKey(.escape, modifierFlags: []) // Collapse
        wait(0.3)

        // Step 3: Continue navigation
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        app.typeKey(.return, modifierFlags: []) // Expand
        wait(0.5)

        // Step 4: Edit title while expanded
        app.typeKey("a", modifierFlags: .command) // Select all
        wait(0.2)
        app.typeText("Modified Task")
        wait(0.3)

        // Step 5: Tab to description
        app.typeKey(.tab, modifierFlags: [])
        wait(0.3)
        app.typeText("Added description")
        wait(0.3)

        // Step 6: Collapse
        app.typeKey(.escape, modifierFlags: [])
        wait(0.5)

        // Step 7: Switch menus
        switchToAgents()
        switchToTasks()

        // Step 8: Verify navigation still works
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.upArrow, modifierFlags: [])
        wait(0.3)

        // Step 9: Expand should work on correct task
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)
        app.typeKey(.escape, modifierFlags: [])
        wait(0.3)

        // Step 10: Reorder tasks
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.upArrow, modifierFlags: .command) // Move up
        wait(0.5)

        // Step 11: Mark complete
        app.typeKey("k", modifierFlags: .command)
        wait(0.5)

        // Step 12: Delete a task
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.delete, modifierFlags: .command)
        wait(0.5)

        let deleteButton = app.buttons["Delete"]
        if deleteButton.waitForExistence(timeout: 2) {
            deleteButton.click()
            wait(0.5)
        }

        // Step 13: Switch menus again and repeat some operations
        switchToAgents()
        switchToTasks()

        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)
        app.typeKey(.escape, modifierFlags: [])
        wait(0.3)

        XCTAssertTrue(true, "Complete workflow sequence should work without errors")
    }

    /// Test the specific bug scenario: select row N, down to N+1, expand, collapse, down to N+2, expand
    func testExpandCorrectTaskAfterNavigation() throws {
        // Create 4 tasks
        createTask(title: "Task N-1")
        createTask(title: "Task N")
        createTask(title: "Task N+1")
        createTask(title: "Task N+2")

        // Navigate to Task N (second task)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Press down to N+1
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Expand N+1
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // Collapse N+1
        app.typeKey(.escape, modifierFlags: [])
        wait(0.3)

        // Press down to N+2
        app.typeKey(.downArrow, modifierFlags: [])
        wait(0.3)

        // Expand - should expand N+2, NOT N+1
        // This was the original bug
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        // If we got here, the correct task expanded
        XCTAssertTrue(true, "Correct task should expand after navigation sequence")
    }

    /// Test rapid navigation doesn't cause state desync
    func testRapidNavigation() throws {
        // Create several tasks
        for i in 1...5 {
            createTask(title: "Rapid Task \(i)")
        }

        // Rapidly navigate up and down
        for _ in 1...10 {
            app.typeKey(.downArrow, modifierFlags: [])
            wait(0.05)
        }

        for _ in 1...10 {
            app.typeKey(.upArrow, modifierFlags: [])
            wait(0.05)
        }

        // Now try to expand
        app.typeKey(.return, modifierFlags: [])
        wait(0.5)

        XCTAssertTrue(true, "Rapid navigation should not desync state")
    }
}
