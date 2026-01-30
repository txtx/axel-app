import XCTest
import SwiftData
@testable import Axel

// MARK: - Mock Task Queue

@MainActor
final class MockTaskQueue: TaskQueueing {
    var terminalQueues: [String: [UUID]] = [:]

    // Track method calls for verification
    var enqueueCallCount = 0
    var dequeueCallCount = 0
    var lastEnqueuedTaskId: UUID?
    var lastEnqueuedPaneId: String?
    var lastDequeuedPaneId: String?

    func enqueue(taskId: UUID, onTerminal paneId: String) {
        enqueueCallCount += 1
        lastEnqueuedTaskId = taskId
        lastEnqueuedPaneId = paneId

        if terminalQueues[paneId] == nil {
            terminalQueues[paneId] = []
        }
        if !terminalQueues[paneId]!.contains(taskId) {
            terminalQueues[paneId]!.append(taskId)
        }
    }

    func dequeue(fromTerminal paneId: String) -> UUID? {
        dequeueCallCount += 1
        lastDequeuedPaneId = paneId

        guard var queue = terminalQueues[paneId], !queue.isEmpty else {
            return nil
        }
        let taskId = queue.removeFirst()
        terminalQueues[paneId] = queue
        return taskId
    }

    func peek(terminal paneId: String) -> UUID? {
        terminalQueues[paneId]?.first
    }

    func tasksQueued(onTerminal paneId: String) -> [UUID] {
        terminalQueues[paneId] ?? []
    }

    func terminalForTask(taskId: UUID) -> String? {
        for (paneId, queue) in terminalQueues {
            if queue.contains(taskId) {
                return paneId
            }
        }
        return nil
    }

    func queueCount(forTerminal paneId: String) -> Int {
        terminalQueues[paneId]?.count ?? 0
    }

    func reorder(taskId: UUID, toIndex newIndex: Int, inTerminal paneId: String) {
        guard var queue = terminalQueues[paneId],
              let currentIndex = queue.firstIndex(of: taskId),
              newIndex >= 0 && newIndex < queue.count else {
            return
        }
        queue.remove(at: currentIndex)
        queue.insert(taskId, at: newIndex)
        terminalQueues[paneId] = queue
    }

    @discardableResult
    func remove(taskId: UUID, fromTerminal paneId: String) -> Bool {
        guard var queue = terminalQueues[paneId],
              let index = queue.firstIndex(of: taskId) else {
            return false
        }
        queue.remove(at: index)
        terminalQueues[paneId] = queue
        return true
    }

    @discardableResult
    func removeFromAnyTerminal(taskId: UUID) -> String? {
        for (paneId, var queue) in terminalQueues {
            if let index = queue.firstIndex(of: taskId) {
                queue.remove(at: index)
                terminalQueues[paneId] = queue
                return paneId
            }
        }
        return nil
    }

    @discardableResult
    func clearQueue(forTerminal paneId: String) -> [UUID] {
        let tasks = terminalQueues[paneId] ?? []
        terminalQueues[paneId] = nil
        return tasks
    }

    func clearAllQueues() {
        terminalQueues.removeAll()
    }

    // Helper for tests
    func reset() {
        terminalQueues.removeAll()
        enqueueCallCount = 0
        dequeueCallCount = 0
        lastEnqueuedTaskId = nil
        lastEnqueuedPaneId = nil
        lastDequeuedPaneId = nil
    }
}

// MARK: - Mock Session Manager

@MainActor
final class MockSessionManager: TerminalSessionManaging {
    var sessions: [TerminalSession] = []

    // Track method calls
    var startSessionCallCount = 0
    var stopSessionCallCount = 0

