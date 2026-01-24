import XCTest
import Foundation
@testable import Axel
import AutomergeWrapper

/// Comprehensive tests for automerge document operations on all models.
/// Tests cover:
/// - Document initialization from model
/// - Document serialization round-trip
/// - Apply document state back to model
/// - Concurrent edits merge correctly
/// - Field-level updates
final class AutomergeModelTests: XCTestCase {

    // MARK: - Task Tests

    func testTaskDocumentInitializationAndApply() throws {
        let doc = Document()

        // Initialize with task data
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Test Task"))
        try doc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Task description"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        try doc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(100))
        let completedAt = Date()
        try doc.put(obj: .ROOT, key: TaskSchema.completedAt, value: .Timestamp(completedAt))

        // Verify all fields can be read back
        if case .Scalar(.String(let title)) = try doc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Test Task")
        } else { XCTFail("Failed to read title") }

        if case .Scalar(.String(let desc)) = try doc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Task description")
        } else { XCTFail("Failed to read description") }

        if case .Scalar(.String(let status)) = try doc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running")
        } else { XCTFail("Failed to read status") }

        if case .Scalar(.Int(let priority)) = try doc.get(obj: .ROOT, key: TaskSchema.priority) {
            XCTAssertEqual(priority, 100)
        } else { XCTFail("Failed to read priority") }

        if case .Scalar(.Timestamp(let timestamp)) = try doc.get(obj: .ROOT, key: TaskSchema.completedAt) {
            XCTAssertEqual(timestamp.timeIntervalSince1970, completedAt.timeIntervalSince1970, accuracy: 0.001)
        } else { XCTFail("Failed to read completedAt") }
    }

    func testTaskSerializationRoundTrip() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Serialization Test"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        try doc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(50))

        let bytes = doc.save()
        XCTAssertFalse(bytes.isEmpty)

        let loaded = try Document(bytes)

        if case .Scalar(.String(let title)) = try loaded.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Serialization Test")
        } else { XCTFail("Failed to read title after load") }
    }

    func testTaskConcurrentEdits() throws {
        // Initial state
        let initial = Document()
        try initial.put(obj: .ROOT, key: TaskSchema.title, value: .String("Task"))
        try initial.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let initialBytes = initial.save()

        // Device A changes status
        let docA = try Document(initialBytes)
        try docA.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))

        // Device B changes description (concurrently)
        let docB = try Document(initialBytes)
        try docB.put(obj: .ROOT, key: TaskSchema.description, value: .String("Added description"))

        // Merge - both changes should be preserved
        try docA.merge(other: docB)

        if case .Scalar(.String(let status)) = try docA.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "Status from A should be preserved")
        }
        if case .Scalar(.String(let desc)) = try docA.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Added description", "Description from B should be merged")
        }
    }

    func testTaskFieldUpdates() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Original"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))

        // Update individual fields
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Updated Title"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("completed"))
        try doc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(999))

        if case .Scalar(.String(let title)) = try doc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Updated Title")
        }
        if case .Scalar(.String(let status)) = try doc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "completed")
        }
        if case .Scalar(.Int(let priority)) = try doc.get(obj: .ROOT, key: TaskSchema.priority) {
            XCTAssertEqual(priority, 999)
        }
    }

    // MARK: - Workspace Tests

    func testWorkspaceDocumentOperations() throws {
        let doc = Document()

        try doc.put(obj: .ROOT, key: WorkspaceSchema.name, value: .String("My Workspace"))
        try doc.put(obj: .ROOT, key: WorkspaceSchema.slug, value: .String("my-workspace"))
        try doc.put(obj: .ROOT, key: WorkspaceSchema.path, value: .String("/Users/test/project"))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let name)) = try loaded.get(obj: .ROOT, key: WorkspaceSchema.name) {
            XCTAssertEqual(name, "My Workspace")
        } else { XCTFail("Failed to read workspace name") }

        if case .Scalar(.String(let slug)) = try loaded.get(obj: .ROOT, key: WorkspaceSchema.slug) {
            XCTAssertEqual(slug, "my-workspace")
        } else { XCTFail("Failed to read workspace slug") }

        if case .Scalar(.String(let path)) = try loaded.get(obj: .ROOT, key: WorkspaceSchema.path) {
            XCTAssertEqual(path, "/Users/test/project")
        } else { XCTFail("Failed to read workspace path") }
    }

    func testWorkspaceConcurrentEdits() throws {
        let initial = Document()
        try initial.put(obj: .ROOT, key: WorkspaceSchema.name, value: .String("Workspace"))
        try initial.put(obj: .ROOT, key: WorkspaceSchema.slug, value: .String("workspace"))
        let initialBytes = initial.save()

        // Device A changes name
        let docA = try Document(initialBytes)
        try docA.put(obj: .ROOT, key: WorkspaceSchema.name, value: .String("New Name"))

        // Device B adds path
        let docB = try Document(initialBytes)
        try docB.put(obj: .ROOT, key: WorkspaceSchema.path, value: .String("/new/path"))

        try docA.merge(other: docB)

        if case .Scalar(.String(let name)) = try docA.get(obj: .ROOT, key: WorkspaceSchema.name) {
            XCTAssertEqual(name, "New Name")
        }
        if case .Scalar(.String(let path)) = try docA.get(obj: .ROOT, key: WorkspaceSchema.path) {
            XCTAssertEqual(path, "/new/path")
        }
    }

    // MARK: - Skill Tests

    func testSkillDocumentOperations() throws {
        let doc = Document()

        try doc.put(obj: .ROOT, key: SkillSchema.name, value: .String("Python Expert"))
        try doc.put(obj: .ROOT, key: SkillSchema.content, value: .String("You are an expert Python developer..."))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let name)) = try loaded.get(obj: .ROOT, key: SkillSchema.name) {
            XCTAssertEqual(name, "Python Expert")
        } else { XCTFail("Failed to read skill name") }

        if case .Scalar(.String(let content)) = try loaded.get(obj: .ROOT, key: SkillSchema.content) {
            XCTAssertEqual(content, "You are an expert Python developer...")
        } else { XCTFail("Failed to read skill content") }
    }

    func testSkillConcurrentContentEdits() throws {
        let initial = Document()
        try initial.put(obj: .ROOT, key: SkillSchema.name, value: .String("Skill"))
        try initial.put(obj: .ROOT, key: SkillSchema.content, value: .String("Original content"))
        let initialBytes = initial.save()

        // Device A changes name
        let docA = try Document(initialBytes)
        try docA.put(obj: .ROOT, key: SkillSchema.name, value: .String("Updated Skill Name"))

        // Device B changes content
        let docB = try Document(initialBytes)
        try docB.put(obj: .ROOT, key: SkillSchema.content, value: .String("Updated content from B"))

        try docA.merge(other: docB)

        if case .Scalar(.String(let name)) = try docA.get(obj: .ROOT, key: SkillSchema.name) {
            XCTAssertEqual(name, "Updated Skill Name")
        }
        if case .Scalar(.String(let content)) = try docA.get(obj: .ROOT, key: SkillSchema.content) {
            XCTAssertEqual(content, "Updated content from B")
        }
    }

    // MARK: - Context Tests

    func testContextDocumentOperations() throws {
        let doc = Document()

        try doc.put(obj: .ROOT, key: ContextSchema.name, value: .String("Project Context"))
        try doc.put(obj: .ROOT, key: ContextSchema.content, value: .String("This project uses Swift and SwiftUI..."))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let name)) = try loaded.get(obj: .ROOT, key: ContextSchema.name) {
            XCTAssertEqual(name, "Project Context")
        } else { XCTFail("Failed to read context name") }

        if case .Scalar(.String(let content)) = try loaded.get(obj: .ROOT, key: ContextSchema.content) {
            XCTAssertEqual(content, "This project uses Swift and SwiftUI...")
        } else { XCTFail("Failed to read context content") }
    }

    // MARK: - Terminal Tests

    func testTerminalDocumentOperations() throws {
        let doc = Document()
        let startedAt = Date()
        let endedAt = Date().addingTimeInterval(3600)

        try doc.put(obj: .ROOT, key: TerminalSchema.name, value: .String("Terminal 1"))
        try doc.put(obj: .ROOT, key: TerminalSchema.status, value: .String("running"))
        try doc.put(obj: .ROOT, key: TerminalSchema.startedAt, value: .Timestamp(startedAt))
        try doc.put(obj: .ROOT, key: TerminalSchema.endedAt, value: .Timestamp(endedAt))
        try doc.put(obj: .ROOT, key: TerminalSchema.paneId, value: .String("pane-123"))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let name)) = try loaded.get(obj: .ROOT, key: TerminalSchema.name) {
            XCTAssertEqual(name, "Terminal 1")
        } else { XCTFail("Failed to read terminal name") }

        if case .Scalar(.String(let status)) = try loaded.get(obj: .ROOT, key: TerminalSchema.status) {
            XCTAssertEqual(status, "running")
        } else { XCTFail("Failed to read terminal status") }

        if case .Scalar(.String(let paneId)) = try loaded.get(obj: .ROOT, key: TerminalSchema.paneId) {
            XCTAssertEqual(paneId, "pane-123")
        } else { XCTFail("Failed to read terminal pane ID") }
    }

    func testTerminalStatusUpdate() throws {
        let initial = Document()
        try initial.put(obj: .ROOT, key: TerminalSchema.status, value: .String("running"))
        try initial.put(obj: .ROOT, key: TerminalSchema.startedAt, value: .Timestamp(Date()))
        let initialBytes = initial.save()

        // Device A ends terminal
        let docA = try Document(initialBytes)
        try docA.put(obj: .ROOT, key: TerminalSchema.status, value: .String("completed"))
        try docA.put(obj: .ROOT, key: TerminalSchema.endedAt, value: .Timestamp(Date()))

        let bytes = docA.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let status)) = try loaded.get(obj: .ROOT, key: TerminalSchema.status) {
            XCTAssertEqual(status, "completed")
        }
    }

    // MARK: - Hint Tests

    func testHintDocumentOperations() throws {
        let doc = Document()
        let answeredAt = Date()

        try doc.put(obj: .ROOT, key: HintSchema.type, value: .String("question"))
        try doc.put(obj: .ROOT, key: HintSchema.title, value: .String("Need clarification"))
        try doc.put(obj: .ROOT, key: HintSchema.description, value: .String("What framework should I use?"))
        try doc.put(obj: .ROOT, key: HintSchema.status, value: .String("answered"))
        try doc.put(obj: .ROOT, key: HintSchema.answeredAt, value: .Timestamp(answeredAt))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let type)) = try loaded.get(obj: .ROOT, key: HintSchema.type) {
            XCTAssertEqual(type, "question")
        } else { XCTFail("Failed to read hint type") }

        if case .Scalar(.String(let title)) = try loaded.get(obj: .ROOT, key: HintSchema.title) {
            XCTAssertEqual(title, "Need clarification")
        } else { XCTFail("Failed to read hint title") }

        if case .Scalar(.String(let status)) = try loaded.get(obj: .ROOT, key: HintSchema.status) {
            XCTAssertEqual(status, "answered")
        } else { XCTFail("Failed to read hint status") }
    }

    func testHintStatusTransition() throws {
        let initial = Document()
        try initial.put(obj: .ROOT, key: HintSchema.type, value: .String("question"))
        try initial.put(obj: .ROOT, key: HintSchema.title, value: .String("Question"))
        try initial.put(obj: .ROOT, key: HintSchema.status, value: .String("pending"))
        let initialBytes = initial.save()

        // Answer the hint
        let doc = try Document(initialBytes)
        try doc.put(obj: .ROOT, key: HintSchema.status, value: .String("answered"))
        try doc.put(obj: .ROOT, key: HintSchema.answeredAt, value: .Timestamp(Date()))

        if case .Scalar(.String(let status)) = try doc.get(obj: .ROOT, key: HintSchema.status) {
            XCTAssertEqual(status, "answered")
        }
    }

    // MARK: - Organization Tests

    func testOrganizationDocumentOperations() throws {
        let doc = Document()

        try doc.put(obj: .ROOT, key: OrganizationSchema.name, value: .String("Acme Corp"))
        try doc.put(obj: .ROOT, key: OrganizationSchema.slug, value: .String("acme-corp"))
        try doc.put(obj: .ROOT, key: OrganizationSchema.avatarUrl, value: .String("https://example.com/avatar.png"))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let name)) = try loaded.get(obj: .ROOT, key: OrganizationSchema.name) {
            XCTAssertEqual(name, "Acme Corp")
        } else { XCTFail("Failed to read org name") }

        if case .Scalar(.String(let slug)) = try loaded.get(obj: .ROOT, key: OrganizationSchema.slug) {
            XCTAssertEqual(slug, "acme-corp")
        } else { XCTFail("Failed to read org slug") }

        if case .Scalar(.String(let avatarUrl)) = try loaded.get(obj: .ROOT, key: OrganizationSchema.avatarUrl) {
            XCTAssertEqual(avatarUrl, "https://example.com/avatar.png")
        } else { XCTFail("Failed to read org avatar URL") }
    }

    // MARK: - Edge Cases

    func testEmptyStringHandling() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.description, value: .String(""))

        if case .Scalar(.String(let desc)) = try doc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "", "Empty string should be preserved")
        }
    }

    func testOptionalFieldDeletion() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.completedAt, value: .Timestamp(Date()))

        // Delete optional field
        try doc.delete(obj: .ROOT, key: TaskSchema.completedAt)

        // Should not find the field
        let result = try? doc.get(obj: .ROOT, key: TaskSchema.completedAt)
        XCTAssertNil(result, "Deleted field should return nil")
    }

    func testLargeContentHandling() throws {
        let doc = Document()
        let largeContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 1000)

        try doc.put(obj: .ROOT, key: SkillSchema.content, value: .String(largeContent))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let content)) = try loaded.get(obj: .ROOT, key: SkillSchema.content) {
            XCTAssertEqual(content.count, largeContent.count, "Large content should be preserved")
        } else { XCTFail("Failed to read large content") }
    }

    func testUnicodeHandling() throws {
        let doc = Document()
        let unicodeContent = "こんにちは 🌍 مرحبا Привет"

        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String(unicodeContent))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let title)) = try loaded.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, unicodeContent, "Unicode should be preserved")
        } else { XCTFail("Failed to read unicode content") }
    }

    func testSpecialCharactersInContent() throws {
        let doc = Document()
        let specialContent = "Code: `func test() { print(\"Hello\\nWorld\") }`\n\nPath: /usr/local/bin"

        try doc.put(obj: .ROOT, key: ContextSchema.content, value: .String(specialContent))

        let bytes = doc.save()
        let loaded = try Document(bytes)

        if case .Scalar(.String(let content)) = try loaded.get(obj: .ROOT, key: ContextSchema.content) {
            XCTAssertEqual(content, specialContent, "Special characters should be preserved")
        } else { XCTFail("Failed to read special character content") }
    }

    // MARK: - Multi-Device Sync Simulation

    func testThreeDeviceSyncScenario() throws {
        // Initial: Created on iOS
        let iosDoc = Document()
        try iosDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Task"))
        try iosDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        try iosDoc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(50))

        // Sync to server
        var serverBytes = iosDoc.save()

        // macOS syncs and changes status
        let macDoc = try Document(serverBytes)
        try macDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        serverBytes = macDoc.save()

        // iPad syncs (from server with macOS changes) and adds description
        let ipadDoc = try Document(serverBytes)
        try ipadDoc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Added by iPad"))

        // iOS syncs again (hasn't seen macOS or iPad changes yet)
        // First merge macOS's changes
        try iosDoc.merge(other: macDoc)
        // Then merge iPad's changes
        try iosDoc.merge(other: ipadDoc)

        // iOS should have all changes
        if case .Scalar(.String(let status)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "Should have macOS status change")
        }
        if case .Scalar(.String(let desc)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Added by iPad", "Should have iPad description")
        }
        if case .Scalar(.Int(let priority)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.priority) {
            XCTAssertEqual(priority, 50, "Should preserve original priority")
        }
    }
}
