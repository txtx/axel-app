import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

// MARK: - Shell Escaping

extension String {
    /// Escapes the string for safe use in shell commands using single quotes.
    /// Works across all POSIX shells (bash, zsh, fish, sh).
    /// Single quotes are escaped by ending the quote, adding escaped quote, then resuming.
    var shellEscaped: String {
        // Single-quote escaping: replace ' with '\'' (end quote, escaped quote, start quote)
        let escaped = self.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Workspace Content View

struct WorkspaceContentView: View {
    let workspace: Workspace
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = TodoViewModel()
    @State private var sidebarSelection: SidebarSection? = .queue(.backlog)
    @State private var selectedHint: Hint?
    @State private var selectedTask: WorkTask?
    @State private var selectedAgent: AgentSelection?
    @State private var selectedContext: Context?
    @State private var showTerminal: Bool = false
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @State private var selectedSession: TerminalSession?
    @State private var selectedMember: OrganizationMember?
    @State private var selectedRecoveredSession: RecoveredSession?
    @State private var showCloseTerminalConfirmation = false
    @State private var closeTargetSession: TerminalSession?
    @State private var closeKillTmuxSession = false
    @State private var showTerminalInspector = false
    @State private var replayBootAnimation = false
    @State private var agentPickerMode: AgentPickerMode?
    @State private var floatingSession: TerminalSession?
    @State private var skillsColumnWidth: CGFloat = 280
    @State private var terminalsColumnWidth: CGFloat = 280
    @State private var teamColumnWidth: CGFloat = 280
    @State private var contextColumnWidth: CGFloat = 280
    @Environment(\.terminalSessionManager) private var sessionManager
    @Environment(\.colorScheme) private var colorScheme

    /// Workers that are not linked to any task (standalone terminals available for assignment)
    /// Filtered to only show workers for this workspace
    private var availableWorkers: [TerminalSession] {
        sessionManager.sessions(for: workspace.id).filter { $0.taskId == nil }
    }

    private func requestCloseSession(_ session: TerminalSession) {
        if session.status == .dormant {
            closeSessionAndCleanup(session, killTmux: true)
            return
        }

        closeTargetSession = session
        closeKillTmuxSession = false
        showCloseTerminalConfirmation = true
    }

    @MainActor
    private func closeSessionAndCleanup(_ session: TerminalSession, killTmux: Bool) {
        if let taskId = session.taskId,
           let task = modelContext.model(for: taskId) as? WorkTask {
            task.updateStatus(.backlog)
        }

        if let paneId = session.paneId {
            let queuedTaskIds = TaskQueueService.shared.clearQueue(forTerminal: paneId)
            for taskId in queuedTaskIds {
                let taskDescriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == taskId })
                if let task = try? modelContext.fetch(taskDescriptor).first {
                    task.updateStatus(.backlog)
                }
            }

            let terminalDescriptor = FetchDescriptor<Terminal>(
                predicate: #Predicate { $0.paneId == paneId }
            )
            if let terminal = try? modelContext.fetch(terminalDescriptor).first {
                terminal.task = nil

                let hintDescriptor = FetchDescriptor<Hint>(
                    predicate: #Predicate { hint in
                        hint.status == "pending"
                    }
                )
                if let hints = try? modelContext.fetch(hintDescriptor) {
                    for hint in hints where hint.terminal?.paneId == paneId {
                        hint.cancel()
                    }
                }
            }

            InboxService.shared.clearEventsForPane(paneId)

            if killTmux {
                // Gather all main-actor values upfront so the kill runs entirely off the main thread
                let axelPath = AxelSetupService.shared.executablePath
                let env = AxelSetupService.shared.axelCommandEnvironment()
                let recoveredSessions = SessionRecoveryService.shared.recoveredSessions
                let sessionName = recoveredSessions.first(where: { $0.axelPaneId == paneId })?.name ?? paneId
                Task.detached(priority: .utility) {
                    await Self.killTmuxSessionBackground(paneId: paneId, sessionName: sessionName, axelPath: axelPath, environment: env)
                }
            }
        }

        let isClosingSelected = selectedSession?.id == session.id
        let sessions = sessionManager.sessions(for: workspace.id)
        let nextSession = isClosingSelected ? computeAdjacentSession(closing: session, in: sessions) : selectedSession