    func startSession(
        for task: WorkTask?,
        paneId: String?,
        command: String?,
        workingDirectory: String?,
        workspaceId: UUID,
        worktreeBranch: String?,
        provider: AIProvider = .claude
    ) -> TerminalSession {
        startSessionCallCount += 1

        // Check for existing session
        if let task = task,
           let existing = sessions.first(where: { $0.taskId == task.persistentModelID }) {
            return existing
        }
        if let paneId = paneId,
           let existing = sessions.first(where: { $0.paneId == paneId }) {
            return existing
        }

        let session = TerminalSession(
            task: task,
            paneId: paneId,
            command: command,
            workingDirectory: workingDirectory,
            workspaceId: workspaceId,
            worktreeBranch: worktreeBranch,
            provider: provider
        )
        sessions.append(session)
        return session
    }

    func session(forPaneId paneId: String, workingDirectory: String?, workspaceId: UUID) -> TerminalSession {
        if let existing = sessions.first(where: { $0.paneId == paneId }) {
            return existing
        }
        let session = TerminalSession(
            task: nil,
            paneId: paneId,
            command: nil,
            workingDirectory: workingDirectory,
            workspaceId: workspaceId
        )
        sessions.append(session)
        return session
    }

    func sessions(for workspaceId: UUID) -> [TerminalSession] {
        sessions.filter { $0.workspaceId == workspaceId }
    }

    func session(for task: WorkTask) -> TerminalSession? {
        let taskModelId = task.persistentModelID
        return sessions.first { $0.taskId == taskModelId }
    }

    func stopSession(for task: WorkTask) {
        stopSessionCallCount += 1
        let taskModelId = task.persistentModelID
        sessions.removeAll { $0.taskId == taskModelId }
    }

    func stopSession(_ session: TerminalSession) {
        stopSessionCallCount += 1
        sessions.removeAll { $0.id == session.id }
    }

    func stopSession(forPaneId paneId: String) {
        stopSessionCallCount += 1
        sessions.removeAll { $0.paneId == paneId }
    }

    func runningCount(for workspaceId: UUID) -> Int {
        sessions(for: workspaceId).count
    }

    var hasRunningSessions: Bool {
        !sessions.isEmpty
    }

    // Helper for tests
    func reset() {
        sessions.removeAll()
        startSessionCallCount = 0
        stopSessionCallCount = 0
    }

    /// Create a mock session with a task
    func createSessionWithTask(
        paneId: String,
        workspaceId: UUID,
        hasTask: Bool = true
    ) -> TerminalSession {
        let session = TerminalSession(
            task: nil,
            paneId: paneId,
            command: nil,
            workingDirectory: nil,
            workspaceId: workspaceId
        )
        if hasTask {
            // Simulate having a task by setting taskId to a dummy value
            // In real usage, this would be a PersistentIdentifier
        }
        sessions.append(session)
        return session
    }
}

// MARK: - Mock Task Fetcher

@MainActor
final class MockTaskFetcher: TaskFetching {
    var tasks: [UUID: WorkTask] = [:]
    var tasksByPersistentId: [String: WorkTask] = [:]

    // Track calls
    var fetchByIdCallCount = 0
    var fetchByPersistentIdCallCount = 0

    func fetchTask(byId id: UUID) -> WorkTask? {
        fetchByIdCallCount += 1
        return tasks[id]
    }

    func fetchTask(byPersistentId id: PersistentIdentifier) -> WorkTask? {
        fetchByPersistentIdCallCount += 1
        // For testing, we use the description as a key
        return tasksByPersistentId[String(describing: id)]
    }

    func addTask(_ task: WorkTask) {
        tasks[task.id] = task
    }

    func reset() {
        tasks.removeAll()
        tasksByPersistentId.removeAll()
        fetchByIdCallCount = 0
        fetchByPersistentIdCallCount = 0
    }
}

// MARK: - Test Helpers

