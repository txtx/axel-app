import Foundation

#if os(macOS)

/// Represents a tmux session discovered via `axel sessions ls --json`
struct RecoveredSession: Identifiable, Codable, Hashable {
    let name: String
    let windows: UInt32
    let panes: UInt32
    let created: UInt64
    let attached: Bool
    let workingDir: String?
    /// Server port (from AXEL_PORT environment)
    let port: UInt16?
    /// Axel pane ID (from AXEL_PANE_ID environment)
    let axelPaneId: String?

    var id: String { name }

    /// Creation date computed from Unix timestamp
    var createdDate: Date {
        Date(timeIntervalSince1970: TimeInterval(created))
    }

    /// Whether this session has recovery info (port and pane ID)
    var canRecover: Bool {
        port != nil && axelPaneId != nil
    }

    enum CodingKeys: String, CodingKey {
        case name
        case windows
        case panes
        case created
        case attached
        case workingDir = "working_dir"
        case port
        case axelPaneId = "axel_pane_id"
    }

    // Default Codable synthesis is sufficient (no backward compatibility needed).
}

/// Service that discovers existing axel tmux sessions via the CLI
@MainActor
@Observable
final class SessionRecoveryService {
    static let shared = SessionRecoveryService()

    /// Discovered tmux sessions from axel CLI
    private(set) var recoveredSessions: [RecoveredSession] = []

    /// Whether discovery is in progress
    private(set) var isDiscovering: Bool = false

    /// Last error from discovery
    private(set) var lastError: String?

    /// Timestamp of last successful discovery
    private(set) var lastDiscoveryTime: Date?

    /// Cached worktree info per workspace path (populated during recovery)
    private var worktreeCache: [String: [WorktreeInfo]] = [:]

    private init() {}

    /// Discover existing axel sessions by calling `axel sessions ls --json`
    func discoverSessions() async {
        isDiscovering = true
        lastError = nil
        defer { isDiscovering = false }

        let axelPath = AxelSetupService.shared.executablePath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: axelPath)
        process.arguments = ["sessions", "ls", "--json"]