        sessionManager.stopSession(session)
        if isClosingSelected {
            selectedSession = nextSession
        }
    }

    private func computeAdjacentSession(closing session: TerminalSession, in sessions: [TerminalSession]) -> TerminalSession? {
        guard let currentIndex = sessions.firstIndex(where: { $0.id == session.id }) else {
            return nil
        }

        if currentIndex > 0 {
            return sessions[currentIndex - 1]
        } else if sessions.count > 1 {
            return sessions[currentIndex + 1]
        }
        return nil
    }

    /// Kill tmux session entirely off the main thread. All values are captured upfront.
    private nonisolated static func killTmuxSessionBackground(paneId: String, sessionName: String, axelPath: String, environment: [String: String]) async {
        if runProcessSync(["/usr/bin/env", axelPath, "session", "kill", sessionName, "--confirm"], environment: environment) == 0 {
            return
        }

        if runProcessSync(["/usr/bin/env", "tmux", "kill-session", "-t", sessionName], environment: environment) == 0 {
            return
        }

        _ = runProcessSync(["/usr/bin/env", "tmux", "kill-pane", "-t", paneId], environment: environment)
    }

    /// Run a process synchronously. Must be called off the main thread.
    private nonisolated static func runProcessSync(_ args: [String], environment: [String: String]) -> Int32 {
        guard let executable = args.first else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// Start a terminal session, optionally linked to a task
    /// - If task is provided, show worker picker to choose agent/provider/session
    /// - If no task, show new terminal sheet to choose worktree/provider
    private func startTerminal(for task: WorkTask? = nil, provider: AIProvider = .claude) {
        let hasExistingSessions = !sessionManager.sessions(for: workspace.id).isEmpty
        print("[WorkspaceContentView] startTerminal: task='\(task?.title ?? "nil")', hasExistingSessions=\(hasExistingSessions), provider=\(provider.displayName)")

        if let task {
            // Task provided - show unified picker in assign mode
            agentPickerMode = .assignTask(task)
            print("[WorkspaceContentView] → Set agentPickerMode to .assignTask")
        } else {
            // No task - show unified picker in new terminal mode
            agentPickerMode = .newTerminal
            print("[WorkspaceContentView] → Set agentPickerMode to .newTerminal")
        }
    }

    /// Assign a task to an existing worker session
    /// If the worker is busy, the task is queued on that terminal
    private func assignTaskToWorker(_ task: WorkTask, worker: TerminalSession) {
        print("[WorkspaceContentView] assignTaskToWorker: task='\(task.title)', worker.hasTask=\(worker.hasTask), worker.paneId=\(worker.paneId ?? "nil")")
        if worker.hasTask {
            // Terminal is busy - queue the task
            queueTaskOnWorker(task, worker: worker)
        } else {
            // Terminal is idle - run immediately
            runTaskOnWorker(task, worker: worker)
        }
    }

    /// Queue a task to run after the current task on this worker completes
    private func queueTaskOnWorker(_ task: WorkTask, worker: TerminalSession) {
        guard let paneId = worker.paneId else {
            print("[WorkspaceContentView] ⚠️ queueTaskOnWorker FAILED: worker.paneId is nil for task '\(task.title)'")
            return
        }

        print("[WorkspaceContentView] ✓ Queueing task '\(task.title)' on terminal \(paneId.prefix(8))...")

        // Update task status to .queued (assigned to a terminal's queue)
        task.updateStatus(.queued)

        // Add to TaskQueueService
        TaskQueueService.shared.enqueue(taskId: task.id, onTerminal: paneId)

        performSync()
    }

    /// Actually run a task on a worker (send prompt, update status)
    private func runTaskOnWorker(_ task: WorkTask, worker: TerminalSession) {
        // Update task status
        task.updateStatus(.running)

        // Update worker session with new task (tracks history)
        worker.assignTask(task)

        // Link task to terminal model
        if let paneId = worker.paneId,
           let terminal = workspace.terminals.first(where: { $0.paneId == paneId }) {
            terminal.task = task
        }

        // Send the task prompt to the worker
        var prompt = task.title
        if let description = task.taskDescription, !description.isEmpty {
            prompt += "\n\n" + description
        }
        if !task.attachments.isEmpty {
            let fileUrls = task.attachments.map { $0.fileUrl }.joined(separator: ", ")
            prompt += "\n\nAttached files: \(fileUrls)"
        }

        // Send the prompt via outbox (tmux send-keys) for reliable delivery
        if let paneId = worker.paneId {
            Task {
                do {
                    try await InboxService.shared.sendTextResponse(
                        sessionId: paneId,
                        text: prompt,
                        paneId: paneId
                    )
                } catch {
                    print("[WorkspaceContentView] Failed to send prompt via outbox: \(error)")
                    // Fallback to direct terminal send
                    worker.surfaceView?.sendCommand(prompt)
                }
            }
        } else {
            // No paneId - fallback to direct terminal send
            worker.surfaceView?.sendCommand(prompt)
        }

        // Sync the task status change
        performSync()
    }

    /// Consume the next queued task on a terminal after current task completes
    /// Called when we receive a taskCompletedOnTerminal notification
    private func consumeNextQueuedTask(forPaneId paneId: String) {
        print("[WorkspaceContentView] consumeNextQueuedTask: paneId=\(paneId)")

        // Find the session for this pane
        guard let session = sessionManager.sessions.first(where: { $0.paneId == paneId }) else {
            print("[WorkspaceContentView] consumeNextQueuedTask: no session found for paneId")
            return
        }

        // Idempotency guard: if session already has a running task that's not completed,
        // skip this call (prevents race condition between dual notifications)
        if session.taskId != nil {
            // Fetch the current task from Terminal model, which is safer than model(for:)
            // as model(for:) can crash with a stale PersistentIdentifier
            if let terminal = workspace.terminals.first(where: { $0.paneId == paneId }),
               let currentTask = terminal.task,
               currentTask.taskStatus == .running {
                // Session is already running a task - this is a duplicate notification
                print("[WorkspaceContentView] consumeNextQueuedTask: idempotency guard - task still running")
                return
            }
        }

        // Pop the next task from the queue (via TaskQueueService)
        let queueCount = TaskQueueService.shared.queueCount(forTerminal: paneId)
        print("[WorkspaceContentView] consumeNextQueuedTask: queue count before dequeue = \(queueCount)")

        guard let nextTaskId = TaskQueueService.shared.dequeue(fromTerminal: paneId) else {
            // No more tasks in queue - clear the current task reference
            print("[WorkspaceContentView] consumeNextQueuedTask: no more tasks in queue, clearing session")
            session.taskId = nil
            session.taskTitle = "Terminal"

            // Also clear from Terminal model
            if let terminal = workspace.terminals.first(where: { $0.paneId == paneId }) {
                terminal.task = nil
            }
            return
        }
        print("[WorkspaceContentView] consumeNextQueuedTask: dequeued taskId=\(nextTaskId)")

        // Find the task by ID
        let taskDescriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == nextTaskId })
        guard let task = try? modelContext.fetch(taskDescriptor).first else {
            // Task was deleted - try next one recursively
            consumeNextQueuedTask(forPaneId: paneId)
            return
        }

        // Run the task on the same session (preserves Claude's conversation context)
        runTaskOnWorker(task, worker: session)
    }

    /// Create a new terminal session, optionally showing floating miniature
    /// - Parameters:
    ///   - task: Optional task to run on the new terminal
    ///   - worktreeBranch: Optional git worktree branch to use (nil = main workspace)
    ///   - gridName: Optional grid name to launch (nil = single pane)
    private func createNewTerminal(for task: WorkTask? = nil, worktreeBranch: String? = nil, provider: AIProvider = .claude, gridName: String? = nil, isolate: Bool = false, reviewPostCompletion: Bool = false) {
        // Update task status if provided
        task?.updateStatus(.running)

        // Generate a pane ID for this terminal session
        let paneId = UUID().uuidString

        // Allocate a unique port for this terminal's server
        let port = InboxService.shared.allocatePort()

        // Create a Terminal model
        let terminal = Terminal()
        terminal.paneId = paneId
        terminal.serverPort = port
        terminal.task = task
        terminal.worktreeBranch = worktreeBranch
        terminal.workspace = workspace
        terminal.status = TerminalStatus.running.rawValue
        terminal.provider = provider
        terminal.isIsolated = isolate
        terminal.parentWorktreeBranch = isolate ? worktreeBranch : nil
        modelContext.insert(terminal)

        // Check if workspace needs initialization (no AXEL.md)
        let initPrefix = AxelSetupService.shared.getInitCommandPrefix(
            workspacePath: workspace.path,
            workspaceName: workspace.name
        )

        // Build command with pane-id and port
        // Use executablePath which prefers PATH version, falls back to bundled binary
        let axelPath = AxelSetupService.shared.executablePath
        var command: String

        if let gridName = gridName {
            // Launch a full grid layout
            // Format: axel session new --grid <name> --session-name ... --pane-id ... --port ... [--worktree ...]
            // Note: No --tmux needed (grids are always tmux)
            command = "\(initPrefix)\(axelPath) session new --grid \(gridName) --session-name \(paneId) --pane-id \(paneId) --port \(port)"
        } else {
            // Launch a single pane
            // Format: axel session new <pane> --tmux --session-name ... --pane-id ... --port ... [--worktree ...]
            command = "\(initPrefix)\(axelPath) session new \(provider.commandName) --tmux --session-name \(paneId) --pane-id \(paneId) --port \(port)"
        }

        // Add worktree flag if specified (axel-cli will create worktree if needed)
        if let branch = worktreeBranch {
            command += " --worktree \(branch.shellEscaped)"
        }

        // Add isolation flags
        if isolate {
            command += " --isolate --allow-dirty"
        }
        if reviewPostCompletion {
            command += " --review-post-completion"
        }

        // Always enable verbose logging for debugging
        command += " --verbose"

        if let task = task {
            var prompt = task.title
            if let description = task.taskDescription, !description.isEmpty {
                prompt += "\n\n" + description
            }
            if !task.attachments.isEmpty {
                let fileUrls = task.attachments.map { $0.fileUrl }.joined(separator: ", ")
                prompt += "\n\nAttached files: \(fileUrls)"
            }

            // Add versioning prompt when review-post-completion is enabled
            if reviewPostCompletion {
                prompt += "\n\nWhen you complete this task, provide a commit summary following conventional commits:\n- Type: feat, fix, refactor, docs, test, chore, etc.\n- A short summary (max 72 chars)\n- A detailed description of what changed and why\n\nFormat your summary as:\nVERSIONING: {\"versioningMessage\": \"<type>: <summary>\", \"versioningDescription\": \"<description>\"}"
            }

            command += " --prompt \(prompt.shellEscaped)"
        }

        // Connect to this terminal's SSE endpoint
        InboxService.shared.connect(paneId: paneId, port: port)

        // Register provider with CostTracker for this terminal
        _ = CostTracker.shared.tracker(forPaneId: paneId, provider: provider)

        let session = sessionManager.startSession(
            for: task,
            paneId: paneId,
            command: command,
            workingDirectory: workspace.path,
            workspaceId: workspace.id,
            worktreeBranch: worktreeBranch,
            provider: provider
        )

        // Show floating miniature or navigate to Agents menu
        if task == nil {
            // No task (CMD+T) - navigate to Agents menu and select the session
            withAnimation {
                sidebarSelection = .terminals
                selectedSession = session
            }
        } else if case .terminals = sidebarSelection {
            // Already on terminals - just select the session
            selectedSession = session
        } else {
            // Has task and not on terminals tab - show floating miniature
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                floatingSession = session
            }
        }

        // Sync if task was provided
        if task != nil {
            performSync()
        }
    }

    private func performSync() {
        guard authService.isAuthenticated else { return }
        guard !syncService.isSyncing else { return }
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            print("[WorkspaceContentView] Triggering workspace sync for: \(workspaceId)")
            await syncService.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private var currentHintFilter: HintFilter {
        if case .inbox(let filter) = sidebarSelection {
            return filter
        }
        return .pending
    }

    private var currentTaskFilter: TaskFilter {
        if case .queue(let filter) = sidebarSelection {
            return filter
        }
        return .backlog
    }

    // Data from workspace relationships
    private var workspaceHints: [Hint] {
        workspace.tasks.flatMap { $0.hints }
    }

    private var workspaceTasks: [WorkTask] {
        workspace.tasks
    }

    private var workspaceSkills: [Skill] {
        workspace.skills
    }

    private var workspaceContexts: [Context] {
        workspace.contexts
    }

    private var currentListColumnWidth: CGFloat {
        switch sidebarSelection {
        case .optimizations(.skills): return skillsColumnWidth
        case .optimizations(.context): return contextColumnWidth
        case .terminals: return terminalsColumnWidth
        case .team: return teamColumnWidth
        default: return 280
        }
    }

    private var currentListColumnWidthBinding: Binding<CGFloat> {
        switch sidebarSelection {
        case .optimizations(.skills): return $skillsColumnWidth
        case .optimizations(.context): return $contextColumnWidth
        case .terminals: return $terminalsColumnWidth
        case .team: return $teamColumnWidth
        default: return $skillsColumnWidth
        }
    }

    @ViewBuilder
    private var sectionView: some View {
        switch sidebarSelection {
        case .queue:
            WorkspaceQueueListView(
                workspace: workspace,
                filter: currentTaskFilter,
                highlightedTask: $selectedTask,
                onNewTask: { appState.isNewTaskPresented = true },
                onStartTerminal: { task in startTerminal(for: task) }
            )
        case .optimizations(.overview):
            OptimizationsOverviewView(workspace: workspace)
        case .terminals:
            VStack(spacing: 0) {
                detailColumnView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 5)
                    .zIndex(1)
                TimelinePanelView(
                    workspaceId: workspace.id,
                    selection: $selectedSession,
                    onRequestClose: requestCloseSession
                )
            }
            .background(.clear)
        case .inbox:
            InboxSceneView()
        default:
            HStack(spacing: 0) {
                listColumnView
                    .frame(width: currentListColumnWidth)

                ResizableDivider(
                    width: currentListColumnWidthBinding,
                    minWidth: 220,
                    maxWidth: 800,
                    style: sidebarSelection == .terminals && sessionManager.runningCount(for: workspace.id) > 0 ? .terminal : .standard
                )

                detailColumnView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private var listColumnView: some View {
        switch sidebarSelection {
        case .optimizations(.skills):
            SkillsListView(workspace: workspace, selection: $selectedAgent)
        case .optimizations(.context):
            WorkspaceContextListView(workspace: workspace, selection: $selectedContext)
        case .terminals:
            RunningListView(
                selection: $selectedSession,
                workspaceId: workspace.id,
                onRequestClose: requestCloseSession
            )
        case .recovered:
            RecoveredSessionsListView(
                workspacePath: workspace.path,
                selection: $selectedRecoveredSession
            )
        case .team:
            TeamListView(selectedMember: $selectedMember)
        case .none:
            EmptyView()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detailColumnView: some View {
        switch sidebarSelection {
        case .optimizations(.skills):
            if let agent = selectedAgent {
                AgentDetailView(agent: agent)
            } else {
                EmptySkillSelectionView()
            }
        case .optimizations(.context):
            if let context = selectedContext {
                ContextDetailView(context: context)
            } else {
                EmptyContextSelectionView()
            }
        case .terminals:
            AgentsSceneLayout(
                workspaceId: workspace.id,
                selection: $selectedSession,
                onRequestClose: requestCloseSession
            )
        case .recovered:
            if let session = selectedRecoveredSession {
                RecoveredSessionDetailView(
                    session: session,
                    workspaceId: workspace.id,
                    workspacePath: workspace.path
                )
            } else {
                ContentUnavailableView {
                    Label("Recovered Sessions", systemImage: "arrow.clockwise.circle")
                } description: {
                    Text("Select a session to view details")
                }
            }
        case .team:
            if let member = selectedMember {
                TeamMemberDetailView(member: member)
            } else {
                EmptyTeamSelectionView()
            }
        case .none:
            ContentUnavailableView {
                Label("Activity", systemImage: "bolt.fill")
            } description: {
                Text("Select a section from the sidebar")
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            OrbView(workspace: workspace, showTerminal: $showTerminal, replayBoot: $replayBootAnimation)
        }

//        ToolbarItemGroup(placement: .primaryAction) {
//            if !authService.isAuthenticated {
//                signInButton
//            }
//        }
    }

//    @ViewBuilder
//    private var signInButton: some View {
//        Button {
//            Task {
//                await authService.signInWithGitHub()
//            }
//        } label: {
//            signInButtonLabel
//        }
//        .buttonStyle(.borderless)
//        .help("Sign in with GitHub")
//    }
//
//    @ViewBuilder
//    private var signInButtonLabel: some View {
//        if authService.isLoading {
//            ProgressView()
//                .controlSize(.small)
//        } else if let error = authService.authError {
//            HStack(spacing: 6) {
//                Image(systemName: "exclamationmark.triangle")
//                    .font(.system(size: 16))
//                Text("Error")
//                    .font(.system(size: 12))
//            }
//            .foregroundStyle(.red)
//            .padding(.horizontal, 16)
//            .help(error.localizedDescription)
//        } else {
//            HStack(spacing: 6) {
//                Image(systemName: "person.circle")
//                    .font(.system(size: 16))
//                Text("Sign in to Sync")
//                    .font(.system(size: 12))
//            }
//            .foregroundStyle(.secondary)
//            .padding(.horizontal, 16)
//        }
//    }

    // MARK: - Floating Terminal Overlay

    @ViewBuilder
    private var floatingTerminalOverlay: some View {
        if let session = floatingSession {
            FloatingTerminalMiniature(
                session: session,
                onDismiss: { floatingSession = nil },
                onTap: {
                    sidebarSelection = .terminals
                    selectedSession = session
                    floatingSession = nil
                }
            )
            .padding(20)
        }
    }

    // MARK: - Body

    var body: some View {
        mainContent
            .modifier(WorkspaceKeyboardShortcuts(
                selectedTask: selectedTask,
                sidebarSelection: $sidebarSelection,
                selectedSession: $selectedSession,
                showTerminalInspector: $showTerminalInspector,
                onStartTerminal: { startTerminal() },
                onStartTerminalForTask: { if let task = selectedTask { startTerminal(for: task) } },
                onRequestClose: requestCloseSession
            ))
            .modifier(WorkspaceAlertModifier(
                showCloseTerminalConfirmation: $showCloseTerminalConfirmation,
                closeTargetSession: $closeTargetSession,
                closeKillTmuxSession: $closeKillTmuxSession,
                showTerminalInspector: $showTerminalInspector,
                selectedSession: $selectedSession,
                onCloseSession: closeSessionAndCleanup
            ))
            .modifier(WorkspaceSheetModifier(
                workspace: workspace,
                appState: appState,
                agentPickerMode: $agentPickerMode,
                selectedTask: $selectedTask,
                selectedSession: $selectedSession,
                showTerminal: $showTerminal,
                onStartTerminal: { task in startTerminal(for: task) },
                onAssignTask: assignTaskToWorker,
                onCreateNewTerminal: { task, provider, gridName in createNewTerminal(for: task, provider: provider, gridName: gridName, isolate: true, reviewPostCompletion: true) },
                onCreateWorktreeTerminal: { task, branch, provider, gridName in createNewTerminal(for: task, worktreeBranch: branch, provider: provider, gridName: gridName, isolate: true, reviewPostCompletion: true) }
            ))
            .overlay(alignment: .bottomTrailing) { floatingTerminalOverlay }
            .background(
                Button("") {
                    replayBootAnimation.toggle()
                }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            )
            .modifier(WorkspaceLifecycleModifier(
                workspace: workspace,
                selectedTask: $selectedTask,
                showTerminal: $showTerminal,
                authService: authService,
                syncService: syncService,
                sessionManager: sessionManager,
                modelContext: modelContext,
                scenePhase: scenePhase,
                performSync: performSync
            ))
            .modifier(WorkspaceFocusedValuesModifier(
                selectedTask: selectedTask,
                appState: appState,
                onStartTerminal: { if let task = selectedTask, task.taskStatus.isPending { startTerminal(for: task) } }
            ))
            .modifier(WorkspaceNotificationModifier(
                sidebarSelection: $sidebarSelection,
                workspace: workspace,
                sessionManager: sessionManager,
                modelContext: modelContext,
                onConsumeNextTask: consumeNextQueuedTask,
                onCreateTerminal: { task, worktree, provider in
                    createNewTerminal(for: task, worktreeBranch: worktree, provider: provider, isolate: true, reviewPostCompletion: true)
                }
            ))
    }

    private var mainContent: some View {
        NavigationSplitView {
            WorkspaceSidebarView(
                workspace: workspace,
                selection: $sidebarSelection
            )
        } detail: {
            sectionView
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 650, idealHeight: 800)
        .toolbar { toolbarContent }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarTitleDisplayMode(.inlineLarge)
        .navigationTitle(workspace.name)
        .background(WindowBackgroundSetter(
            color: colorScheme == .dark
                ? NSColor(red: 0x29/255.0, green: 0x2F/255.0, blue: 0x30/255.0, alpha: 1.0)
                : .windowBackgroundColor
        ))
    }
}

// MARK: - Window Background Setter

/// Sets the NSWindow's backgroundColor to ensure consistent sidebar material tinting.
/// The NavigationSplitView sidebar uses a visual effect material that is tinted by the
/// window's background color. Without this, different detail content produces different sidebar tints.
private struct WindowBackgroundSetter: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSView {
        let view = NSView()
        view.setFrameSize(.zero)
        DispatchQueue.main.async {
            view.window?.backgroundColor = color
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<Self>) {
        nsView.window?.backgroundColor = color
    }
}

// MARK: - Workspace View Modifiers

private struct WorkspaceKeyboardShortcuts: ViewModifier {
    let selectedTask: WorkTask?
    @Binding var sidebarSelection: SidebarSection?
    @Binding var selectedSession: TerminalSession?
    @Binding var showTerminalInspector: Bool
    let onStartTerminal: () -> Void
    let onStartTerminalForTask: () -> Void
    let onRequestClose: (TerminalSession) -> Void

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(for: .runTerminal) { onStartTerminalForTask() }
            .keyboardShortcut(for: .newTerminal) { onStartTerminal() }
            .keyboardShortcut(for: .closePane) {
                // Cmd+W only works on terminals screen
                guard case .terminals = sidebarSelection, let session = selectedSession else { return }
                onRequestClose(session)
            }
            .keyboardShortcut(for: .inspectTerminal) {
                // Cmd+I only works on terminals screen with a selected session
                guard case .terminals = sidebarSelection, selectedSession != nil else { return }
                showTerminalInspector = true
            }
            .keyboardShortcut(for: .showTasks) { sidebarSelection = .queue(.backlog) }
            .keyboardShortcut(for: .showAgents) { sidebarSelection = .terminals }
            .keyboardShortcut(for: .showInbox) { sidebarSelection = .inbox(.pending) }
            .keyboardShortcut(for: .showSkills) { sidebarSelection = .optimizations(.skills) }
            .keyboardShortcut(for: .undo) { TaskUndoManager.shared.undo() }
            .keyboardShortcut(for: .redo) { TaskUndoManager.shared.redo() }
    }
}

private struct WorkspaceAlertModifier: ViewModifier {
    @Binding var showCloseTerminalConfirmation: Bool
    @Binding var closeTargetSession: TerminalSession?
    @Binding var closeKillTmuxSession: Bool
    @Binding var showTerminalInspector: Bool
    @Binding var selectedSession: TerminalSession?
    let onCloseSession: (TerminalSession, Bool) -> Void

    private var sessionForClose: TerminalSession? {
        closeTargetSession ?? selectedSession
    }

    private var pendingPermissionRequests: Int {
        guard let paneId = sessionForClose?.paneId else { return 0 }
        return InboxService.shared.unresolvedPermissionRequestCount(forPaneId: paneId)
    }

    private var queuedTaskCount: Int {
        guard let paneId = sessionForClose?.paneId else { return 0 }
        return TaskQueueService.shared.tasksQueued(onTerminal: paneId).count
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showTerminalInspector) {
                if let session = selectedSession {
                    TerminalInspectorView(session: session)
                }
            }
            .sheet(isPresented: $showCloseTerminalConfirmation) {
                TerminalCloseConfirmationSheet(
                    killTmuxSession: $closeKillTmuxSession,
                    pendingPermissionRequests: pendingPermissionRequests,
                    queuedTaskCount: queuedTaskCount,
                    onCancel: {
                        closeKillTmuxSession = false
                        closeTargetSession = nil
                        showCloseTerminalConfirmation = false
                    },
                    onConfirm: {
                        if let session = sessionForClose {
                            onCloseSession(session, closeKillTmuxSession)
                        }
                        closeKillTmuxSession = false
                        closeTargetSession = nil
                        showCloseTerminalConfirmation = false
                    }
                )
            }
    }
}

private struct WorkspaceSheetModifier: ViewModifier {
    let workspace: Workspace
    @Bindable var appState: AppState
    @Binding var agentPickerMode: AgentPickerMode?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedSession: TerminalSession?
    @Binding var showTerminal: Bool
    let onStartTerminal: (WorkTask) -> Void
    let onAssignTask: (WorkTask, TerminalSession) -> Void
    let onCreateNewTerminal: (WorkTask?, AIProvider, String?) -> Void
    let onCreateWorktreeTerminal: (WorkTask?, String, AIProvider, String?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.isNewTaskPresented) {
                WorkspaceCreateTaskView(
                    workspace: workspace,
                    isPresented: $appState.isNewTaskPresented,
                    onRun: { task in onStartTerminal(task) },
                    onSelect: { task in selectedTask = task }
                )
            }
            .sheet(item: $agentPickerMode) { mode in
                AgentPickerPanel(
                    workspaceId: workspace.id,
                    workspacePath: workspace.path,
                    task: mode.task,
                    onCreateTerminal: { branchName, provider, gridName in
                        if let branchName {
                            onCreateWorktreeTerminal(mode.task, branchName, provider, gridName)
                        } else {
                            onCreateNewTerminal(mode.task, provider, gridName)
                        }
                    },
                    onAssignToSession: mode.task != nil ? { task, session in
                        onAssignTask(task, session)
                    } : nil,
                    onGoToSession: { session in
                        selectedSession = session
                        showTerminal = true
                    }
                )
            }
    }
}


private struct WorkspaceLifecycleModifier: ViewModifier {
    let workspace: Workspace
    @Binding var selectedTask: WorkTask?
    @Binding var showTerminal: Bool
    let authService: AuthService
    let syncService: SyncService
    let sessionManager: TerminalSessionManager
    let modelContext: ModelContext
    let scenePhase: ScenePhase
    let performSync: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedTask) { _, _ in
                showTerminal = false
            }
            .task {
                InboxService.shared.connect()
                let workspaceId = workspace.syncId ?? workspace.id
                syncService.registerActiveWorkspace(workspaceId)
                performSync()
                if authService.isAuthenticated {
                    await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
                }
            }
            .task {
                // Discover and recover existing tmux sessions for this workspace
                // Run independently of sync to avoid blocking on slow/failed connections
                await SessionRecoveryService.shared.discoverSessions()
                await SessionRecoveryService.shared.recoverUntrackedSessions(
                    for: workspace.path,
                    workspaceId: workspace.id,
                    sessionManager: sessionManager
                )
            }
            .onDisappear {
                let workspaceId = workspace.syncId ?? workspace.id
                syncService.unregisterActiveWorkspace(workspaceId)
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { performSync() }
            }
            .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
                if isAuthenticated {
                    performSync()
                    Task {
                        let workspaceId = workspace.syncId ?? workspace.id
                        await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
                    }
                }
            }
    }
}