/// Create a test model container for SwiftData
@MainActor
func createTestModelContainer() throws -> ModelContainer {
    let schema = Schema([
        Workspace.self,
        WorkTask.self,
        Terminal.self,
        Profile.self,
        TaskAssignee.self,
        TaskComment.self,
        TaskAttachment.self,
        TaskDispatch.self,
        Hint.self,
        TaskSkill.self,
        Skill.self,
        Context.self,
        Organization.self,
        OrganizationMember.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

// MARK: - Task Queue Service Tests

@MainActor
final class TaskQueueServiceTests: XCTestCase {

    var taskQueue: MockTaskQueue!

    override func setUp() {
        super.setUp()
        taskQueue = MockTaskQueue()
    }

    override func tearDown() {
        taskQueue = nil
        super.tearDown()
    }

    // MARK: - Enqueue Tests

    func testEnqueue_addsTaskToQueue() {
        let taskId = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)

        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 1)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.first, taskId)
        XCTAssertEqual(taskQueue.enqueueCallCount, 1)
    }

    func testEnqueue_preventsDuplicates() {
        let taskId = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)

        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 1)
        XCTAssertEqual(taskQueue.enqueueCallCount, 2)
    }

    func testEnqueue_maintainsFIFOOrder() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let taskId3 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId3, onTerminal: paneId)

        let queue = taskQueue.terminalQueues[paneId]!
        XCTAssertEqual(queue[0], taskId1)
        XCTAssertEqual(queue[1], taskId2)
        XCTAssertEqual(queue[2], taskId3)
    }

    func testEnqueue_createsNewQueueIfNeeded() {
        let taskId = UUID()
        let paneId = "new-pane"

        XCTAssertNil(taskQueue.terminalQueues[paneId])

        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)

        XCTAssertNotNil(taskQueue.terminalQueues[paneId])
    }

    // MARK: - Dequeue Tests

    func testDequeue_returnsFirstTask() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)

        let dequeued = taskQueue.dequeue(fromTerminal: paneId)

        XCTAssertEqual(dequeued, taskId1)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 1)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.first, taskId2)
    }

    func testDequeue_returnsNilForEmptyQueue() {
        let paneId = "empty-pane"

        let dequeued = taskQueue.dequeue(fromTerminal: paneId)

        XCTAssertNil(dequeued)
    }

    func testDequeue_returnsNilForNonexistentPane() {
        let dequeued = taskQueue.dequeue(fromTerminal: "nonexistent")

        XCTAssertNil(dequeued)
    }

    // MARK: - Peek Tests

    func testPeek_returnsFirstTaskWithoutRemoving() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)

        let peeked = taskQueue.peek(terminal: paneId)

        XCTAssertEqual(peeked, taskId1)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 2)
    }

    // MARK: - Terminal For Task Tests

    func testTerminalForTask_findsCorrectTerminal() {
        let taskId = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)

        let found = taskQueue.terminalForTask(taskId: taskId)

        XCTAssertEqual(found, paneId)
    }

    func testTerminalForTask_returnsNilForUnqueuedTask() {
        let taskId = UUID()

        let found = taskQueue.terminalForTask(taskId: taskId)

        XCTAssertNil(found)
    }

    // MARK: - Remove Tests

    func testRemove_removesSpecificTask() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)

        taskQueue.remove(taskId: taskId1, fromTerminal: paneId)

        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 1)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.first, taskId2)
    }

    func testRemoveFromAnyTerminal_findsAndRemovesTask() {
        let taskId = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId, onTerminal: paneId)

        let removedFrom = taskQueue.removeFromAnyTerminal(taskId: taskId)

        XCTAssertEqual(removedFrom, paneId)
        XCTAssertEqual(taskQueue.terminalQueues[paneId]?.count, 0)
    }

    // MARK: - Reorder Tests

    func testReorder_movesTaskToNewPosition() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let taskId3 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId3, onTerminal: paneId)

        // Move task3 to front
        taskQueue.reorder(taskId: taskId3, toIndex: 0, inTerminal: paneId)

        let queue = taskQueue.terminalQueues[paneId]!
        XCTAssertEqual(queue[0], taskId3)
        XCTAssertEqual(queue[1], taskId1)
        XCTAssertEqual(queue[2], taskId2)
    }

    // MARK: - Clear Tests

    func testClearQueue_removesAllTasksFromTerminal() {
        let taskId1 = UUID()
        let taskId2 = UUID()
        let paneId = "pane-1"

        taskQueue.enqueue(taskId: taskId1, onTerminal: paneId)
        taskQueue.enqueue(taskId: taskId2, onTerminal: paneId)

        taskQueue.clearQueue(forTerminal: paneId)

        XCTAssertNil(taskQueue.terminalQueues[paneId])
    }

    func testClearAllQueues_removesAllQueues() {
        taskQueue.enqueue(taskId: UUID(), onTerminal: "pane-1")
        taskQueue.enqueue(taskId: UUID(), onTerminal: "pane-2")

        taskQueue.clearAllQueues()

        XCTAssertTrue(taskQueue.terminalQueues.isEmpty)
    }
}

