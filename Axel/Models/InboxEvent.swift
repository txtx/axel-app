import Foundation

/// Represents an event received from the axel server's SSE /inbox endpoint
struct InboxEvent: Identifiable, Codable, Hashable {
    let id: UUID

    static func == (lhs: InboxEvent, rhs: InboxEvent) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    let timestamp: Date
    let eventType: String
    /// The pane ID (UUID string) that identifies which terminal this event came from.
    /// This is extracted from the URL path in the axel server.
    let paneId: String
    let event: InboxEventPayload

    enum CodingKeys: String, CodingKey {
        case timestamp
        case eventType = "event_type"
        case paneId = "pane_id"
        case event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.eventType = try container.decode(String.self, forKey: .eventType)
        self.paneId = try container.decode(String.self, forKey: .paneId)
        self.event = try container.decode(InboxEventPayload.self, forKey: .event)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(paneId, forKey: .paneId)
        try container.encode(event, forKey: .event)
    }
}

/// The inner event payload from Claude Code hooks
struct InboxEventPayload: Codable {
    let hookEventName: String?
    let cwd: String?
    let permissionMode: String?
    let claudeSessionId: String?
    let transcriptPath: String?

    // Tool-related fields
    let toolName: String?
    let toolInput: [String: AnyCodable]?
    let toolResponse: [String: AnyCodable]?
    let toolUseId: String?

    // Permission request fields
    let permissionRequest: PermissionRequestInfo?
    let permissionSuggestions: [PermissionSuggestion]?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case cwd
        case permissionMode = "permission_mode"
        case claudeSessionId = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case toolUseId = "tool_use_id"
        case permissionRequest = "permission_request"
        case permissionSuggestions = "permission_suggestions"
    }
}

/// Permission request details
struct PermissionRequestInfo: Codable {
    let toolName: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case description
    }
}

/// Permission suggestion from Claude Code (e.g., "allow all edits this session")
struct PermissionSuggestion: Codable, Hashable, Sendable {
    let type: String  // e.g., "setMode"
    let mode: String?  // e.g., "acceptEdits"
    let destination: String?  // e.g., "session"

    /// Human-readable label for this suggestion
    var label: String {
        switch mode {
        case "acceptEdits":
            return "Yes, allow all edits this session"
        case "bypassPermissions":
            return "Yes, don't ask again this session"
        default:
            if destination == "session" {
                return "Yes, allow all this session"
            }
            return "Yes, allow"
        }
    }

    var shortLabel: String {
        switch mode {
        case "acceptEdits":
            return "Allow all edits"
        case "bypassPermissions":
            return "Allow all"
        default:
            return "Allow session"
        }
    }
}

/// A permission option that can be selected by the user
struct PermissionOption: Identifiable, Hashable {
    let id: Int  // The option number (1, 2, 3...)
    let label: String
    let shortLabel: String  // For compact display
    let isDestructive: Bool
    let suggestion: PermissionSuggestion?

    /// The response text to send for this option
    var responseText: String {
        "\(id)"
    }
}

// Note: AnyCodable is defined in SyncModels.swift

// MARK: - Display Helpers

extension InboxEvent {
    /// Human-readable title for the event
    var title: String {
        guard let hookName = event.hookEventName else {
            return eventType
        }

        switch hookName {
        case "PostToolUse":
            if let toolName = event.toolName {
                return "Used \(toolName)"
            }
            return "Tool Used"
        case "PreToolUse":
            if let toolName = event.toolName {
                return "Using \(toolName)"
            }
            return "Using Tool"
        case "PermissionRequest":
            return "Permission Required"
        case "Stop":
            return "Task Completed"
        case "SubagentStop":
            return "Subagent Completed"
        case "SessionStart":
            return "Session Started"
        case "SessionEnd":
            return "Session Ended"
        default:
            return hookName
        }
    }

    /// Subtitle with additional context
    var subtitle: String? {
        if let toolName = event.toolName {
            // Try to extract file path from tool input
            if let input = event.toolInput,
               let filePath = input["file_path"]?.value as? String {
                return "\(toolName): \(URL(fileURLWithPath: filePath).lastPathComponent)"
            }
            return toolName
        }

        if let cwd = event.cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }

        return nil
    }

    /// Icon name for the event type
    var iconName: String {
        guard let hookName = event.hookEventName else {
            return "bell"
        }

        switch hookName {
        case "PostToolUse", "PreToolUse":
            switch event.toolName {
            case "Read": return "doc.text"
            case "Write": return "square.and.pencil"
            case "Edit": return "pencil"
            case "Bash": return "terminal"
            case "Glob", "Grep": return "magnifyingglass"
            case "WebFetch", "WebSearch": return "globe"
            default: return "wrench"
            }
        case "PermissionRequest":
            return "lock.shield"
        case "Stop", "SubagentStop":
            return "checkmark.circle"
        case "SessionStart":
            return "play.circle"
        case "SessionEnd":
            return "stop.circle"
        default:
            return "bell"
        }
    }

    /// Generate permission options based on the event data
    /// Options are numbered 1, 2, 3... matching Claude Code's CLI
    var permissionOptions: [PermissionOption] {
        var options: [PermissionOption] = []
        var optionNum = 1

        // Option 1: Yes (always present for permission requests)
        options.append(PermissionOption(
            id: optionNum,
            label: "Yes",
            shortLabel: "Yes",
            isDestructive: false,
            suggestion: nil
        ))
        optionNum += 1

        // Middle options from permission_suggestions (e.g., "allow all edits this session")
        if let suggestions = event.permissionSuggestions {
            for suggestion in suggestions {
                options.append(PermissionOption(
                    id: optionNum,
                    label: suggestion.label,
                    shortLabel: suggestion.shortLabel,
                    isDestructive: false,
                    suggestion: suggestion
                ))
                optionNum += 1
            }
        }

        // Last option: No
        options.append(PermissionOption(
            id: optionNum,
            label: "No",
            shortLabel: "No",
            isDestructive: true,
            suggestion: nil
        ))

        return options
    }
}
