import Foundation
import Supabase

// MARK: - Supabase Configuration

enum SupabaseConfig {
    // Supabase project credentials
    static let url: URL? = {
        let raw = env("SUPABASE_URL") ?? info("SUPABASE_URL")
        guard let raw else { return nil }
        guard let url = URL(string: raw) else {
            return nil
        }
        return url
    }()

    static let anonKey: String? = {
        let value = env("SUPABASE_ANON_KEY") ?? info("SUPABASE_ANON_KEY")
        return value?.isEmpty == false ? value : nil
    }()

    private static func env(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    private static func info(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return value?.isEmpty == false ? value : nil
    }
}

// MARK: - Supabase Client

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient?

    private init() {
        guard let url = SupabaseConfig.url,
              let anonKey = SupabaseConfig.anonKey
        else {
            print("[SupabaseManager] Supabase disabled (missing SUPABASE_URL or SUPABASE_ANON_KEY)")
            client = nil
            return
        }

        print("[SupabaseManager] Initializing Supabase client")
        client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }
}

// MARK: - Database Table Names

enum SupabaseTable: String {
    case profiles = "profiles"
    case organizations = "organizations"
    case organizationMembers = "organization_members"
    case organizationInvitations = "organization_invitations"
    case workspaces = "workspaces"
    case tasks = "tasks"
    case taskAssignees = "task_assignees"
    case taskComments = "task_comments"
    case taskAttachments = "task_attachments"
    case terminals = "terminals"
    case terminalSkills = "terminal_skills"
    case terminalContexts = "terminal_contexts"
    case taskDispatches = "task_dispatches"
    case hints = "hints"
    case skills = "skills"
    case contexts = "contexts"
}
