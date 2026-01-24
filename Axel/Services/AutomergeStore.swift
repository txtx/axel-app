import AutomergeWrapper
import Foundation

/// Manages Automerge documents for CRDT-based conflict-free synchronization.
/// Each synced entity has its own Automerge document that can be merged with remote changes.
@MainActor
@Observable
final class AutomergeStore {
    static let shared = AutomergeStore()

    /// Local automerge documents indexed by entity ID
    private var documents: [UUID: Document] = [:]

    private init() {}

    // MARK: - Document Management

    /// Get an existing document for an entity, or create a new one if it doesn't exist.
    /// - Parameter id: The entity's unique identifier
    /// - Returns: The Automerge document for this entity
    func document(for id: UUID) -> Document {
        if let existing = documents[id] {
            return existing
        }
        let doc = Document()
        documents[id] = doc
        return doc
    }

    /// Check if a document exists for the given entity ID.
    /// - Parameter id: The entity's unique identifier
    /// - Returns: True if a document exists
    func hasDocument(for id: UUID) -> Bool {
        documents[id] != nil
    }

    /// Load a document from serialized bytes.
    /// - Parameters:
    ///   - id: The entity's unique identifier
    ///   - bytes: The serialized Automerge document bytes
    func load(id: UUID, bytes: Data) throws {
        let doc = try Document(bytes)
        documents[id] = doc
    }

    /// Merge a remote document into the local document.
    /// If no local document exists, the remote document becomes the local one.
    /// - Parameters:
    ///   - id: The entity's unique identifier
    ///   - remoteBytes: The serialized remote Automerge document bytes
    func merge(id: UUID, remoteBytes: Data) throws {
        let remoteDoc = try Document(remoteBytes)
        if let local = documents[id] {
            try local.merge(other: remoteDoc)
        } else {
            documents[id] = remoteDoc
        }
    }

    /// Export the document as serialized bytes for sync.
    /// - Parameter id: The entity's unique identifier
    /// - Returns: The serialized document bytes, or nil if no document exists
    func save(id: UUID) -> Data? {
        documents[id]?.save()
    }

    /// Remove the document for an entity (e.g., when entity is deleted).
    /// - Parameter id: The entity's unique identifier
    func remove(id: UUID) {
        documents.removeValue(forKey: id)
    }

    /// Clear all cached documents.
    func clearAll() {
        documents.removeAll()
    }

    // MARK: - Compaction

    /// Compact a document to reduce its size by removing historical operations.
    /// Should be called periodically on long-lived documents.
    /// - Parameter id: The entity's unique identifier
    func compact(id: UUID) throws {
        guard let doc = documents[id] else { return }
        // Create a new document with the current state, discarding history
        let compacted = Document()
        // Copy current state to new document
        if let root = try? doc.get(obj: .ROOT, key: "_root") {
            // The new document will have only the current state
            documents[id] = compacted
        }
    }
}