private struct WorkspaceFocusedValuesModifier: ViewModifier {
    let selectedTask: WorkTask?
    @Bindable var appState: AppState
    let onStartTerminal: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.newTaskAction) { appState.isNewTaskPresented = true }
            .focusedSceneValue(\.runTaskAction, selectedTask != nil ? {
                NotificationCenter.default.post(name: .runTaskTriggered, object: nil)
                onStartTerminal()
            } : nil)
            .focusedSceneValue(\.deleteTasksAction, selectedTask != nil ? {
                NotificationCenter.default.post(name: .deleteTasksTriggered, object: nil)
            } : nil)
            .focusedSceneValue(\.completeTaskAction, selectedTask != nil ? {
                NotificationCenter.default.post(name: .completeTaskTriggered, object: nil)
            } : nil)
            .focusedSceneValue(\.cancelTaskAction, selectedTask != nil ? {
                NotificationCenter.default.post(name: .cancelTaskTriggered, object: nil)
            } : nil)
    }
}

private struct WorkspaceNotificationModifier: ViewModifier {
    @Binding var sidebarSelection: SidebarSection?
    let workspace: Workspace
    let sessionManager: TerminalSessionManager
    let modelContext: ModelContext
    let onConsumeNextTask: (String) -> Void
    let onCreateTerminal: (WorkTask?, String?, AIProvider) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showTasks)) { _ in
                sidebarSelection = .queue(.backlog)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgents)) { _ in
                sidebarSelection = .terminals
            }
            .onReceive(NotificationCenter.default.publisher(for: .showInbox)) { _ in
                sidebarSelection = .inbox(.pending)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSkills)) { _ in
                sidebarSelection = .optimizations(.skills)
            }
            .onReceive(NotificationCenter.default.publisher(for: .scriptingStartAgent)) { notification in
                // Handle AppleScript agent start requests
                guard let userInfo = notification.userInfo,
                      let targetWorkspaceId = userInfo["workspaceId"] as? UUID,
                      targetWorkspaceId == workspace.id else { return }

                let worktree = userInfo["worktree"] as? String
                let provider = userInfo["provider"] as? AIProvider ?? .claude
                let taskId = userInfo["taskId"] as? UUID

                // Find task if taskId provided
                var task: WorkTask? = nil
                if let taskId = taskId {
                    let descriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == taskId })
                    task = try? modelContext.fetch(descriptor).first
                }

                onCreateTerminal(task, worktree, provider)
            }
            .onReceive(NotificationCenter.default.publisher(for: .taskCompletedOnTerminal)) { notification in
                // When a task completes on a terminal (via inbox confirmation), consume the next queued task
                if let paneId = notification.userInfo?["paneId"] as? String {
                    onConsumeNextTask(paneId)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .taskNoLongerRunning)) { notification in
                // When a task's status changes from running (via Tasks scene), find terminal and cleanup
                guard let taskId = notification.userInfo?["taskId"] as? UUID else {
                    print("[WorkspaceNotificationModifier] .taskNoLongerRunning: no taskId in notification")
                    return
                }

                print("[WorkspaceNotificationModifier] .taskNoLongerRunning: taskId=\(taskId), workspace=\(workspace.name)")

                // First fetch the task from current context to get its persistent ID
                let taskDescriptor = FetchDescriptor<WorkTask>(predicate: #Predicate { $0.id == taskId })
                guard let task = try? modelContext.fetch(taskDescriptor).first else {
                    print("[WorkspaceNotificationModifier] .taskNoLongerRunning: task not found in context")
                    return
                }

                // Query for terminal with this task using predicate (safer than relationship traversal)
                let workspaceId = workspace.id
                let terminalDescriptor = FetchDescriptor<Terminal>(predicate: #Predicate<Terminal> { terminal in
                    terminal.workspace?.id == workspaceId && terminal.task?.id == taskId
                })

                if let terminal = try? modelContext.fetch(terminalDescriptor).first,
                   let paneId = terminal.paneId {
                    print("[WorkspaceNotificationModifier] .taskNoLongerRunning: found via Terminal query, paneId=\(paneId)")
                    onConsumeNextTask(paneId)
                    return
                }

                // Fallback: Try to find paneId via TerminalSession
                let persistentId = task.persistentModelID
                if let session = sessionManager.sessions(for: workspace.id).first(where: { $0.taskId == persistentId }),
                   let paneId = session.paneId {
                    print("[WorkspaceNotificationModifier] .taskNoLongerRunning: found via TerminalSession fallback, paneId=\(paneId)")
                    onConsumeNextTask(paneId)
                    return
                }

                print("[WorkspaceNotificationModifier] .taskNoLongerRunning: no terminal/session found for task \(taskId)")
            }
    }
}

