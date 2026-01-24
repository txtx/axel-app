import Foundation
import SwiftUI
import SwiftData
import Supabase
import AuthenticationServices

// MARK: - Auth Service

@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    private let supabase = SupabaseManager.shared.client

    var currentUser: User?
    var isAuthenticated: Bool { currentUser != nil }
    var isLoading = false
    var authError: Error?

    private init() {
        print("[AuthService] Initializing AuthService")
        Task {
            await checkSession()
        }
    }

    // MARK: - Check Existing Session

    func checkSession() async {
        let user = await Task.detached { [supabase] in
            try? await supabase.auth.session.user
        }.value
        self.currentUser = user
    }

    // MARK: - GitHub Sign In

    func signInWithGitHub() async {
        print("[AuthService] signInWithGitHub called")
        isLoading = true
        authError = nil

        do {
            // Get the OAuth URL from Supabase (network call on background)
            let redirectString = "axel://auth/callback"
            let redirectURL = URL(string: redirectString)!

            let url = try await Task.detached { [supabase] in
                var url = try await supabase.auth.getOAuthSignInURL(
                    provider: .github,
                    redirectTo: redirectURL
                )

                // Manually rebuild with encoded redirect_to
                if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.queryItems = components.queryItems?.map { item in
                        if item.name == "redirect_to" {
                            return URLQueryItem(name: item.name, value: item.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed))
                        }
                        return item
                    }
                    if let encodedURL = components.url {
                        url = encodedURL
                    }
                }
                return url
            }.value

            print("[AuthService] Opening URL: \(url)")
            #if os(macOS)
            let opened = NSWorkspace.shared.open(url)
            print("[AuthService] Browser opened: \(opened)")
            #else
            let opened = await UIApplication.shared.open(url)
            print("[AuthService] Safari opened: \(opened)")
            #endif
        } catch {
            authError = error
            print("[AuthService] GitHub sign in error: \(error)")
        }

        isLoading = false
    }

    // MARK: - Handle OAuth Callback

    func handleOAuthCallback(url: URL) async {
        isLoading = true
        authError = nil

        do {
            let user = try await Task.detached { [supabase] in
                let session = try await supabase.auth.session(from: url)
                return session.user
            }.value
            currentUser = user
            print("[AuthService] Signed in as: \(user.email ?? "unknown")")
        } catch {
            authError = error
            print("[AuthService] OAuth callback error: \(error)")
        }

        isLoading = false
    }

    // MARK: - Sign Out

    func signOut(clearingLocalData context: ModelContext? = nil) async {
        isLoading = true

        do {
            try await Task.detached { [supabase] in
                try await supabase.auth.signOut()
            }.value

            // Clear local SwiftData if context provided
            if let context = context {
                clearLocalData(context: context)
            }

            // Ensure the orphan cleanup never runs after re-login with empty local store
            UserDefaults.standard.set(true, forKey: "hasRunDeletionCleanup")

            currentUser = nil
        } catch {
            authError = error
            print("[AuthService] Sign out error: \(error)")
        }

        isLoading = false
    }

    // MARK: - Clear Local Data

    private func clearLocalData(context: ModelContext) {
        do {
            // Delete individually to respect cascade rules and inverse relationships.
            // Batch deletes (context.delete(model:)) can't manage inverse relationship
            // updates, causing "mandatory OTO nullify inverse" CoreData errors.

            // Delete organizations first — cascades to Workspace, OrganizationMember, OrganizationInvitation.
            // Workspace cascade further deletes WorkTask, Skill, Context, Terminal.
            // WorkTask cascade deletes Hint, TaskAssignee, TaskComment, TaskAttachment, TaskDispatch.
            let organizations = try context.fetch(FetchDescriptor<Organization>())
            for org in organizations {
                context.delete(org)
            }

            // Delete any orphan workspaces (personal workspaces without an org)
            let workspaces = try context.fetch(FetchDescriptor<Workspace>())
            for ws in workspaces {
                context.delete(ws)
            }

            // Delete remaining standalone entities
            let profiles = try context.fetch(FetchDescriptor<Profile>())
            for profile in profiles {
                context.delete(profile)
            }

            try context.save()
            print("[AuthService] Cleared all local data")
        } catch {
            print("[AuthService] Error clearing local data: \(error)")
        }
    }

    // MARK: - Get User ID for Sync

    var userId: String? {
        currentUser?.id.uuidString
    }
}

// MARK: - JSON Value Extension

extension AnyJSON {
    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }
}