        AxelSetupService.shared.configureAxelProcess(process)
        let env = AxelSetupService.shared.axelCommandEnvironment()
        print("[SessionRecovery] ENV: TMPDIR=\(env["TMPDIR"] ?? "nil"), LANG=\(env["LANG"] ?? "nil"), PATH has \(env["PATH"]?.components(separatedBy: ":").count ?? 0) entries")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Run the process off the main thread to avoid blocking the UI
        let result: (status: Int32, stdout: Data, stderr: Data) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    process.waitUntilExit()
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: (process.terminationStatus, stdoutData, stderrData))
                } catch {
                    continuation.resume(returning: (-1, Data(), Data()))
                }
            }
        }

        if result.status == 0 {
            do {
                let decoder = JSONDecoder()
                let sessions = try decoder.decode([RecoveredSession].self, from: result.stdout)
                let filtered = sessions.filter { $0.port != nil }
                self.recoveredSessions = filtered
                self.lastDiscoveryTime = Date()

                // Log discovery results
                let recoverable = filtered.filter { $0.canRecover }
                let unrecoverable = filtered.filter { !$0.canRecover }
                print("[SessionRecovery] Discovered \(filtered.count) session(s) with ports: \(recoverable.count) recoverable, \(unrecoverable.count) manual-only")
            } catch {
                self.lastError = "Failed to decode sessions: \(error.localizedDescription)"
                print("[SessionRecovery] Decode error: \(error)")
                self.recoveredSessions = []
            }
        } else if result.status == -1 {
            self.lastError = "Failed to run axel process"
            print("[SessionRecovery] Failed to launch process")
            self.recoveredSessions = []
        } else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            self.lastError = "axel command failed with status \(result.status)"
            print("[SessionRecovery] Command failed with status \(result.status): \(stderr)")
            self.recoveredSessions = []
        }
    }

    /// Filter sessions matching a specific workspace path (including worktree paths)
    func sessions(for workspacePath: String?) -> [RecoveredSession] {
        guard let path = workspacePath else {
            print("[SessionRecovery] No workspace path provided, returning all recovered sessions")
            return recoveredSessions
        }

        // Build all known paths: main workspace + any cached worktree paths
        let allMatchPaths = allNormalizedPaths(for: path)

        let matchingSessions = recoveredSessions.filter { session in
            guard let sessionPath = session.workingDir else {
                return false
            }
            let normalizedSessionPath = (sessionPath as NSString).standardizingPath
            let sessionComponents = (normalizedSessionPath as NSString).pathComponents

            // Check against main workspace path and all worktree paths
            for matchPath in allMatchPaths {
                if normalizedSessionPath == matchPath {
                    return true
                }
                // Allow sessions started in subdirectories
                let matchComponents = (matchPath as NSString).pathComponents
                if sessionComponents.starts(with: matchComponents) {
                    return true
                }
            }
            return false
        }

        // Log path matching for debugging
        if matchingSessions.count != recoveredSessions.count {
            let nonMatching = recoveredSessions.filter { session in
                guard let sessionPath = session.workingDir else { return true }
                let normalizedSessionPath = (sessionPath as NSString).standardizingPath
                let sessionComponents = (normalizedSessionPath as NSString).pathComponents
                for matchPath in allMatchPaths {
                    if normalizedSessionPath == matchPath { return false }
                    let matchComponents = (matchPath as NSString).pathComponents
                    if sessionComponents.starts(with: matchComponents) { return false }
                }
                return true
            }
            for session in nonMatching {
                print("[SessionRecovery] Session \(session.name.prefix(8))... path mismatch: \(session.workingDir ?? "nil") vs \(path)")
            }
        }

        return matchingSessions
    }

    /// Resolve and cache worktree paths for a workspace
    func resolveWorktrees(for workspacePath: String) async {
        let worktrees = await WorktreeService.shared.listWorktrees(in: workspacePath)
        worktreeCache[workspacePath] = worktrees
        if worktrees.count > 1 {
            print("[SessionRecovery] Cached \(worktrees.count) worktree path(s) for \(workspacePath)")
        }
    }

    /// All normalized paths (main workspace + worktrees) for matching
    private func allNormalizedPaths(for workspacePath: String) -> [String] {
        let normalizedMain = (workspacePath as NSString).standardizingPath
        var paths = [normalizedMain]
        if let worktrees = worktreeCache[workspacePath] {
            for wt in worktrees {
                let normalized = (wt.path as NSString).standardizingPath
                if normalized != normalizedMain {
                    paths.append(normalized)
                }
            }
        }
        return paths
    }

    /// Find the worktree branch for a session based on its working directory
    private func worktreeBranch(forSessionPath sessionPath: String, workspacePath: String) -> String? {
        guard let worktrees = worktreeCache[workspacePath] else { return nil }
        let normalizedSessionPath = (sessionPath as NSString).standardizingPath
        for wt in worktrees where !wt.isMain {
            let normalizedWtPath = (wt.path as NSString).standardizingPath
            if normalizedSessionPath == normalizedWtPath {
                return wt.branch
            }
            // Also check subdirectories of the worktree
            let wtComponents = (normalizedWtPath as NSString).pathComponents
            let sessionComponents = (normalizedSessionPath as NSString).pathComponents
            if sessionComponents.starts(with: wtComponents) {
                return wt.branch
            }
        }
        return nil
    }

    /// Check if a session is already tracked (exists in the set of tracked pane IDs)
    func isSessionTracked(_ session: RecoveredSession, trackedPaneIds: Set<String>) -> Bool {
        guard let paneId = session.axelPaneId else { return false }
        return trackedPaneIds.contains(paneId)
    }

    /// Get sessions that are not already tracked (truly "recovered")
    func untrackedSessions(for workspacePath: String?, trackedPaneIds: Set<String>) -> [RecoveredSession] {
        sessions(for: workspacePath).filter { !isSessionTracked($0, trackedPaneIds: trackedPaneIds) }
    }

    /// Get count of untracked sessions for a workspace
    func untrackedCount(for workspacePath: String?, trackedPaneIds: Set<String>) -> Int {
        untrackedSessions(for: workspacePath, trackedPaneIds: trackedPaneIds).count
    }

    /// Recover (join) untracked sessions for a workspace and register them with the session manager.
    /// Only sessions with stored port and pane_id info can be properly recovered.
    /// Resolves git worktrees to also discover sessions running in worktree directories.
    func recoverUntrackedSessions(for workspacePath: String?, workspaceId: UUID, sessionManager: TerminalSessionManager) async {
        // Resolve worktree paths so sessions in worktree directories are matched
        if let workspacePath {
            await resolveWorktrees(for: workspacePath)
        }

        let trackedPaneIds = Set(sessionManager.sessions(for: workspaceId).compactMap { $0.paneId })
        let allUntracked = untrackedSessions(for: workspacePath, trackedPaneIds: trackedPaneIds)
        let sessionsToRecover = allUntracked.filter { $0.canRecover }

        // Log discovery results for debugging
        let unrecoverable = allUntracked.filter { !$0.canRecover }
        if !unrecoverable.isEmpty {
            print("[SessionRecovery] Found \(unrecoverable.count) session(s) without recovery info (missing port/pane_id):")
            for session in unrecoverable {
                print("[SessionRecovery]   - \(session.name.prefix(8))... (can manually attach)")
            }
        }

        guard !sessionsToRecover.isEmpty else {
            if !allUntracked.isEmpty {
                print("[SessionRecovery] No auto-recoverable sessions (all missing port/pane_id)")
            }
            return
        }

        let axelPath = AxelSetupService.shared.executablePath
        print("[SessionRecovery] Auto-recovering \(sessionsToRecover.count) session(s)...")

        for session in sessionsToRecover {
            guard let port = session.port, let paneId = session.axelPaneId else { continue }

            // Determine worktree branch from session's working directory
            let branch: String?
            if let sessionDir = session.workingDir, let wsPath = workspacePath {
                branch = worktreeBranch(forSessionPath: sessionDir, workspacePath: wsPath)
            } else {
                branch = nil
            }

            print("[SessionRecovery] Recovering \(session.name.prefix(8))... on port \(port)\(branch.map { " (worktree: \($0))" } ?? "")")

            // Connect InboxService to the existing server port
            InboxService.shared.connect(paneId: paneId, port: Int(port))

            // Register provider with CostTracker for this terminal
            _ = CostTracker.shared.tracker(forPaneId: paneId, provider: .claude)

            // Create terminal session that joins the tmux session
            let command = "\(axelPath) session join \(session.name)"
            let newSession = sessionManager.startSession(
                for: nil,
                paneId: paneId,
                command: command,
                workingDirectory: workspacePath,
                workspaceId: workspaceId,
                worktreeBranch: branch,
                provider: .claude
            )
            print("[SessionRecovery] Created session \(newSession.id) for pane \(paneId)")
        }

        print("[SessionRecovery] Recovery complete. SessionManager now has \(sessionManager.sessions(for: workspaceId).count) session(s) for this workspace")
    }
}

#else

/// Minimal iOS/visionOS stubs to satisfy shared references.
struct TerminalSessionManager {}

struct RecoveredSession: Identifiable, Codable, Hashable {
    let name: String
    let axelPaneId: String?

    var id: String { name }
}

@MainActor
@Observable
final class SessionRecoveryService {
    static let shared = SessionRecoveryService()

    private(set) var recoveredSessions: [RecoveredSession] = []
    private(set) var isDiscovering: Bool = false
    private(set) var lastError: String?
    private(set) var lastDiscoveryTime: Date?

    private init() {}

    func discoverSessions() async {
        // No-op on iOS/visionOS
    }

    func untrackedSessions(for workspacePath: String?, trackedPaneIds: Set<String>) -> [RecoveredSession] {
        []
    }

    func recoverUntrackedSessions(for workspacePath: String?, workspaceId: UUID, sessionManager: TerminalSessionManager) async {
        // No-op on iOS/visionOS
    }
}

#endif
