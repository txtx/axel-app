import Foundation

// MARK: - Core Types

/// Represents the type of change for a line in a diff
public enum DiffLineType: Hashable, Sendable {
    case context
    case addition
    case deletion
}

/// A single line in a diff with its metadata
public struct DiffLine: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let type: DiffLineType
    public let content: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(
        id: UUID = UUID(),
        type: DiffLineType,
        content: String,
        oldLineNumber: Int?,
        newLineNumber: Int?
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A hunk represents a contiguous block of changes
public struct DiffHunk: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]
    public let header: String?

    public init(
        id: UUID = UUID(),
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine],
        header: String? = nil
    ) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.header = header
    }

    public var headerString: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(header.map { " \($0)" } ?? "")"
    }
}

/// Represents a complete file diff
public struct FileDiff: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let oldPath: String?
    public let newPath: String?
    public let hunks: [DiffHunk]
    public let changeType: FileChangeType
    public let language: String?

    public init(
        id: UUID = UUID(),
        oldPath: String?,
        newPath: String?,
        hunks: [DiffHunk],
        changeType: FileChangeType = .modified,
        language: String? = nil
    ) {
        self.id = id
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.changeType = changeType
        self.language = language ?? Self.detectLanguage(from: newPath ?? oldPath)
    }

    public var displayPath: String {
        newPath ?? oldPath ?? "unknown"
    }

    public var additions: Int {
        hunks.flatMap(\.lines).filter { $0.type == .addition }.count
    }

    public var deletions: Int {
        hunks.flatMap(\.lines).filter { $0.type == .deletion }.count
    }

    private static func detectLanguage(from path: String?) -> String? {
        guard let path = path else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        return languageMap[ext]
    }

    private static let languageMap: [String: String] = [
        "swift": "swift",
        "ts": "typescript",
        "tsx": "typescript",
        "js": "javascript",
        "jsx": "javascript",
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "kt": "kotlin",
        "c": "c",
        "cpp": "cpp",
        "h": "c",
        "hpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "scss": "scss",
        "html": "html",
        "xml": "xml",
        "json": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "md": "markdown",
        "sql": "sql",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash"
    ]
}

/// Type of file change
public enum FileChangeType: String, Hashable, Sendable {
    case added = "A"
    case deleted = "D"
    case modified = "M"
    case renamed = "R"
    case copied = "C"
}

/// A complete patch containing multiple file diffs
public struct Patch: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let files: [FileDiff]
    public let metadata: PatchMetadata?

    public init(
        id: UUID = UUID(),
        files: [FileDiff],
        metadata: PatchMetadata? = nil
    ) {
        self.id = id
        self.files = files
        self.metadata = metadata
    }

    public var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    public var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }
}

/// Metadata for a patch (e.g., from git)
public struct PatchMetadata: Hashable, Sendable {
    public let commitHash: String?
    public let author: String?
    public let date: Date?
    public let message: String?

    public init(
        commitHash: String? = nil,
        author: String? = nil,
        date: Date? = nil,
        message: String? = nil
    ) {
        self.commitHash = commitHash
        self.author = author
        self.date = date
        self.message = message
    }
}

// MARK: - Split View Types

/// A row for split diff view (side-by-side)
public struct SplitDiffRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let leftLine: DiffLine?
    public let rightLine: DiffLine?

    public init(
        id: UUID = UUID(),
        leftLine: DiffLine?,
        rightLine: DiffLine?
    ) {
        self.id = id
        self.leftLine = leftLine
        self.rightLine = rightLine
    }
}

// MARK: - Inline Diff Types

/// Represents an inline change within a line (word-level diff)
public struct InlineChange: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let type: DiffLineType
    public let text: String

    public init(
        id: UUID = UUID(),
        type: DiffLineType,
        text: String
    ) {
        self.id = id
        self.type = type
        self.text = text
    }
}

/// A line with inline (word-level) changes highlighted
public struct InlineDiffLine: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let type: DiffLineType
    public let segments: [InlineSegment]
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(
        id: UUID = UUID(),
        type: DiffLineType,
        segments: [InlineSegment],
        oldLineNumber: Int?,
        newLineNumber: Int?
    ) {
        self.id = id
        self.type = type
        self.segments = segments
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A segment of text within an inline diff line
public struct InlineSegment: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let isChanged: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        isChanged: Bool
    ) {
        self.id = id
        self.text = text
        self.isChanged = isChanged
    }
}