// MARK: - Task Assignment Coordinator Tests

@MainActor
final class TaskAssignmentCoordinatorTests: XCTestCase {

    var coordinator: TaskAssignmentCoordinator!
    var mockTaskQueue: MockTaskQueue!
    var mockSessionManager: MockSessionManager!
    var mockTaskFetcher: MockTaskFetcher!
    var modelContainer: ModelContainer!
    var modelContext: ModelContext!

    override func setUp() async throws {
        try await super.setUp()

        mockTaskQueue = MockTaskQueue()
        mockSessionManager = MockSessionManager()
        mockTaskFetcher = MockTaskFetcher()

        coordinator = TaskAssignmentCoordinator(
            taskQueue: mockTaskQueue,
            sessionManager: mockSessionManager,
            taskFetcher: mockTaskFetcher
        )

        // Set up SwiftData for creating test tasks
        modelContainer = try createTestModelContainer()
        modelContext = ModelContext(modelContainer)
    }

    override func tearDown() {
        coordinator = nil
        mockTaskQueue = nil
        mockSessionManager = nil
        mockTaskFetcher = nil
        modelContainer = nil
        modelContext = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    func createTestTask(title: String = "Test Task") -> WorkTask {
        let task = WorkTask(title: title)
        modelContext.insert(task)
        try? modelContext.save()
        mockTaskFetcher.addTask(task)
        return task
    }

    func createTestSession(
        paneId: String = "pane-1",
        workspaceId: UUID = UUID(),
        hasTask: Bool = false
    ) -> TerminalSession {
        let session = TerminalSession(
            task: nil,
            paneId: paneId,
            command: nil,
            workingDirectory: nil,
            workspaceId: workspaceId
        )
        if hasTask {
            let task = createTestTask()
            session.assignTask(task)
        }
        mockSessionManager.sessions.append(session)
        return session
    }

    // MARK: - Assign Task Tests

    func testAssignTask_toIdleWorker_runsImmediately() {
        let task = createTestTask(title: "Run Task")
        let session = createTestSession(hasTask: false)

        var promptSent = false
        coordinator.onSendTaskPrompt = { sentTask, sentSession in
            promptSent = true
            XCTAssertEqual(sentTask.id, task.id)
            XCTAssertEqual(sentSession.paneId, session.paneId)
        }

        let result = coordinator.assignTask(task, to: session)

        XCTAssertEqual(result, .running(paneId: session.paneId!))
        XCTAssertEqual(task.taskStatus, .running)
        XCTAssertTrue(promptSent)
        XCTAssertEqual(mockTaskQueue.enqueueCallCount, 0)
    }

    func testAssignTask_toBusyWorker_queuesTask() {
        let task = createTestTask(title: "Queue Task")
        let session = createTestSession(hasTask: true)

        let result = coordinator.assignTask(task, to: session)

        XCTAssertEqual(result, .queued(paneId: session.paneId!))
        XCTAssertEqual(task.taskStatus, .queued)
        XCTAssertEqual(mockTaskQueue.enqueueCallCount, 1)
        XCTAssertEqual(mockTaskQueue.lastEnqueuedTaskId, task.id)
        XCTAssertEqual(mockTaskQueue.lastEnqueuedPaneId, session.paneId)
    }

    func testAssignTask_toSessionWithoutPaneId_returnsNoSessionFound() {
        let task = createTestTask()
        let session = TerminalSession(
            task: nil,
            paneId: nil,
            command: nil,
            workingDirectory: nil,
            workspaceId: UUID()
        )
        mockSessionManager.sessions.append(session)

        let result = coordinator.assignTask(task, to: session)

        XCTAssertEqual(result, .noSessionFound)
    }

    // MARK: - Queue Task Tests

    func testQueueTask_updatesStatusAndEnqueues() {
        let task = createTestTask()
        let session = createTestSession()

        let result = coordinator.queueTask(task, on: session)

        XCTAssertEqual(result, .queued(paneId: session.paneId!))
        XCTAssertEqual(task.taskStatus, .queued)
        XCTAssertEqual(mockTaskQueue.enqueueCallCount, 1)
    }

    // MARK: - Run Task Tests

    func testRunTask_updatesStatusAndSendsPrompt() {
        let task = createTestTask(title: "My Task")
        let session = createTestSession()

        var terminalTaskUpdated = false
        coordinator.onUpdateTerminalTask = { paneId, updatedTask in
            terminalTaskUpdated = true
            XCTAssertEqual(paneId, session.paneId)
            XCTAssertEqual(updatedTask?.id, task.id)
        }

        var promptSent = false
        coordinator.onSendTaskPrompt = { _, _ in
            promptSent = true
        }

        let result = coordinator.runTask(task, on: session)

        XCTAssertEqual(result, .running(paneId: session.paneId!))
        XCTAssertEqual(task.taskStatus, .running)
        XCTAssertTrue(terminalTaskUpdated)
        XCTAssertTrue(promptSent)
    }

    // MARK: - Consume Next Queued Task Tests

    func testConsumeNextQueuedTask_withQueuedTask_runsNextTask() {
        let workspaceId = UUID()
        let paneId = "pane-1"

        // Create session
        let session = createTestSession(paneId: paneId, workspaceId: workspaceId, hasTask: false)

        // Create and queue a task
        let queuedTask = createTestTask(title: "Queued Task")
        mockTaskQueue.enqueue(taskId: queuedTask.id, onTerminal: paneId)

        var promptSent = false
        coordinator.onSendTaskPrompt = { task, _ in
            promptSent = true
            XCTAssertEqual(task.id, queuedTask.id)
        }

        let result = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)

        XCTAssertEqual(result, .consumed(taskId: queuedTask.id))
        XCTAssertEqual(mockTaskQueue.dequeueCallCount, 1)
        XCTAssertTrue(promptSent)
    }

