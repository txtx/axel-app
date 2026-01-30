import Foundation

/// AI provider for terminal sessions
enum AIProvider: String, Codable, CaseIterable, Sendable {
    case claude = "claude"
    case codex = "codex"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var commandName: String {
        rawValue
    }
}
