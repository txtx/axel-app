import SwiftUI
import SwiftData

struct ContentView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = TodoViewModel()
    @State private var sidebarSelection: SidebarSection? = .inbox(.pending)
    @State private var selectedHint: Hint?
    @State private var selectedTask: WorkTask?
    @State private var selectedAgent: AgentSelection?
    @State private var selectedContext: Context?
    @State private var selectedTeamMember: OrganizationMember?
    @State private var showTerminal: Bool = false
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    #if os(macOS)
    @State private var selectedSession: TerminalSession?
    @State private var showWorkerPicker = false
    @State private var pendingTask: WorkTask?
    @State private var floatingSession: TerminalSession?
    @State private var showCloseTerminalConfirmation = false
    @State private var closeTargetSession: TerminalSession?
    @State private var closeKillTmuxSession = false
    @Environment(\.terminalSessionManager) private var sessionManager

    /// Workers that are not linked to any task (standalone terminals available for assignment)
    private var availableWorkers: [TerminalSession] {
        sessionManager.sessions.filter { $0.taskId == nil }
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
                Task { await killTmuxSession(paneId: paneId) }
            }
        }

        let isClosingSelected = selectedSession?.id == session.id
        let sessions = sessionManager.sessions
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

    private func killTmuxSession(paneId: String) async {
        _ = await AxelSetupService.shared.checkInstallation()
        let sessionName = await resolveSessionName(for: paneId)
        let axelPath = AxelSetupService.shared.executablePath

        if await runProcess(["/usr/bin/env", axelPath, "session", "kill", sessionName, "--confirm"]) == 0 {
            return
        }

        if await runProcess(["/usr/bin/env", "tmux", "kill-session", "-t", sessionName]) == 0 {
            return
        }

        _ = await runProcess(["/usr/bin/env", "tmux", "kill-pane", "-t", paneId])
    }

    private func resolveSessionName(for paneId: String) async -> String {
        await SessionRecoveryService.shared.discoverSessions()
        return SessionRecoveryService.shared.recoveredSessions.first(where: { $0.axelPaneId == paneId })?.name ?? paneId
    }

    private func runProcess(_ args: [String]) async -> Int32 {
        guard let executable = args.first else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        AxelSetupService.shared.configureAxelProcess(process)
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

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

    /// Content column ID used to force width recalculation when switching sections
    private var contentColumnId: String {
        switch sidebarSelection {
        case .inbox: return "inbox"
        case .queue: return "queue"
        case .terminals: return "terminals"
        case .recovered: return "recovered"
        case .optimizations(.overview): return "optimizations"
        case .optimizations(.skills): return "skills"
        case .optimizations(.context): return "context"
        case .team: return "team"
        case .none: return "none"
        }
    }

    /// Start a terminal session, optionally linked to a task
    /// - If task is provided, always show the picker (provider + agent selection)
    /// - If no task, create a new terminal immediately
    private func startTerminal(for task: WorkTask? = nil) {
        if let task {
            pendingTask = task
            showWorkerPicker = true
        } else {
            createNewTerminal(for: task)
        }
    }

    /// Assign a task to an existing worker session
    /// If the worker is busy, the task is queued on that terminal
    private func assignTaskToWorker(_ task: WorkTask, worker: TerminalSession) {
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
        guard let paneId = worker.paneId else { return }

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

        // Send the task prompt to the worker
        var prompt = task.title
        if let description = task.taskDescription, !description.isEmpty {
            prompt += "\n\n" + description
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
                    print("[ContentView] Failed to send prompt via outbox: \(error)")
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
        // Find the session for this pane
        guard let session = sessionManager.sessions.first(where: { $0.paneId == paneId }) else {
            return
        }

        // Pop the next task from the queue (via TaskQueueService)
        guard let nextTaskId = TaskQueueService.shared.dequeue(fromTerminal: paneId) else {
            // No more tasks in queue - clear the current task reference
            session.taskId = nil
            session.taskTitle = "Terminal"
            return
        }

        // Fetch the task from SwiftData
        let predicate = #Predicate<WorkTask> { $0.id == nextTaskId }
        let descriptor = FetchDescriptor<WorkTask>(predicate: predicate)
        guard let task = try? modelContext.fetch(descriptor).first else {
            // Task was deleted - try the next one
            consumeNextQueuedTask(forPaneId: paneId)
            return
        }

        // Run this task
        runTaskOnWorker(task, worker: session)
    }

    /// Create a new terminal session, optionally showing floating miniature
    private func createNewTerminal(for task: WorkTask? = nil, provider: AIProvider = .claude) {
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
        terminal.workspace = task?.workspace
        terminal.status = TerminalStatus.running.rawValue
        terminal.provider = provider
        modelContext.insert(terminal)

        // Build command with pane-id and port
        // Use executablePath which prefers PATH version, falls back to bundled binary
        // Format: axel session new <pane> --tmux --session-name ... --pane-id ... --port ...
        let axelPath = AxelSetupService.shared.executablePath
        var command = "\(axelPath) session new \(provider.commandName) --tmux --session-name \(paneId) --pane-id \(paneId) --port \(port)"
        if let task = task {
            var prompt = task.title
            if let description = task.taskDescription, !description.isEmpty {
                prompt += "\n\n" + description
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
            workingDirectory: task?.workspace?.path,
            workspaceId: task?.workspace?.id ?? UUID(),
            provider: provider
        )

        // Show floating miniature instead of switching sidebar
        // Only show if we're NOT already on the terminals tab
        if case .terminals = sidebarSelection {
            // Already on terminals - just select the session
            selectedSession = session
        } else {
            // Show floating miniature
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                floatingSession = session
            }
        }

        // Sync if task was provided
        if task != nil {
            performSync()
        }
    }
    #endif

    private func performSync() {
        guard authService.isAuthenticated else { return }
        guard !syncService.isSyncing else { return }

        // Check if we need to run cleanup (first launch after deletion sync was added)
        let hasRunCleanup = UserDefaults.standard.bool(forKey: "hasRunDeletionCleanup")
        if !hasRunCleanup {
            print("[ContentView] Running one-time deletion cleanup...")
            Task {
                await syncService.performCleanupSync(context: modelContext)
                UserDefaults.standard.set(true, forKey: "hasRunDeletionCleanup")
            }
        } else {
            // Use background sync (runs entirely off main thread)
            print("[ContentView] Triggering background sync...")
            syncService.performFullSyncInBackground(container: modelContext.container)
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

    // MARK: - Content Column (macOS only)

    #if os(macOS)
    @ViewBuilder
    private var contentColumnView: some View {
        switch sidebarSelection {
        case .optimizations(.overview):
            ContentUnavailableView {
                Label("Optimizations", systemImage: "gauge.with.dots.needle.50percent")
            } description: {
                Text("Add skills and context to improve agent performance")
            }
        case .optimizations(.skills):
            SkillsListView(workspace: nil, selection: $selectedAgent)
        case .optimizations(.context):
            ContextListView(selection: $selectedContext)
        case .team:
            TeamListView(selectedMember: $selectedTeamMember)
        case .queue:
            QueueListView(
                filter: currentTaskFilter,
                selection: $selectedTask,
                onNewTask: { appState.isNewTaskPresented = true }
            )
        case .inbox, .none:
            HintInboxView(
                filter: currentHintFilter,
                selection: $selectedHint
            )
        case .terminals:
            RunningListView(selection: $selectedSession, onRequestClose: requestCloseSession)
        case .recovered:
            // Recovered sessions not shown in global view (workspace-specific)
            EmptyView()
        }
    }

    // MARK: - Detail Column

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
            if let session = selectedSession {
                RunningDetailView(
                    session: session,
                    selection: $selectedSession,
                    onRequestClose: requestCloseSession
                )
            } else {
                EmptyRunningSelectionView()
            }
        case .queue:
            if let task = selectedTask {
                TaskDetailView(task: task, viewModel: viewModel, showTerminal: $showTerminal, selectedTask: $selectedTask, onStartTerminal: startTerminal)
            } else {
                EmptyTaskSelectionView()
            }
        case .team:
            if let member = selectedTeamMember {
                TeamMemberDetailView(member: member)
            } else {
                EmptyTeamSelectionView()
            }
        default:
            if let hint = selectedHint {
                HintDetailView(hint: hint)
            } else {
                EmptyHintSelectionView()
            }
        }
    }
    #endif

    // MARK: - Body

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView(
                selection: $sidebarSelection,
                onNewTask: { appState.isNewTaskPresented = true }
            )
        } content: {
            contentColumnView
                .id(contentColumnId)
        } detail: {
            detailColumnView
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 650, idealHeight: 800)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Centered workspace info (Xcode style)
                WorkspaceHeaderView(showTerminal: $showTerminal)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Sign in button (only when not authenticated)
                if !authService.isAuthenticated {
                    Button {
                        Task {
                            print("[ContentView] Sign in button pressed")
                            await authService.signInWithGitHub()
                            print("[ContentView] Sign in completed, error: \(String(describing: authService.authError))")
                        }
                    } label: {
                        if authService.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if let error = authService.authError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 16))
                                Text("Error")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .help(error.localizedDescription)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 16))
                                Text("Sign in to Sync")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Sign in with GitHub")
                }
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarTitleDisplayMode(.inlineLarge)
        .keyboardShortcut(for: .runTerminal) {
            if let task = selectedTask {
                startTerminal(for: task)
            }
        }
        .keyboardShortcut(for: .newTerminal) {
            startTerminal()
        }
        .keyboardShortcut(for: .undo) { TaskUndoManager.shared.undo() }
        .keyboardShortcut(for: .redo) { TaskUndoManager.shared.redo() }
        .sheet(isPresented: $showWorkerPicker) {
            WorkerPickerPanel(workspaceId: nil) { selectedWorker, provider, _ in
                if let task = pendingTask {
                    if let worker = selectedWorker {
                        // User selected an existing worker
                        assignTaskToWorker(task, worker: worker)
                    } else {
                        // User chose to create a new agent
                        createNewTerminal(for: task, provider: provider)
                    }
                }
                pendingTask = nil
            }
            .presentationDetents([.medium])
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
                        closeSessionAndCleanup(session, killTmux: closeKillTmuxSession)
                    }
                    closeKillTmuxSession = false
                    closeTargetSession = nil
                    showCloseTerminalConfirmation = false
                }
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if let session = floatingSession {
                FloatingTerminalMiniature(
                    session: session,
                    onDismiss: {
                        floatingSession = nil
                    },
                    onTap: {
                        // Navigate to terminals and select this session
                        sidebarSelection = .terminals
                        selectedSession = session
                        floatingSession = nil
                    }
                )
                .padding(20)
            }
        }
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
        }
        .onChange(of: selectedTask) { _, _ in
            showTerminal = false
        }
        .task {
            // Sync on launch if authenticated (non-blocking)
            performSync()
            // Start real-time sync in background
            if authService.isAuthenticated {
                let service = syncService
                let context = modelContext
                Task {
                    await service.startRealtimeSync(context: context)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                performSync()
            }
        }
        .onChange(of: authService.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                performSync()
                Task {
                    await syncService.startRealtimeSync(context: modelContext)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskCompletedOnTerminal)) { notification in
            // When a task completes on a terminal, consume the next queued task
            if let paneId = notification.userInfo?["paneId"] as? String {
                consumeNextQueuedTask(forPaneId: paneId)
            }
        }
        #else
        iOSContentView(
            appState: appState,
            viewModel: viewModel,
            sidebarSelection: $sidebarSelection,
            selectedHint: $selectedHint,
            selectedTask: $selectedTask,
            selectedAgent: $selectedAgent,
            selectedContext: $selectedContext,
            selectedTeamMember: $selectedTeamMember,
            showTerminal: $showTerminal
        )
        #endif
    }
}

// MARK: - Previews

#Preview {
    ContentView(appState: AppState())
        .modelContainer(PreviewContainer.shared.container)
}

#Preview("Create Task") {
    CreateTaskView(isPresented: .constant(true))
        .modelContainer(PreviewContainer.shared.container)
}