    func testConsumeNextQueuedTask_withEmptyQueue_clearsSession() {
        let workspaceId = UUID()
        let paneId = "pane-1"

        let session = createTestSession(paneId: paneId, workspaceId: workspaceId, hasTask: true)

        var terminalCleared = false
        coordinator.onUpdateTerminalTask = { updatedPaneId, task in
            if task == nil {
                terminalCleared = true
                XCTAssertEqual(updatedPaneId, paneId)
            }
        }

        let result = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)

        XCTAssertEqual(result, .queueEmpty)
        XCTAssertNil(session.taskId)
        XCTAssertEqual(session.taskTitle, "Terminal")
        XCTAssertTrue(terminalCleared)
    }

    func testConsumeNextQueuedTask_withNoSession_returnsSessionNotFound() {
        let result = coordinator.consumeNextQueuedTask(forPaneId: "nonexistent", workspaceId: UUID())

        XCTAssertEqual(result, .sessionNotFound)
    }

    func testConsumeNextQueuedTask_withDeletedTask_skipsAndTriesNext() {
        let workspaceId = UUID()
        let paneId = "pane-1"

        let session = createTestSession(paneId: paneId, workspaceId: workspaceId, hasTask: false)

        // Queue two tasks, but don't add the first one to the fetcher (simulating deletion)
        let deletedTaskId = UUID()
        let validTask = createTestTask(title: "Valid Task")

        mockTaskQueue.enqueue(taskId: deletedTaskId, onTerminal: paneId)
        mockTaskQueue.enqueue(taskId: validTask.id, onTerminal: paneId)

        // Note: deletedTaskId is not in mockTaskFetcher, so it will return nil

        let result = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)

        XCTAssertEqual(result, .consumed(taskId: validTask.id))
        // Should have dequeued twice (once for deleted, once for valid)
        XCTAssertEqual(mockTaskQueue.dequeueCallCount, 2)
    }

    // MARK: - Handle Task No Longer Running Tests

    func testHandleTaskNoLongerRunning_findsTerminalAndConsumesQueue() {
        let workspaceId = UUID()
        let paneId = "pane-1"

        // Create session
        _ = createTestSession(paneId: paneId, workspaceId: workspaceId, hasTask: false)

        // Create a task that was running
        let completedTask = createTestTask(title: "Completed Task")

        // Queue another task
        let nextTask = createTestTask(title: "Next Task")
        mockTaskQueue.enqueue(taskId: nextTask.id, onTerminal: paneId)

        // Create a real Terminal with the task using SwiftData
        let terminal = createTestTerminal(paneId: paneId, task: completedTask)

        let result = coordinator.handleTaskNoLongerRunning(
            taskId: completedTask.id,
            workspaceId: workspaceId,
            terminals: [terminal]
        )

        XCTAssertEqual(result, paneId)
        XCTAssertEqual(mockTaskQueue.dequeueCallCount, 1)
    }

    func testHandleTaskNoLongerRunning_withNoMatchingTerminal_returnsNil() {
        let workspaceId = UUID()
        let taskId = UUID()

        let result = coordinator.handleTaskNoLongerRunning(
            taskId: taskId,
            workspaceId: workspaceId,
            terminals: []
        )

        XCTAssertNil(result)
    }

    // MARK: - Integration-style Tests

    func testFullWorkflow_assignQueueAndConsume() {
        let workspaceId = UUID()
        let paneId = "pane-1"

        // Create a session with a running task
        let session = createTestSession(paneId: paneId, workspaceId: workspaceId, hasTask: true)

        // Assign a second task (should be queued)
        let task2 = createTestTask(title: "Task 2")
        let assignResult = coordinator.assignTask(task2, to: session)
        XCTAssertEqual(assignResult, .queued(paneId: paneId))

        // Assign a third task (should also be queued)
        let task3 = createTestTask(title: "Task 3")
        let assignResult2 = coordinator.assignTask(task3, to: session)
        XCTAssertEqual(assignResult2, .queued(paneId: paneId))

        // Queue should have 2 tasks
        XCTAssertEqual(mockTaskQueue.queueCount(forTerminal: paneId), 2)

        // Simulate first task completing - clear the session's task
        session.taskId = nil

        // Consume next task
        let consumeResult = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
        XCTAssertEqual(consumeResult, .consumed(taskId: task2.id))

        // Queue should now have 1 task
        XCTAssertEqual(mockTaskQueue.queueCount(forTerminal: paneId), 1)

        // Consume again
        session.taskId = nil
        let consumeResult2 = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
        XCTAssertEqual(consumeResult2, .consumed(taskId: task3.id))

        // Queue should be empty
        XCTAssertEqual(mockTaskQueue.queueCount(forTerminal: paneId), 0)

        // Consume again should return empty
        session.taskId = nil
        let consumeResult3 = coordinator.consumeNextQueuedTask(forPaneId: paneId, workspaceId: workspaceId)
        XCTAssertEqual(consumeResult3, .queueEmpty)
    }
}

// MARK: - Test Helper for Terminal

extension TaskAssignmentCoordinatorTests {
    /// Create a real Terminal with SwiftData for testing
    func createTestTerminal(paneId: String, task: WorkTask? = nil) -> Terminal {
        let terminal = Terminal()
        terminal.paneId = paneId
        terminal.task = task
        modelContext.insert(terminal)
        try? modelContext.save()
        return terminal
    }
}
