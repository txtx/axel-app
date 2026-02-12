import Foundation

/// Represents an event received from the axel server's SSE `/inbox` endpoint.
///
/// ## JSON Structure (from server)
/// ```json
/// {
///   "timestamp": "2025-01-01T00:00:00Z",
///   "event_type": "unknown_hook",   // Rust can't parse hook_event_name → falls back
///   "pane_id": "abc-123-...",        // ⚠️ May be wrong (see below)
///   "event": { ... }                 // Raw Claude Code hook payload
/// }
/// ```
///
/// ## Important: `paneId` Reliability
///
/// **`paneId` may be wrong** due to shared `.claude/settings.json` hooks. All events
/// from all Claude instances in a workspace may carry the same (last terminal's) paneId.
///
/// Use `InboxService.resolvedPaneId(for:)` or `CostTracker.shared.paneId(forSessionId:)`
/// to get the correct pane ID for routing, lookups, and response targeting.
///
/// The `event.claudeSessionId` is always correct and unique per Claude process.
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
    /// The pane ID (UUID string) from the URL path in the axel server.
    ///
    /// **⚠️ WARNING: This may be wrong.** Due to shared `.claude/settings.json` hooks,
    /// all events from all Claude instances may carry the last terminal's pane ID.
    /// Use `InboxService.resolvedPaneId(for:)` instead for routing and lookups.
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

    /// Programmatic initializer for creating events from OTEL data (Codex)
    init(paneId: String, eventType: String, event: InboxEventPayload) {
        self.id = UUID()
        self.timestamp = Date()
        self.paneId = paneId
        self.eventType = eventType
        self.event = event
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(paneId, forKey: .paneId)
        try container.encode(event, forKey: .event)
    }
}

/// The inner event payload from Claude Code hooks.
///
/// This is the raw JSON body that Claude Code sends to the hook command's stdin.
/// Key fields:
/// - `hookEventName`: The hook type ("PermissionRequest", "Stop", "PreToolUse", etc.)
///   Maps from `"hook_event_name"` in JSON. Note: the Rust server can't parse this
///   (it expects `"type"` via serde rename), so `event_type` falls back to `"unknown_hook"`.
/// - `claudeSessionId`: Unique per Claude process. Maps from `"session_id"` in JSON.
///   **This is always correct** and should be used as the primary key for per-session tracking.
/// - `toolName`, `toolInput`: Present for tool-related hooks (PermissionRequest, PreToolUse, PostToolUse).
/// - `permissionRequest`, `permissionSuggestions`: Present for PermissionRequest events.
struct InboxEventPayload: Codable {
    /// The hook event type: "PermissionRequest", "Stop", "PreToolUse", "PostToolUse", etc.
    let hookEventName: String?
    /// Working directory of the Claude Code process
    let cwd: String?
    let permissionMode: String?
    /// Claude session ID — unique per Claude Code process, always correct.
    /// Use this (not `paneId`) as the primary key for per-session tracking.
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

    /// Programmatic initializer for creating payloads from OTEL data (Codex)
    init(
        hookEventName: String?,
        claudeSessionId: String?,
        toolName: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        cwd: String? = nil,
        permissionOptions: [PermissionSuggestion]? = nil
    ) {
        self.hookEventName = hookEventName
        self.claudeSessionId = claudeSessionId
        self.toolName = toolName
        self.toolInput = toolInput
        self.cwd = cwd
        self.permissionMode = nil
        self.transcriptPath = nil
        self.toolResponse = nil
        self.toolUseId = nil
        self.permissionRequest = nil
        self.permissionSuggestions = permissionOptions
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
