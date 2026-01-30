import XCTest
import Foundation
@testable import Axel
import AutomergeWrapper

/// Integration tests for the sync engine that simulate real sync scenarios.
/// These tests verify the complete flow of:
/// 1. Local changes being captured in automerge
/// 2. Remote changes being merged correctly
/// 3. Bidirectional sync between devices
final class SyncIntegrationTests: XCTestCase {

    // MARK: - Scenario: iOS changes status, macOS should receive it

    func testStatusChangeFromiOSToMacOS() throws {
        // Initial state on both devices: task with status "queued"
        let taskId = UUID()
        let initialDoc = Document()
        try initialDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Test Task"))
        try initialDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let initialBytes = initialDoc.save()

        // Simulate iOS: user changes status to "running"
        let iosDoc = try Document(initialBytes)
        try iosDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        let iosBytes = iosDoc.save()

        // Simulate macOS: receives iOS's changes
        let macDoc = try Document(initialBytes)
        try macDoc.merge(other: try Document(iosBytes))

        // Verify macOS has the status change
        if case .Scalar(.String(let status)) = try macDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "macOS should have iOS's status change")
        } else {
            XCTFail("Failed to read status on macOS")
        }
    }

    // MARK: - Scenario: Concurrent edits to different fields

    func testConcurrentEditsDifferentFields() throws {
        // Initial state: task with title and status, no description
        let initialDoc = Document()
        try initialDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Initial Title"))
        try initialDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let initialBytes = initialDoc.save()

        // iOS edits description
        let iosDoc = try Document(initialBytes)
        try iosDoc.put(obj: .ROOT, key: TaskSchema.description, value: .String("iOS added this description"))

        // macOS edits status (concurrently, without knowing about iOS's change)
        let macDoc = try Document(initialBytes)
        try macDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))

        // Both devices sync - merge both docs
        let iosBytes = iosDoc.save()
        let macBytes = macDoc.save()

        // iOS receives macOS's changes
        try iosDoc.merge(other: try Document(macBytes))

        // Verify iOS has BOTH changes
        if case .Scalar(.String(let desc)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "iOS added this description", "iOS should have its own description")
        }
        if case .Scalar(.String(let status)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "iOS should have macOS's status change")
        }

        // macOS receives iOS's changes
        try macDoc.merge(other: try Document(iosBytes))

        // Verify macOS has BOTH changes
        if case .Scalar(.String(let desc)) = try macDoc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "iOS added this description", "macOS should have iOS's description")
        }
        if case .Scalar(.String(let status)) = try macDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "macOS should have its own status change")
        }
    }

    // MARK: - Scenario: Local change should not be overwritten by older remote

    func testLocalChangeNotOverwrittenByOlderRemote() throws {
        // Initial state
        let initialDoc = Document()
        try initialDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let initialBytes = initialDoc.save()

        // iOS makes a change (newer)
        let iosDoc = try Document(initialBytes)
        try iosDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        let iosBytes = iosDoc.save()

        // Simulate: iOS already has its local change, now receives an OLDER remote state
        // (e.g., the server had an old version)
        // When we merge, automerge uses internal clocks, not timestamps
        // So the "newer" write in automerge terms wins

        // In this case, since iosDoc made the change after loading initialBytes,
        // iosDoc's status should win
        let resultDoc = try Document(iosBytes)
        try resultDoc.merge(other: try Document(initialBytes))

        if case .Scalar(.String(let status)) = try resultDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "Local change should be preserved")
        }
    }

    // MARK: - Scenario: Empty local doc merged with populated remote

    func testEmptyLocalMergedWithPopulatedRemote() throws {
        // Local: empty document (simulating first sync)
        let localDoc = Document()

        // Remote: has task data
        let remoteDoc = Document()
        try remoteDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Remote Task"))
        try remoteDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        try remoteDoc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Remote description"))

        // Merge remote into local
        try localDoc.merge(other: remoteDoc)

        // Local should now have all remote data
        if case .Scalar(.String(let title)) = try localDoc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Remote Task")
        } else {
            XCTFail("Title should be present after merge")
        }

        if case .Scalar(.String(let status)) = try localDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running")
        } else {
            XCTFail("Status should be present after merge")
        }

        if case .Scalar(.String(let desc)) = try localDoc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Remote description")
        } else {
            XCTFail("Description should be present after merge")
        }
    }

    // MARK: - Scenario: Multiple sync cycles

    func testMultipleSyncCycles() throws {
        // Cycle 1: Create task on iOS
        let iosDoc = Document()
        try iosDoc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Task"))
        try iosDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        var serverBytes = iosDoc.save()

        // Cycle 2: macOS syncs and changes status
        var macDoc = try Document(serverBytes)
        try macDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        serverBytes = macDoc.save()

        // Cycle 3: iOS syncs and adds description
        var iosDoc2 = try Document(serverBytes)
        try iosDoc2.merge(other: macDoc) // Get macOS's changes
        try iosDoc2.put(obj: .ROOT, key: TaskSchema.description, value: .String("Added by iOS"))
        serverBytes = iosDoc2.save()

        // Cycle 4: macOS syncs and changes priority
        let macDoc2 = try Document(serverBytes)
        try macDoc2.merge(other: iosDoc2) // Get iOS's changes
        try macDoc2.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(100))

        // Final state should have all changes
        if case .Scalar(.String(let status)) = try macDoc2.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running")
        }
        if case .Scalar(.String(let desc)) = try macDoc2.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Added by iOS")
        }
        if case .Scalar(.Int(let priority)) = try macDoc2.get(obj: .ROOT, key: TaskSchema.priority) {
            XCTAssertEqual(priority, 100)
        }
    }

    // MARK: - Scenario: Document serialization round-trip

    func testDocumentSerializationRoundTrip() throws {
        let doc = Document()
        try doc.put(obj: .ROOT, key: TaskSchema.title, value: .String("Test"))
        try doc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        try doc.put(obj: .ROOT, key: TaskSchema.description, value: .String("Description"))
        try doc.put(obj: .ROOT, key: TaskSchema.priority, value: .Int(50))

        // Serialize
        let bytes = doc.save()

        // Simulate hex encoding (what Supabase does)
        let hexString = bytes.map { String(format: "%02x", $0) }.joined()

        // Simulate hex decoding (what we do when reading)
        var decodedBytes = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = String(hexString[index..<nextIndex])
            if let byte = UInt8(byteString, radix: 16) {
                decodedBytes.append(byte)
            }
            index = nextIndex
        }

        // Should be able to load
        let loadedDoc = try Document(decodedBytes)

        // Verify all fields
        if case .Scalar(.String(let title)) = try loadedDoc.get(obj: .ROOT, key: TaskSchema.title) {
            XCTAssertEqual(title, "Test")
        }
        if case .Scalar(.String(let status)) = try loadedDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "queued")
        }
        if case .Scalar(.String(let desc)) = try loadedDoc.get(obj: .ROOT, key: TaskSchema.description) {
            XCTAssertEqual(desc, "Description")
        }
        if case .Scalar(.Int(let priority)) = try loadedDoc.get(obj: .ROOT, key: TaskSchema.priority) {
            XCTAssertEqual(priority, 50)
        }
    }

    // MARK: - Scenario: Correct merge behavior

    func testCorrectMergeWithoutCapturingLocalFirst() throws {
        // The fix: DON'T write to local doc before merging

        // Initial state
        let initialDoc = Document()
        try initialDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("queued"))
        let initialBytes = initialDoc.save()

        // iOS: has the initial state
        let iosDoc = try Document(initialBytes)

        // macOS: changes status to "running" and syncs to server
        let macDoc = try Document(initialBytes)
        try macDoc.put(obj: .ROOT, key: TaskSchema.status, value: .String("running"))
        let serverBytes = macDoc.save()

        // iOS syncs: THE FIX - just merge, don't capture local state first
        try iosDoc.merge(other: try Document(serverBytes)) // Merge remote

        // macOS's "running" should be present
        if case .Scalar(.String(let status)) = try iosDoc.get(obj: .ROOT, key: TaskSchema.status) {
            XCTAssertEqual(status, "running", "Remote change should be applied")
        }
    }
}
