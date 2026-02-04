import Foundation

/// Information about a git worktree
struct WorktreeInfo: Identifiable, Hashable {
    let id: String  // Branch name or "main" for primary
    let path: String
    let branch: String?
    let isMain: Bool

    /// Display name for the worktree
    var displayName: String {
        branch ?? "main"
    }
}

/// Service for discovering git worktrees in a workspace
@MainActor
@Observable
final class WorktreeService {
    static let shared = WorktreeService()

    private init() {}

    /// List all worktrees in the given workspace path
    /// - Parameter workspacePath: The path to the git repository
    /// - Returns: Array of WorktreeInfo, sorted with main first then alphabetically
    func listWorktrees(in workspacePath: String) async -> [WorktreeInfo] {
        #if os(macOS)
        let path = workspacePath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.parseWorktrees(in: path)
                continuation.resume(returning: result)
            }
        }
        #else
        // Worktrees are not supported on iOS
        return []
        #endif
    }

    #if os(macOS)
    /// Parse git worktree list output
    private nonisolated static func parseWorktrees(in workspacePath: String) -> [WorktreeInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["worktree", "list", "--porcelain"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("[WorktreeService] Failed to run git worktree list: \(error)")
            return []
        }

        guard process.terminationStatus == 0 else {
            print("[WorktreeService] git worktree list failed with status: \(process.terminationStatus)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return Self.parsePortableOutput(output)
    }

    /// Parse the porcelain output format from git worktree list
    /// Format:
    /// worktree /path/to/worktree
    /// HEAD abc123
    /// branch refs/heads/branch-name
    /// (blank line)
    private nonisolated static func parsePortableOutput(_ output: String) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentBranch: String?
        var isFirstWorktree = true

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("worktree ") {
                // Save previous worktree if exists
                if let path = currentPath {
                    let branchName = currentBranch
                    worktrees.append(WorktreeInfo(
                        id: branchName ?? "main",
                        path: path,
                        branch: branchName,
                        isMain: isFirstWorktree
                    ))
                    isFirstWorktree = false
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch ") {
                // Extract branch name from refs/heads/branch-name
                let ref = String(line.dropFirst("branch ".count))
                if ref.hasPrefix("refs/heads/") {
                    currentBranch = String(ref.dropFirst("refs/heads/".count))
                } else {
                    currentBranch = ref
                }
            }
        }

        // Don't forget the last worktree
        if let path = currentPath {
            let branchName = currentBranch
            worktrees.append(WorktreeInfo(
                id: branchName ?? "main",
                path: path,
                branch: branchName,
                isMain: isFirstWorktree
            ))
        }

        // Sort: main first, then alphabetically by branch name
        return worktrees.sorted { lhs, rhs in
            if lhs.isMain { return true }
            if rhs.isMain { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
    #endif
}
