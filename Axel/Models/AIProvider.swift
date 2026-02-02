import Foundation

/// AI provider / shell type for terminal sessions
enum AIProvider: String, Codable, CaseIterable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case opencode = "opencode"
    case antigravity = "antigravity"
    case shell = "shell"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .antigravity: return "Antigravity"
        case .shell: return "Shell"
        case .custom: return "Custom"
        }
    }

    var commandName: String {
        rawValue
    }

    /// Initialize from shell type string, defaulting to custom for unknown types
    init(shellType: String) {
        self = AIProvider(rawValue: shellType) ?? .custom
    }
}
