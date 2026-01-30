import XCTest
import Foundation
@testable import Axel
import AutomergeWrapper

/// Tests for the sync engine focusing on:
/// - Automerge document merge behavior
/// - Field-level merge fallback
/// - Local changes preserved during sync
/// - Remote changes applied correctly
final class SyncEngineTests: XCTestCase {

    // MARK: - Automerge Document Tests

    func testAutomergeDocumentCreation() throws {
        let doc = Document()

        // Set task fields
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Test Task"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        try doc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Test description"))
        try doc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(100))

        // Verify fields
        if case .Scalar(.String(let title)) = try doc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Test Task")
        } else {
            XCTFail("Failed to read title")
        }

        if case .Scalar(.String(let status)) = try doc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "queued")
        } else {
            XCTFail("Failed to read status")
        }
    }

    func testAutomergeDocumentSerialization() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Test Task"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))

        // Serialize
        let bytes = doc.save()
        XCTAssertFalse(bytes.isEmpty, "Serialized document should not be empty")

        // Deserialize
        let loadedDoc = try Document(bytes)
        if case .Scalar(.String(let title)) = try loadedDoc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Test Task")
        } else {
            XCTFail("Failed to read title from loaded document")
        }
    }

    func testAutomergeMergeRemoteChanges() throws {
        // Simulate local device with initial state
        let localDoc = Document()
        try localDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Task"))
        try localDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))

        // Simulate remote device that changed status
        let remoteDoc = Document()
        try remoteDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Task"))
        try remoteDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))

        // Merge remote into local
        try localDoc.merge(other: remoteDoc)

        // After merge, one of the statuses should be present (LWW based on actor ID)
        if case .Scalar(.String(let status)) = try localDoc.get(obj: .ROOT, key: TaskSchema.status) {
            // The status should be either "queued" or "running" - both are valid merge results
            XCTAssertTrue(["queued", "running"].contains(status), "Status should be either queued or running after merge")
        } else {
            XCTFail("Failed to read status after merge")
        }
    }

    func testAutomergeMergeWithHistory() throws {
        // Create a document with history
        let doc1 = Document()
        try doc1.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let doc1Bytes = doc1.save()

        // Fork: doc2 starts from doc1's state and changes status
        let doc2 = try Document(doc1Bytes)
        try doc2.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))

        // Fork: doc3 starts from doc1's state and changes description
        let doc3 = try Document(doc1Bytes)
        try doc3.put(obj: .ROOT, key: TaskSchema.description, value: .String("Added description"))

        // Merge doc2 and doc3 - both changes should be preserved
        try doc2.merge(other: doc3)

        // Should have both status from doc2 and description from doc3
        if case .Scalar(.String(let status)) = try doc2.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "Status should be 'running' from doc2")
        }
        if case .Scalar(.String(let desc)) = try doc2.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Added description", "Description should be from doc3")
        }
    }

    // MARK: - PostgresBytea Encoding Tests

    func testPostgresByteaHexEncoding() throws {
        let originalData = Data([0x85, 0x6f, 0x4a, 0x83, 0xfe, 0xdc, 0xba])

        let bytea = PostgresBytea(originalData)

        // Encode to JSON
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(bytea)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Should be hex format with \x prefix
        XCTAssertTrue(jsonString.contains("\\\\x"), "Should encode as hex with \\x prefix")
    }

    func testPostgresByteaHexDecoding() throws {
        // Simulate what Supabase returns: hex-encoded data
        let hexString = "\"\\\\x856f4a83fedcba\""
        let jsonData = hexString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let bytea = try decoder.decode(PostgresBytea.self, from: jsonData)

        XCTAssertEqual(bytea.data, Data([0x85, 0x6f, 0x4a, 0x83, 0xfe, 0xdc, 0xba]))
    }

    func testPostgresByteaDoubleEncodedBase64Decoding() throws {
        // Simulate the bug: hex-encoded base64
        // Original bytes -> base64 string -> stored as bytes -> returned as hex

        let originalData = Data([0x85, 0x6f, 0x4a, 0x83])
        let base64String = originalData.base64EncodedString() // "hW9Kgw=="
        let base64Bytes = base64String.data(using: .utf8)! // ASCII bytes of "hW9Kgw=="
        // Use \\\\x to create valid JSON with escaped backslash (\\x in JSON bytes -> \x when decoded)
        let hexOfBase64 = "\\\\x" + base64Bytes.map { String(format: "%02x", $0) }.joined()

        let jsonData = "\"\(hexOfBase64)\"".data(using: .utf8)!
        let decoder = JSONDecoder()
        let bytea = try decoder.decode(PostgresBytea.self, from: jsonData)

        // Should correctly decode the double-encoded data
        XCTAssertEqual(bytea.data, originalData, "Should decode double-encoded base64 correctly")
    }

    // MARK: - Field-Level Merge Tests

    func testFieldLevelMergeRemoteDescriptionApplied() {
        // Scenario: Local has no description, remote has description
        // Expected: Remote description should be applied

        let localTask = MockTask(
            title: "Task",
            status: "queued",
            description: nil,
            updatedAt: Date()
        )

        let remoteTask = MockSyncTask(
            title: "Task",
            status: "queued",
            description: "Remote description",
            updatedAt: Date().addingTimeInterval(-60) // Remote is older
        )

        applyFieldLevelMerge(local: localTask, remote: remoteTask)

        // Even though remote is older, description should be applied because local was nil
        XCTAssertEqual(localTask.description, "Remote description")
    }

    func testFieldLevelMergeLocalDescriptionPreserved() {
        // Scenario: Local has description, remote has nil
        // Expected: Local description should be preserved

        let localTask = MockTask(
            title: "Task",
            status: "queued",
            description: "Local description",
            updatedAt: Date()
        )

        let remoteTask = MockSyncTask(
            title: "Task",
            status: "queued",
            description: nil,
            updatedAt: Date().addingTimeInterval(60) // Remote is newer
        )

        applyFieldLevelMerge(local: localTask, remote: remoteTask)

        // Local description should be preserved even though remote is newer (don't delete data)
        XCTAssertEqual(localTask.description, "Local description")
    }

    func testFieldLevelMergeStatusFromNewerRemote() {
        // Scenario: Both have status, remote is newer
        // Expected: Remote status should be applied

        let localTask = MockTask(
            title: "Task",
            status: "queued",
            description: nil,
            updatedAt: Date()
        )

        let remoteTask = MockSyncTask(
            title: "Task",
            status: "running",
            description: nil,
            updatedAt: Date().addingTimeInterval(60) // Remote is newer
        )

        applyFieldLevelMerge(local: localTask, remote: remoteTask)

        XCTAssertEqual(localTask.status, "running")
    }

    func testFieldLevelMergeStatusFromOlderRemoteNotApplied() {
        // Scenario: Both have status, local is newer
        // Expected: Local status should be preserved

        let localTask = MockTask(
            title: "Task",
            status: "running",
            description: nil,
            updatedAt: Date()
        )

        let remoteTask = MockSyncTask(
            title: "Task",
            status: "queued",
            description: nil,
            updatedAt: Date().addingTimeInterval(-60) // Remote is older
        )

        applyFieldLevelMerge(local: localTask, remote: remoteTask)

        XCTAssertEqual(localTask.status, "running")
    }

    // MARK: - AutomergeStore Tests

    func testAutomergeStoreDocumentCreation() async {
        await MainActor.run {
            let store = AutomergeStore.shared
            let id = UUID()

            // Get document (creates new one)
            let doc1 = store.document(for: id)

            // Get same document again
            let doc2 = store.document(for: id)

            // Should be the same instance
            XCTAssertTrue(doc1 === doc2, "Should return same document instance")
        }
    }

    func testAutomergeStoreMerge() async throws {
        try await MainActor.run {
            let store = AutomergeStore.shared
            let id = UUID()

            // Create local document with initial state
            let localDoc = store.document(for: id)
            try localDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))

            // Create remote document with different state
            let remoteDoc = Document()
            try remoteDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
            try remoteDoc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Added by remote"))
            let remoteBytes = remoteDoc.save()

            // Merge remote into local
            try store.merge(id: id, remoteBytes: remoteBytes)

            // Both values should be present (description was only in remote)
            if case .Scalar(.String(let desc)) = try localDoc.get(obj: .ROOT, key: TaskSchema.description) {
                XCTAssertEqual(desc, "Added by remote")
            } else {
                XCTFail("Description should be present after merge")
            }

            // Clean up
            store.remove(id: id)
        }
    }

    // MARK: - Helper Methods

    /// Simplified field-level merge for testing
    private func applyFieldLevelMerge(local: MockTask, remote: MockSyncTask) {
        let remoteNewer = remote.updatedAt > local.updatedAt

        // Title: always has value, use timestamp
        if remoteNewer {
            local.title = remote.title
        }

        // Description: prefer non-nil, then timestamp
        if local.description == nil && remote.description != nil {
            local.description = remote.description
        } else if local.description != nil && remote.description == nil {
            // Keep local (don't delete)
        } else if remoteNewer {
            local.description = remote.description
        }

        // Status: always has value, use timestamp
        if remoteNewer {
            local.status = remote.status
        }

        // Update timestamp to reflect merge
        local.updatedAt = max(local.updatedAt, remote.updatedAt)
    }
}

// MARK: - Mock Types

class MockTask {
    var title: String
    var status: String
    var description: String?
    var updatedAt: Date

    init(title: String, status: String, description: String?, updatedAt: Date) {
        self.title = title
        self.status = status
        self.description = description
        self.updatedAt = updatedAt
    }
}

struct MockSyncTask {
    let title: String
    let status: String
    let description: String?
    let updatedAt: Date
}