// MARK: - Workspace Toolbar Header

struct OrbView: View {
    /// Only play boot animation once per app session
    private static var hasPlayedBootAnimation = false

    let workspace: Workspace
    @Binding var showTerminal: Bool
    @Binding var replayBoot: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var costTracker = CostTracker.shared
    @State private var shouldPlayBoot = false

    /// AI providers to display — always show Claude and Codex, plus any other active ones
    private var displayProviders: [AIProvider] {
        var providers = Set(costTracker.activeProviders.filter { $0 != .shell && $0 != .custom })
        providers.insert(.claude)
        providers.insert(.codex)
        return AIProvider.allCases.filter { providers.contains($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(displayProviders.enumerated()), id: \.element) { index, provider in
                SpeedometerGauge(
                    provider: provider,
                    costTracker: costTracker,
                    colorScheme: colorScheme,
                    bootDelay: Double(index) * 0.15,
                    playBootAnimation: shouldPlayBoot
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? Color(white: 0.08) : Color(hex: "F7F7F7")!)
        )
        .fixedSize()
        .onAppear {
            if !Self.hasPlayedBootAnimation {
                Self.hasPlayedBootAnimation = true
                shouldPlayBoot = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    shouldPlayBoot = false
                }
            }
        }
        .onChange(of: replayBoot) {
            guard replayBoot else { return }
            shouldPlayBoot = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                shouldPlayBoot = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                shouldPlayBoot = false
                replayBoot = false
            }
        }
    }
}

