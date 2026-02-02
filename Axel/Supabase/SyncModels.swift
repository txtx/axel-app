import Foundation

// MARK: - PostgreSQL BYTEA Wrapper

/// Wrapper for PostgreSQL BYTEA data that handles both hex and base64 encoding
struct PostgresBytea: Codable, Sendable {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try to decode as a string first (PostgreSQL hex or base64 format)
        if let string = try? container.decode(String.self) {
            // Check for PostgreSQL hex format: \x followed by hex digits
            if string.hasPrefix("\\x") {
                let hexString = String(string.dropFirst(2))
                if let hexData = Data(hexString: hexString) {
                    // The hex-decoded data might itself be base64 (Supabase stores our base64 as bytes)
                    // Check if the decoded bytes look like a base64 string and decode again
                    if let base64String = String(data: hexData, encoding: .utf8),
                       let finalData = Data(base64Encoded: base64String) {
                        self.data = finalData
                        return
                    }
                    // Otherwise use the hex-decoded data directly
                    self.data = hexData
                    return
                }
            }

            // Try base64 decoding
            if let data = Data(base64Encoded: string) {
                self.data = data
                return
            }

            // Try treating it as raw hex without prefix
            if let hexData = Data(hexString: string) {
                // Again, check if it's base64
                if let base64String = String(data: hexData, encoding: .utf8),
                   let finalData = Data(base64Encoded: base64String) {
                    self.data = finalData
                    return
                }
                self.data = hexData
                return
            }

            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "String is not valid hex or base64: \(string.prefix(50))..."
                )
            )
        }

        // Try to decode as raw Data (base64 in JSON)
        self.data = try container.decode(Data.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // Encode as hex string with \x prefix for PostgreSQL BYTEA
        // This is the native PostgreSQL format and avoids double-encoding issues
        let hexString = "\\x" + data.map { String(format: "%02x", $0) }.joined()
        try container.encode(hexString)
    }
}

// Extension to convert hex string to Data
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex

        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - Sync Models (Codable structs for Supabase)

struct SyncProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var email: String?
    var fullName: String?
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case fullName = "full_name"
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct SyncOrganization: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var slug: String
    var avatarUrl: String?
    var createdAt: Date
    var updatedAt: Date
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case automergeDoc = "automerge_doc"
    }

    /// Convenience accessor for the raw bytes
    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncOrganizationMember: Codable, Identifiable, Sendable {
    let id: UUID
    var organizationId: UUID
    var userId: UUID
    var role: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case organizationId = "organization_id"
        case userId = "user_id"
        case role
        case createdAt = "created_at"
    }
}

struct SyncWorkspace: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var slug: String
    var ownerId: UUID?
    var organizationId: UUID?
    var createdAt: Date
    var updatedAt: Date
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case ownerId = "owner_id"
        case organizationId = "organization_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncTask: Codable, Identifiable, Sendable {
    let id: UUID
    var workspaceId: UUID?
    var title: String
    var description: String?
    var status: String
    var priority: Int
    var createdById: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case title
        case description
        case status
        case priority
        case createdById = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

// For updating existing tasks (only fields that can be updated)
struct SyncTaskUpdate: Encodable, Sendable {
    var title: String
    var description: String?
    var status: String
    var priority: Int
    var updatedAt: Date
    var completedAt: Date?
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case status
        case priority
        case updatedAt = "updated_at"
        case completedAt = "completed_at"
        case automergeDoc = "automerge_doc"
    }

    init(title: String, description: String?, status: String, priority: Int, updatedAt: Date, completedAt: Date?, automergeDocData: Data?) {
        self.title = title
        self.description = description
        self.status = status
        self.priority = priority
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.automergeDoc = automergeDocData.map { PostgresBytea($0) }
    }
}

struct SyncTaskAssignee: Codable, Identifiable, Sendable {
    let id: UUID
    var taskId: UUID
    var profileId: UUID
    var assignedAt: Date
    var assignedById: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case profileId = "profile_id"
        case assignedAt = "assigned_at"
        case assignedById = "assigned_by"
    }
}

struct SyncTaskComment: Codable, Identifiable, Sendable {
    let id: UUID
    var taskId: UUID
    var userId: UUID
    var content: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case userId = "user_id"
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct SyncTaskAttachment: Codable, Identifiable, Sendable {
    let id: UUID
    var taskId: UUID
    var userId: UUID
    var fileName: String
    var fileUrl: String
    var fileType: String?
    var fileSize: Int?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case userId = "user_id"
        case fileName = "file_name"
        case fileUrl = "file_url"
        case fileType = "file_type"
        case fileSize = "file_size"
        case createdAt = "created_at"
    }
}

struct SyncTerminal: Codable, Identifiable, Sendable {
    let id: UUID
    var workspaceId: UUID?
    var taskId: UUID?
    var name: String?
    var status: String
    var startedAt: Date
    var endedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case taskId = "task_id"
        case name
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncTaskDispatch: Codable, Identifiable, Sendable {
    let id: UUID
    var taskId: UUID
    var terminalId: UUID
    var status: String
    var dispatchedAt: Date
    var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case terminalId = "terminal_id"
        case status
        case dispatchedAt = "dispatched_at"
        case completedAt = "completed_at"
    }
}

struct SyncHint: Codable, Identifiable, Sendable {
    let id: UUID
    var terminalId: UUID?
    var taskId: UUID?
    var type: String
    var title: String
    var description: String?
    var options: [SyncHintOption]?
    var response: AnyCodable?
    var status: String
    var createdAt: Date
    var answeredAt: Date?
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case terminalId = "terminal_id"
        case taskId = "task_id"
        case type
        case title
        case description
        case options
        case response
        case status
        case createdAt = "created_at"
        case answeredAt = "answered_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncHintOption: Codable, Sendable {
    var label: String
    var value: String
}

struct SyncSkill: Codable, Identifiable, Sendable {
    let id: UUID
    var workspaceId: UUID?
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case name
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncContext: Codable, Identifiable, Sendable {
    let id: UUID
    var workspaceId: UUID?
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var automergeDoc: PostgresBytea?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case name
        case content
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case automergeDoc = "automerge_doc"
    }

    var automergeDocData: Data? { automergeDoc?.data }
}

struct SyncOrganizationInvitation: Codable, Identifiable, Sendable {
    let id: UUID
    var organizationId: UUID
    var email: String
    var role: String
    var invitedBy: UUID?
    var status: String
    var createdAt: Date
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case organizationId = "organization_id"
        case email
        case role
        case invitedBy = "invited_by"
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

// MARK: - Helper for JSON fields

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let string as String:
            try container.encode(string)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let bool as Bool:
            try container.encode(bool)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
