import Foundation
import Supabase

// MARK: - Supabase Configuration

enum SupabaseConfig {
    // Supabase project credentials
    // Dashboard: https://supabase.com/dashboard/project/ywofbigbobyjruvlihky/settings/api
    static let url = URL(string: "https://ywofbigbobyjruvlihky.supabase.co")!
    static let anonKey = "sb_publishable__EHz-57q8-SNRzv8VYGibg_Yeh5gJ2L"
}

// MARK: - Supabase Client

@MainActor
final class SupabaseManager {
    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        print("[SupabaseManager] Initializing Supabase client")
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.anonKey
        )
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