// MARK: - Workspace Sidebar View

struct WorkspaceSidebarView: View {
    let workspace: Workspace
    @Binding var selection: SidebarSection?
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @State private var inboxService = InboxService.shared
    @State private var recoveryService = SessionRecoveryService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.terminalSessionManager) private var sessionManager

    private var queuedTasksCount: Int {
        workspace.tasks.filter { $0.taskStatus.isPending }.count
    }

    private var runningTasksCount: Int {
        workspace.tasks.filter { $0.taskStatus == .running }.count
    }

    private var runningCount: Int {
        sessionManager.runningCount(for: workspace.id)
    }

    /// Number of agents blocked (have pending permission request) for this workspace
    private var blockedCount: Int {
        let blockedPanes = inboxService.blockedPaneIds
        return sessionManager.sessions(for: workspace.id).filter { session in
            guard let paneId = session.paneId else { return false }
            return blockedPanes.contains(paneId)
        }.count
    }

    /// Number of agents not blocked
    private var notBlockedCount: Int {
        runningCount - blockedCount
    }

    /// Set of pane IDs currently being tracked by TerminalSessionManager
    private var trackedPaneIds: Set<String> {
        Set(sessionManager.sessions(for: workspace.id).compactMap { $0.paneId })
    }

    /// Number of recovered (untracked) sessions for this workspace
    private var recoveredCount: Int {
        recoveryService.untrackedCount(for: workspace.path, trackedPaneIds: trackedPaneIds)
    }

    /// Number of pending inbox events (permission requests)
    private var pendingInboxCount: Int {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return ["PermissionRequest", "Stop"].contains(hookName) && !inboxService.isResolved(event.id)
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Spacer()
                    .frame(height: 4)
                    .listRowSeparator(.hidden)

                // Tasks
                Label {
                    HStack {
                        Text("Tasks")
                        Spacer()
                        if queuedTasksCount > 0 {
                            Text("\(queuedTasksCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.accentPurple)
                }
                .tag(SidebarSection.queue(.backlog))

                // Agents
                Label {
                    HStack {
                        Text("Agents")
                        Spacer()
                        if runningCount > 0 {
                            HStack(spacing: 0) {
                                Text("\(notBlockedCount)")
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.leading, 8)
                                    .padding(.trailing, blockedCount > 0 ? 6 : 8)
                                    .padding(.vertical, 2)
                                if blockedCount > 0 {
                                    Text("|")
                                        .font(.callout)
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .padding(.vertical, 2)
                                    Text("\(blockedCount)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.red)
                                        .padding(.leading, 6)
                                        .padding(.trailing, 8)
                                        .padding(.vertical, 2)
                                }
                            }
                            .background(
                                Capsule()
                                    .fill(
                                        blockedCount > 0
                                            ? LinearGradient(
                                                colors: [Color.white.opacity(0.15), Color.red.opacity(0.15)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                            : LinearGradient(
                                                colors: [Color.white.opacity(0.15)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                    )
                            )
                        }
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.orange)
                }
                .tag(SidebarSection.terminals)

                // Recovered Sessions (only show if there are any)
                if recoveredCount > 0 {
                    Label {
                        HStack {
                            Text("Recovered")
                            Spacer()
                            Text("\(recoveredCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    } icon: {
                        Image(systemName: "arrow.clockwise.circle")
                            .foregroundStyle(.yellow)
                    }
                    .padding(.leading, 16)
                    .tag(SidebarSection.recovered)
                }

                // Inbox
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        if pendingInboxCount > 0 {
                            Text("\(pendingInboxCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(Color(red: 249.0/255, green: 25.0/255, blue: 85.0/255)) // #F91955
                }
                .tag(SidebarSection.inbox(.pending))

                Divider()
                    .padding(.vertical, 8)

                // Optimizations (coming soon)
                Label {
                    HStack {
                        Text("Optimizations")
                        Spacer()
                        Text("Soon")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)

                // Skills (indented under Optimizations)
                Label {
                    Text("Skills")
                } icon: {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
                .padding(.leading, 16)
                .allowsHitTesting(false)

                // Context (indented under Optimizations)
                Label {
                    Text("Context")
                } icon: {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
                .padding(.leading, 16)
                .allowsHitTesting(false)

                Divider()
                    .padding(.vertical, 8)

                // Team (coming soon)
                Label {
                    HStack {
                        Text("Team")
                        Spacer()
                        Text("Soon")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "person.2")
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            }
            .listStyle(.sidebar)

            // Bottom section with user info
            Divider()

            if let user = authService.currentUser {
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: user.userMetadata["avatar_url"]?.stringValue ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 0) {
                        Text(user.userMetadata["user_name"]?.stringValue ?? "Signed In")
                            .font(.callout)
                            .lineLimit(1)
                        if syncService.isSyncing {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Syncing...")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Synced")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer()

//                    Button {
//                        Task {
//                            let workspaceId = workspace.syncId ?? workspace.id
//                            await syncService.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
//                        }
//                    } label: {
//                        Image(systemName: "arrow.triangle.2.circlepath")
//                            .font(.callout)
//                            .foregroundStyle(syncService.isSyncing ? .secondary : .primary)
//                    }
//                    .buttonStyle(.plain)
//                    .disabled(syncService.isSyncing)

                    Menu {
                        Button(role: .destructive) {
                            Task {
                                await authService.signOut(clearingLocalData: modelContext)
                            }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }
}

// MARK: - Workspace Context List View

struct WorkspaceContextListView: View {
    let workspace: Workspace
    @Binding var selection: Context?

    private var contexts: [Context] {
        workspace.contexts.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Context")
                    .font(.title2.bold())
                Spacer()
                Text("\(contexts.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if contexts.isEmpty {
                emptyView
            } else {
                List(selection: $selection) {
                    ForEach(contexts) { context in
                        ContextRow(context: context)
                            .tag(context)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "briefcase")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("No Context")
                .font(.headline)

            Text("Context provides background information for AI assistants")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Workspace Create Task View

struct WorkspaceCreateTaskView: View {
    @Bindable var workspace: Workspace
    @Binding var isPresented: Bool
    var onRun: ((WorkTask) -> Void)?
    var onSelect: ((WorkTask) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 2)

                TextField("New Task", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit {
                        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            createTask()
                        }
                    }

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(20)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    createTask()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("\u{23CE}")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    createAndRunTask()
                } label: {
                    HStack(spacing: 6) {
                        Text("Run")
                        Text("\u{2318}\u{23CE}")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 480, height: 180)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            isFocused = true
        }
    }

    private func createTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Close sheet immediately for responsive UI
        isPresented = false

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority = workspace.tasks
            .filter { $0.taskStatus == .queued }
            .map { $0.priority }
            .max() ?? 0

        let task = WorkTask(title: trimmedTitle)
        task.priority = maxPriority + 50  // New tasks go to bottom of queue with room for reordering
        modelContext.insert(task)

        // Explicitly add to relationship and save to trigger SwiftUI observation
        workspace.tasks.append(task)
        try? modelContext.save()

        // Select the newly created task
        onSelect?(task)

        // Sync to push the new task to Supabase (detached to avoid main actor contention)
        let workspaceId = workspace.syncId ?? workspace.id
        Task.detached {
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: self.modelContext)
        }
    }

    private func createAndRunTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Close sheet immediately for responsive UI
        isPresented = false

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority = workspace.tasks
            .filter { $0.taskStatus == .queued }
            .map { $0.priority }
            .max() ?? 0

        let task = WorkTask(title: trimmedTitle)
        task.priority = maxPriority + 50
        modelContext.insert(task)

        // Explicitly add to relationship and save to trigger SwiftUI observation
        workspace.tasks.append(task)
        try? modelContext.save()

        // Select the newly created task
        onSelect?(task)

        // Start the terminal for this task immediately
        onRun?(task)

        // Sync to push the new task to Supabase (detached to avoid main actor contention)
        let workspaceId = workspace.syncId ?? workspace.id
        Task.detached {
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: self.modelContext)
        }
    }
}

// MARK: - Row Views

struct HintRow: View {
    let hint: Hint

    private var typeIcon: String {
        switch hint.hintType {
        case .exclusiveChoice: "circle.circle"
        case .multipleChoice: "checklist"
        case .textInput: "text.cursor"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: typeIcon)
                .font(.title3)
                .foregroundStyle(hint.hintStatus == .pending ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(hint.title)
                    .font(.body)
                    .lineLimit(2)

                Text(hint.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.body)

                Text(skill.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct ContextRow: View {
    let context: Context

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "briefcase.fill")
                .font(.title3)
                .foregroundStyle(.accentPurple)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.name)
                    .font(.body)

                Text(context.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Cursor At End TextField (Single Line)

struct CursorAtEndTextField: NSViewRepresentable {
    typealias NSViewType = NSTextField

    @Binding var text: String
    var shouldFocus: Bool
    var font: NSFont
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?

    func makeNSView(context: NSViewRepresentableContext<CursorAtEndTextField>) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = font
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: NSViewRepresentableContext<CursorAtEndTextField>) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.parent = self
        if shouldFocus && nsView.window?.firstResponder != nsView.currentEditor() {
            nsView.window?.makeFirstResponder(nsView)
            if let editor = nsView.currentEditor() {
                editor.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CursorAtEndTextField

        init(_ parent: CursorAtEndTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil)
                parent.onEscape?()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab?()
                return true
            }
            return false
        }
    }
}

// MARK: - Multiline Title Field

class TitleTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?
    private var lastLineCount: Int = 1

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        onEscape?()
    }

    override func insertTab(_ sender: Any?) {
        onTab?()
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let usedRect = manager.usedRect(for: container)
        let inset = textContainerInset
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: usedRect.height + inset.height * 2
        )
    }

    override func didChangeText() {
        super.didChangeText()
        // Only invalidate intrinsic content size if line count changed (due to word wrapping or Enter)
        let newLineCount = countRenderedLines()
        if newLineCount != lastLineCount {
            lastLineCount = newLineCount
            invalidateIntrinsicContentSize()
        }
    }

    /// Count the actual number of rendered lines (includes word-wrapped lines)
    private func countRenderedLines() -> Int {
        guard let manager = layoutManager, let container = textContainer else {
            return 1
        }
        manager.ensureLayout(for: container)

        var lineCount = 0
        var index = 0
        let glyphCount = manager.numberOfGlyphs

        while index < glyphCount {
            var lineRange = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &lineRange)
            lineCount += 1
            index = NSMaxRange(lineRange)
        }

        // Empty text or single line minimum
        return max(1, lineCount)
    }
}

struct MultilineTitleField: NSViewRepresentable {
    typealias NSViewType = TitleTextView

    @Binding var text: String
    var font: NSFont
    var shouldFocus: Bool
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?

    func makeNSView(context: NSViewRepresentableContext<MultilineTitleField>) -> TitleTextView {
        let textView = TitleTextView()
        textView.onEscape = onEscape
        textView.onTab = onTab
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.focusRingType = .none
        textView.string = text

        return textView
    }

    func updateNSView(_ textView: TitleTextView, context: NSViewRepresentableContext<MultilineTitleField>) {
        textView.onEscape = onEscape
        textView.onTab = onTab

        if textView.string != text {
            textView.string = text
            textView.invalidateIntrinsicContentSize()
        }

        // Update container width to match view width for proper word wrapping
        if let container = textView.textContainer, textView.bounds.width > 0 {
            container.containerSize = NSSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }

        if shouldFocus && textView.window?.firstResponder != textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineTitleField

        init(_ parent: MultilineTitleField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Update binding immediately - the TitleTextView handles intrinsic size invalidation
            // only when line count changes, so this won't cause constant row height updates
            parent.text = textView.string
        }
    }
}

// MARK: - Growing Text View

private class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""
    var placeholderFont: NSFont = .systemFont(ofSize: 14)
    var onEscape: (() -> Void)?
    var onShiftTab: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        onEscape?()
    }

    override func insertBacktab(_ sender: Any?) {
        onShiftTab?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: placeholderFont,
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6)
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let rect = NSRect(
                x: inset.width + padding,
                y: inset.height,
                width: bounds.width - inset.width * 2 - padding * 2,
                height: bounds.height - inset.height * 2
            )
            placeholderString.draw(in: rect, withAttributes: attrs)
        }
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        manager.ensureLayout(for: container)
        let usedRect = manager.usedRect(for: container)
        let inset = textContainerInset
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: usedRect.height + inset.height * 2
        )
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }
}

struct GrowingTextView: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var shouldFocus: Bool
    var onEscape: (() -> Void)?
    var onShiftTab: (() -> Void)?

    func makeNSView(context: NSViewRepresentableContext<GrowingTextView>) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = PlaceholderTextView()
        textView.placeholderString = placeholder
        textView.placeholderFont = font
        textView.onEscape = onEscape
        textView.onShiftTab = onShiftTab
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .secondaryLabelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.focusRingType = .none
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: NSViewRepresentableContext<GrowingTextView>) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }

        textView.onEscape = onEscape
        textView.onShiftTab = onShiftTab

        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }

        if shouldFocus && textView.window?.firstResponder != textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    enum Style {
        case standard
        case terminal  // Dark style for terminal/agents view
    }

    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    var style: Style = .standard

    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private var dividerWidth: CGFloat {
        style == .terminal ? 1 : 1
    }

    private var dividerColor: Color {
        switch style {
        case .terminal:
            return colorScheme == .dark ? Color(hex: "292F30")! : Color.white
        case .standard:
            return Color.primary.opacity(isDragging ? 0.2 : 0.08)
        }
    }

    var body: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(width: dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragStartWidth = width
                        }
                        let newWidth = dragStartWidth + value.translation.width
                        width = min(maxWidth, max(minWidth, newWidth))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - Optimizations Overview View

struct OptimizationsOverviewView: View {
    let workspace: Workspace

    var body: some View {
        EmptyStateView(
            image: "gauge.with.dots.needle.50percent",
            title: "Optimize your agents",
            description: "Add skills and context to improve agent performance"
        )
    }
}
#endif
