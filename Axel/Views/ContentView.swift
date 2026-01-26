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
    @Environment(\.terminalSessionManager) private var sessionManager

    /// Workers that are not linked to any task (standalone terminals available for assignment)
    private var availableWorkers: [TerminalSession] {
        sessionManager.sessions.filter { $0.taskId == nil }
    }

    /// Content column ID used to force width recalculation when switching sections
    private var contentColumnId: String {
        switch sidebarSelection {
        case .inbox: return "inbox"
        case .queue: return "queue"
        case .terminals: return "terminals"
        case .skills: return "skills"
        case .context: return "context"
        case .team: return "team"
        case .none: return "none"
        }
    }

    /// Start a terminal session, optionally linked to a task
    /// - If multiple inactive workers exist, shows a picker panel
    /// - If one worker exists, reuses it
    /// - If no workers exist, creates a new one and shows floating miniature
    private func startTerminal(for task: WorkTask? = nil) {
        let available = availableWorkers

        if task != nil && available.count > 1 {
            // Multiple workers available - show picker
            pendingTask = task
            showWorkerPicker = true
        } else if task != nil && available.count == 1 {
            // Single worker available - reuse it
            assignTaskToWorker(task!, worker: available[0])
        } else {
            // No workers or no task - create new terminal
            createNewTerminal(for: task)
        }
    }

    /// Assign a task to an existing worker session
    private func assignTaskToWorker(_ task: WorkTask, worker: TerminalSession) {
        // Update task status
        task.updateStatus(.running)

        // Send the task prompt to the worker
        var prompt = task.title
        if let description = task.taskDescription, !description.isEmpty {
            prompt += "\n\n" + description
        }

        // Send the prompt command to the existing terminal
        worker.surfaceView?.sendCommand("axel claude --prompt \(prompt.shellEscaped)")

        // Sync the task status change
        performSync()
    }

    /// Create a new terminal session, optionally showing floating miniature
    private func createNewTerminal(for task: WorkTask? = nil) {
        // Update task status if provided
        task?.updateStatus(.running)

        // Generate a pane ID for this terminal session
        let paneId = UUID().uuidString

        // Create a Terminal model
        let terminal = Terminal()
        terminal.paneId = paneId
        terminal.task = task
        terminal.workspace = task?.workspace
        terminal.status = TerminalStatus.running.rawValue
        modelContext.insert(terminal)

        // Build command with optional prompt
        var command = "axel claude --pane-id=\(paneId)"
        if let task = task {
            var prompt = task.title
            if let description = task.taskDescription, !description.isEmpty {
                prompt += "\n\n" + description
            }
            command += " --prompt \(prompt.shellEscaped)"
        }

        let session = sessionManager.startSession(
            for: task,
            paneId: paneId,
            command: command,
            workingDirectory: task?.workspace?.path,
            workspaceId: task?.workspace?.id ?? UUID()
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
        return .queued
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            SidebarView(
                selection: $sidebarSelection,
                onNewTask: { appState.isNewTaskPresented = true }
            )
        } content: {
            Group {
                switch sidebarSelection {
                case .skills:
                    SkillsListView(workspace: nil, selection: $selectedAgent)
                case .context:
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
                    RunningListView(selection: $selectedSession)
                }
            }
            .id(contentColumnId)  // Force content column to adopt each view's preferred width
        } detail: {
            switch sidebarSelection {
            case .skills:
                if let agent = selectedAgent {
                    AgentDetailView(agent: agent)
                } else {
                    EmptySkillSelectionView()
                }
            case .context:
                if let context = selectedContext {
                    ContextDetailView(context: context)
                } else {
                    EmptyContextSelectionView()
                }
            case .terminals:
                if let session = selectedSession {
                    RunningDetailView(session: session, selection: $selectedSession)
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
        .sheet(isPresented: $showWorkerPicker) {
            WorkerPickerPanel(workers: availableWorkers) { selectedWorker in
                if let task = pendingTask {
                    if let worker = selectedWorker {
                        // User selected an existing worker
                        assignTaskToWorker(task, worker: worker)
                    } else {
                        // User chose to create a new agent
                        createNewTerminal(for: task)
                    }
                }
                pendingTask = nil
            }
            .presentationDetents([.medium])
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
