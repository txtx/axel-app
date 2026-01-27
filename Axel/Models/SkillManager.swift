import Foundation
import SwiftUI

// MARK: - Local Agent File

/// Represents an agent file loaded from the filesystem
struct LocalAgentFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: URL
    let content: String

    init(path: URL) {
        self.id = path.absoluteString
        self.path = path
        // If the file is named SKILL.md, use the parent folder name instead
        if path.deletingPathExtension().lastPathComponent.uppercased() == "SKILL" {
            self.name = path.deletingLastPathComponent().lastPathComponent
        } else {
            self.name = path.deletingPathExtension().lastPathComponent
        }
        self.content = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocalAgentFile, rhs: LocalAgentFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Skill Manager

/// Singleton manager for loading and caching skills from the filesystem
@MainActor
final class SkillManager: ObservableObject {
    static let shared = SkillManager()

    /// Skills from the current workspace's ./skills directory
    @Published private(set) var workspaceSkills: [LocalAgentFile] = []

    /// Skills from ~/.config/axel/skills directory
    @Published private(set) var userSkills: [LocalAgentFile] = []

    /// All filesystem-based skills combined
    var allLocalSkills: [LocalAgentFile] {
        workspaceSkills + userSkills
    }

    /// Current workspace path for loading workspace skills
    private var currentWorkspacePath: String?

    private init() {
        #if os(macOS)
        loadUserSkills()
        #endif
    }

    // MARK: - Public Methods

    /// Load workspace skills from a specific workspace path
    func loadWorkspaceSkills(from workspacePath: String?) {
        guard let workspacePath = workspacePath else {
            workspaceSkills = []
            return
        }

        // Skip if already loaded for this workspace
        guard currentWorkspacePath != workspacePath else { return }
        currentWorkspacePath = workspacePath

        let skillsDir = URL(fileURLWithPath: workspacePath).appendingPathComponent("skills")

        guard FileManager.default.fileExists(atPath: skillsDir.path) else {
            workspaceSkills = []
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            workspaceSkills = files
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { LocalAgentFile(path: $0) }
        } catch {
            print("[SkillManager] Failed to load workspace skills: \(error)")
            workspaceSkills = []
        }
    }

    /// Reload all skills (useful after file changes)
    func reload() {
        #if os(macOS)
        loadUserSkills()
        #endif

        if let path = currentWorkspacePath {
            let savedPath = path
            currentWorkspacePath = nil // Force reload
            loadWorkspaceSkills(from: savedPath)
        }
    }

    // MARK: - Private Methods

    #if os(macOS)
    private func loadUserSkills() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let userSkillsDir = homeDir.appendingPathComponent(".config/axel/skills")

        guard FileManager.default.fileExists(atPath: userSkillsDir.path) else {
            userSkills = []
            return
        }

        do {
            // User skills use directory structure: <name>/SKILL.md or flat .md files
            let contents = try FileManager.default.contentsOfDirectory(
                at: userSkillsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var skills: [LocalAgentFile] = []

            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // Check for SKILL.md inside the directory
                    let skillFile = item.appendingPathComponent("SKILL.md")
                    if FileManager.default.fileExists(atPath: skillFile.path) {
                        skills.append(LocalAgentFile(path: skillFile))
                    }
                } else if item.pathExtension == "md" {
                    // Also support flat .md files (excluding index.md)
                    if item.lastPathComponent != "index.md" {
                        skills.append(LocalAgentFile(path: item))
                    }
                }
            }

            userSkills = skills.sorted { $0.name < $1.name }
        } catch {
            print("[SkillManager] Failed to load user skills: \(error)")
            userSkills = []
        }
    }
    #endif
}
