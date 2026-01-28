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
    @State private var sidebarSelection: SidebarSection? = .queue(.queued)
    @State private var selectedHint: Hint?
    @State private var selectedTask: WorkTask?
    @State private var selectedAgent: AgentSelection?
    @State private var selectedContext: Context?
    @State private var showTerminal: Bool = false
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @State private var selectedSession: TerminalSession?
    @State private var selectedInboxEvent: InboxEvent?
    @State private var selectedMember: OrganizationMember?
    @State private var showCloseTerminalConfirmation = false
    @State private var showWorkerPicker = false
    @State private var pendingTask: WorkTask?
    @State private var floatingSession: TerminalSession?
    @State private var skillsColumnWidth: CGFloat = 280
    @State private var inboxColumnWidth: CGFloat = 280
    @State private var terminalsColumnWidth: CGFloat = 280
    @State private var teamColumnWidth: CGFloat = 280
    @State private var contextColumnWidth: CGFloat = 280
    @Environment(\.terminalSessionManager) private var sessionManager

    /// Workers that are not linked to any task (standalone terminals available for assignment)
    /// Filtered to only show workers for this workspace
    private var availableWorkers: [TerminalSession] {
        sessionManager.sessions(for: workspace.id).filter { $0.taskId == nil }
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

        // Allocate a unique port for this terminal's server
        let port = InboxService.shared.allocatePort()

        // Create a Terminal model
        let terminal = Terminal()
        terminal.paneId = paneId
        terminal.serverPort = port
        terminal.task = task
        terminal.workspace = workspace
        terminal.status = TerminalStatus.running.rawValue
        modelContext.insert(terminal)

        // Build command with pane-id and port
        var command = "axel claude --tmux --session-name \(paneId) --pane-id=\(paneId) --port=\(port)"
        if let task = task {
            var prompt = task.title
            if let description = task.taskDescription, !description.isEmpty {
                prompt += "\n\n" + description
            }
            command += " --prompt \(prompt.shellEscaped)"
        }

        // Connect to this terminal's SSE endpoint
        InboxService.shared.connect(paneId: paneId, port: port)

        let session = sessionManager.startSession(
            for: task,
            paneId: paneId,
            command: command,
            workingDirectory: workspace.path,
            workspaceId: workspace.id
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
        return .queued
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
        case .inbox, .none: return inboxColumnWidth
        default: return 280
        }
    }

    private var currentListColumnWidthBinding: Binding<CGFloat> {
        switch sidebarSelection {
        case .optimizations(.skills): return $skillsColumnWidth
        case .optimizations(.context): return $contextColumnWidth
        case .terminals: return $terminalsColumnWidth
        case .team: return $teamColumnWidth
        case .inbox, .none: return $inboxColumnWidth
        default: return $inboxColumnWidth
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
                onStartTerminal: startTerminal
            )
        case .optimizations(.overview):
            OptimizationsOverviewView(workspace: workspace)
        default:
            HStack(spacing: 0) {
                listColumnView
                    .frame(width: currentListColumnWidth)

                ResizableDivider(width: currentListColumnWidthBinding, minWidth: 220, maxWidth: 800)

                detailColumnView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transaction { transaction in
                transaction.animation = nil
            }
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
            RunningListView(selection: $selectedSession, workspaceId: workspace.id)
        case .team:
            TeamListView(selectedMember: $selectedMember)
        case .inbox, .none:
            InboxView(selection: $selectedInboxEvent)
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
            if let session = selectedSession {
                RunningDetailView(session: session, selection: $selectedSession)
            } else {
                EmptyRunningSelectionView()
            }
        case .team:
            if let member = selectedMember {
                TeamMemberDetailView(member: member)
            } else {
                EmptyTeamSelectionView()
            }
        case .inbox, .none:
            if let event = selectedInboxEvent {
                InboxEventDetailView(event: event, selection: $selectedInboxEvent)
            } else {
                ContentUnavailableView {
                    Label("Activity", systemImage: "bolt.fill")
                } description: {
                    Text("Select an event to see details")
                }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Toolbar Content

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            WorkspaceToolbarHeader(workspace: workspace, showTerminal: $showTerminal)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !authService.isAuthenticated {
                signInButton
            }
        }
    }

    @ViewBuilder
    private var signInButton: some View {
        Button {
            Task {
                await authService.signInWithGitHub()
            }
        } label: {
            signInButtonLabel
        }
        .buttonStyle(.borderless)
        .help("Sign in with GitHub")
    }

    @ViewBuilder
    private var signInButtonLabel: some View {
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
                showCloseTerminalConfirmation: $showCloseTerminalConfirmation,
                sessionManager: sessionManager,
                onCloseTerminal: { selectedSession = nil },
                onStartTerminal: { startTerminal() },
                onStartTerminalForTask: { if let task = selectedTask { startTerminal(for: task) } }
            ))
            .modifier(WorkspaceAlertModifier(
                showCloseTerminalConfirmation: $showCloseTerminalConfirmation,
                selectedSession: selectedSession,
                sessionManager: sessionManager,
                onCloseSession: { selectedSession = nil }
            ))
            .modifier(WorkspaceSheetModifier(
                workspace: workspace,
                appState: appState,
                showWorkerPicker: $showWorkerPicker,
                availableWorkers: availableWorkers,
                pendingTask: $pendingTask,
                onStartTerminal: startTerminal,
                onAssignTask: assignTaskToWorker,
                onCreateNewTerminal: createNewTerminal
            ))
            .overlay(alignment: .bottomTrailing) { floatingTerminalOverlay }
            .modifier(WorkspaceLifecycleModifier(
                workspace: workspace,
                selectedTask: $selectedTask,
                showTerminal: $showTerminal,
                authService: authService,
                syncService: syncService,
                modelContext: modelContext,
                scenePhase: scenePhase,
                performSync: performSync
            ))
            .modifier(WorkspaceFocusedValuesModifier(
                selectedTask: selectedTask,
                appState: appState,
                onStartTerminal: { if let task = selectedTask, task.taskStatus == .queued { startTerminal(for: task) } }
            ))
            .modifier(WorkspaceNotificationModifier(sidebarSelection: $sidebarSelection))
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
    }
}

// MARK: - Workspace View Modifiers

private struct WorkspaceKeyboardShortcuts: ViewModifier {
    let selectedTask: WorkTask?
    @Binding var sidebarSelection: SidebarSection?
    @Binding var selectedSession: TerminalSession?
    @Binding var showCloseTerminalConfirmation: Bool
    let sessionManager: TerminalSessionManager
    let onCloseTerminal: () -> Void
    let onStartTerminal: () -> Void
    let onStartTerminalForTask: () -> Void

    func body(content: Content) -> some View {
        content
            .keyboardShortcut(for: .runTerminal) { onStartTerminalForTask() }
            .keyboardShortcut(for: .newTerminal) { onStartTerminal() }
            .keyboardShortcut(for: .closePane) {
                // Cmd+W only works on terminals screen
                guard case .terminals = sidebarSelection, let session = selectedSession else { return }

                // If terminal has an associated task, ask for confirmation
                if session.taskId != nil {
                    showCloseTerminalConfirmation = true
                } else {
                    // No task associated, stop the terminal directly
                    sessionManager.stopSession(session)
                    onCloseTerminal()
                }
            }
            .keyboardShortcut(for: .showTasks) { sidebarSelection = .queue(.queued) }
            .keyboardShortcut(for: .showAgents) { sidebarSelection = .terminals }
            .keyboardShortcut(for: .showInbox) { sidebarSelection = .inbox(.pending) }
            .keyboardShortcut(for: .showSkills) { sidebarSelection = .optimizations(.skills) }
    }
}

private struct WorkspaceAlertModifier: ViewModifier {
    @Binding var showCloseTerminalConfirmation: Bool
    let selectedSession: TerminalSession?
    let sessionManager: TerminalSessionManager
    let onCloseSession: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var keepTmuxSession: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showCloseTerminalConfirmation) {
                CloseTerminalConfirmationSheet(
                    keepTmuxSession: $keepTmuxSession,
                    onCancel: {
                        showCloseTerminalConfirmation = false
                    },
                    onConfirm: {
                        if let session = selectedSession {
                            // Reset the associated task to queued status
                            if let taskId = session.taskId,
                               let task = modelContext.model(for: taskId) as? WorkTask {
                                task.updateStatus(.queued)
                            }

                            if keepTmuxSession {
                                // Just remove from UI without killing tmux
                                sessionManager.stopSession(session)
                            } else {
                                // Kill the tmux session as well
                                if let paneId = session.paneId {
                                    Task {
                                        // Kill the tmux pane
                                        let process = Process()
                                        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                                        process.arguments = ["tmux", "kill-pane", "-t", paneId]
                                        try? process.run()
                                        process.waitUntilExit()
                                    }
                                }
                                sessionManager.stopSession(session)
                            }
                            onCloseSession()
                        }
                        showCloseTerminalConfirmation = false
                    }
                )
            }
    }
}

private struct CloseTerminalConfirmationSheet: View {
    @Binding var keepTmuxSession: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)

                Text("Stop Terminal?")
                    .font(.headline)

                Text("This will stop the terminal and put the associated task back in the queue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Checkbox option
            Toggle(isOn: $keepTmuxSession) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep tmux session running")
                        .font(.body)
                    Text("The terminal process will continue in the background")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)

                Button("Stop & Re-queue") {
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 340)
        .background(.background)
    }
}

private struct WorkspaceSheetModifier: ViewModifier {
    let workspace: Workspace
    @Bindable var appState: AppState
    @Binding var showWorkerPicker: Bool
    let availableWorkers: [TerminalSession]
    @Binding var pendingTask: WorkTask?
    let onStartTerminal: (WorkTask) -> Void
    let onAssignTask: (WorkTask, TerminalSession) -> Void
    let onCreateNewTerminal: (WorkTask) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $appState.isNewTaskPresented) {
                WorkspaceCreateTaskView(workspace: workspace, isPresented: $appState.isNewTaskPresented) { task in
                    onStartTerminal(task)
                }
            }
            .sheet(isPresented: $showWorkerPicker) {
                WorkerPickerPanel(workers: availableWorkers) { selectedWorker in
                    if let task = pendingTask {
                        if let worker = selectedWorker {
                            onAssignTask(task, worker)
                        } else {
                            onCreateNewTerminal(task)
                        }
                    }
                    pendingTask = nil
                }
                .presentationDetents([.medium])
            }
    }
}

private struct WorkspaceLifecycleModifier: ViewModifier {
    let workspace: Workspace
    @Binding var selectedTask: WorkTask?
    @Binding var showTerminal: Bool
    let authService: AuthService
    let syncService: SyncService
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

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showTasks)) { _ in
                sidebarSelection = .queue(.queued)
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
    }
}

// MARK: - Workspace Toolbar Header

struct WorkspaceToolbarHeader: View {
    let workspace: Workspace
    @Binding var showTerminal: Bool
    @Environment(\.terminalSessionManager) private var sessionManager
    @State private var costTracker = CostTracker.shared

    private var terminalsCount: Int {
        sessionManager.runningCount(for: workspace.id)
    }

    private var queueCount: Int {
        workspace.tasks.filter { $0.taskStatus == .queued }.count
    }

    private var histogramValues: [Double] {
        costTracker.globalHistogramValues
    }

    private var totalTokens: Int {
        costTracker.globalTotalTokens
    }

    private var totalCost: Double {
        costTracker.globalTotalCostUSD
    }

    private var formattedTokenCount: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM", Double(totalTokens) / 1_000_000)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fK", Double(totalTokens) / 1_000)
        }
        return "\(totalTokens)"
    }

    var body: some View {
        HStack(spacing: 12) {
            // Orange histogram from CostTracker
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 1)
                        .fill(Color.orange)
                        .frame(width: 7, height: 2 + CGFloat(value) * 5)
                }
            }

            // Claude icon (glowing) + token count
            HStack(spacing: 6) {
                ClaudeIcon()
                    .frame(width: 14, height: 10)
                Text(formattedTokenCount)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(hex: "DCDCDC")!)
            }

            // Show cost if available
            if totalCost > 0 {
                Text(String(format: "$%.2f", totalCost))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color(hex: "DCDCDC")!.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(white: 0.08)) // Darker background
        )
    }
}

// MARK: - Claude Icon

struct ClaudeIcon: View {
    @State private var animationAmount: CGFloat = 0.5

    var body: some View {
        ClaudeShape()
            .fill(Color(hex: "DCDCDC")!.opacity(0.5 + animationAmount * 0.5))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    animationAmount = 1.0
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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.terminalSessionManager) private var sessionManager

    private var queuedTasksCount: Int {
        workspace.tasks.filter { $0.taskStatus == .queued }.count
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
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.blue)
                }
                .tag(SidebarSection.queue(.queued))

                // Agents
                Label {
                    HStack {
                        Text("Agents")
                        Spacer()
                        if runningCount > 0 {
                            HStack(spacing: 6) {
                                if notBlockedCount > 0 {
                                    Text("\(notBlockedCount)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.orange)
                                }
                                if blockedCount > 0 {
                                    Text("\(blockedCount)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.orange)
                }
                .tag(SidebarSection.terminals)

                // Inbox
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        Circle()
                            .fill(InboxService.shared.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                    }
                } icon: {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(Color(red: 249.0/255, green: 25.0/255, blue: 85.0/255)) // #F91955
                }
                .tag(SidebarSection.inbox(.pending))

                // Resolved
                Label {
                    HStack {
                        Text("Resolved")
                        Spacer()
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarSection.inbox(.answered))
                .padding(.leading, 16)

                Divider()
                    .padding(.vertical, 8)

                // Optimizations
                Label {
                    Text("Optimizations")
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(.purple)
                }
                .tag(SidebarSection.optimizations(.overview))

                // Skills (indented under Optimizations)
                Label {
                    Text("Skills")
                } icon: {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.white)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.optimizations(.skills))

                // Context (indented under Optimizations)
                Label {
                    Text("Context")
                } icon: {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(.white)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.optimizations(.context))

                Divider()
                    .padding(.vertical, 8)

                // Team
                Label("Team", systemImage: "person.2")
                    .tag(SidebarSection.team)
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

                    Button {
                        Task {
                            let workspaceId = workspace.syncId ?? workspace.id
                            await syncService.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.callout)
                            .foregroundStyle(syncService.isSyncing ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(syncService.isSyncing)

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

// MARK: - Workspace Queue List View

struct WorkspaceQueueListView: View {
    @Bindable var workspace: Workspace
    @Environment(\.modelContext) private var modelContext
    let filter: TaskFilter
    @Binding var highlightedTask: WorkTask?
    var onNewTask: () -> Void
    var onStartTerminal: ((WorkTask) -> Void)?
    var onDeleteTasks: (([WorkTask]) -> Void)?
    @State private var expandedTask: WorkTask?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapTaskId: UUID?
    @State private var viewModel = TodoViewModel()
    @State private var showTerminal = false
    @State private var draggingTask: WorkTask?
    @State private var dropTargetTaskId: UUID?
    @State private var selectedTaskIds: Set<UUID> = []
    @State private var lastSelectedTaskId: UUID?
    @State private var showDeleteConfirmation = false
    @FocusState private var isListFocused: Bool

    // Running tasks (sorted by priority)
    private var runningTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus == .running }
            .sorted { $0.priority < $1.priority }
    }

    // Queued tasks (sorted by priority - lower = top of queue)
    private var queuedTasks: [WorkTask] {
        workspace.tasks
            .filter { $0.taskStatus == .queued }
            .sorted { $0.priority < $1.priority }
    }

    private var allFilteredTasks: [WorkTask] {
        let tasks = workspace.tasks.sorted { $0.priority < $1.priority }
        switch filter {
        case .queued: return tasks.filter { $0.taskStatus == .queued || $0.taskStatus == .running }
        case .running: return tasks.filter { $0.taskStatus == .running }
        case .completed: return tasks.filter { $0.taskStatus == .completed }
        case .all: return tasks
        }
    }

    /// All visible tasks in display order (running first, then queued)
    private var visibleTasksInOrder: [WorkTask] {
        if filter == .queued {
            return runningTasks + queuedTasks
        }
        return allFilteredTasks
    }

    /// Selected tasks based on selectedTaskIds
    private var selectedTasks: [WorkTask] {
        visibleTasksInOrder.filter { selectedTaskIds.contains($0.id) }
    }

    /// Check if a task is selected
    private func isTaskSelected(_ task: WorkTask) -> Bool {
        selectedTaskIds.contains(task.id)
    }

    /// Select a single task (clears other selections)
    private func selectTask(_ task: WorkTask) {
        selectedTaskIds = [task.id]
        lastSelectedTaskId = task.id
        highlightedTask = task
    }

    /// Toggle selection of a task (Cmd+click behavior)
    private func toggleTaskSelection(_ task: WorkTask) {
        if selectedTaskIds.contains(task.id) {
            selectedTaskIds.remove(task.id)
            if selectedTaskIds.isEmpty {
                highlightedTask = nil
                lastSelectedTaskId = nil
            } else if highlightedTask?.id == task.id {
                highlightedTask = visibleTasksInOrder.first { selectedTaskIds.contains($0.id) }
            }
        } else {
            selectedTaskIds.insert(task.id)
            lastSelectedTaskId = task.id
            highlightedTask = task
        }
    }

    /// Extend selection to a task (Shift+click behavior)
    private func extendSelectionTo(_ task: WorkTask) {
        guard let lastId = lastSelectedTaskId,
              let lastIndex = visibleTasksInOrder.firstIndex(where: { $0.id == lastId }),
              let targetIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) else {
            selectTask(task)
            return
        }

        let range = lastIndex < targetIndex ? lastIndex...targetIndex : targetIndex...lastIndex
        for i in range {
            selectedTaskIds.insert(visibleTasksInOrder[i].id)
        }
        highlightedTask = task
    }

    /// Select all tasks in current filter
    private func selectAllTasks() {
        selectedTaskIds = Set(visibleTasksInOrder.map(\.id))
        if let first = visibleTasksInOrder.first {
            highlightedTask = first
        }
    }

    /// Sync selection state - ensures highlightedTask and selectedTaskIds are in sync
    private func syncSelectionState() {
        // First, check if selectedTaskIds has a valid selection
        if let selectedTask = visibleTasksInOrder.first(where: { selectedTaskIds.contains($0.id) }) {
            // Update highlightedTask to match the visual selection
            highlightedTask = selectedTask
        } else if let task = highlightedTask, visibleTasksInOrder.contains(where: { $0.id == task.id }) {
            // selectedTaskIds is empty but highlightedTask has a valid value (e.g., after view recreation)
            // Initialize selectedTaskIds from highlightedTask
            selectedTaskIds = [task.id]
            lastSelectedTaskId = task.id
        } else {
            // No valid selection anywhere - clear everything
            highlightedTask = nil
            selectedTaskIds.removeAll()
        }
    }

    /// Toggle expansion of the currently selected task
    private func toggleSelectedTaskExpansion() {
        // Use selectedTaskIds as the source of truth to find the task to expand
        guard let task = visibleTasksInOrder.first(where: { selectedTaskIds.contains($0.id) }) else {
            return
        }

        // Also sync highlightedTask to ensure consistency
        highlightedTask = task

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedTask?.id == task.id {
                expandedTask = nil
            } else {
                expandedTask = task
            }
        }
    }

    /// Move selection up
    private func moveSelectionUp(extendSelection: Bool = false) {
        guard !visibleTasksInOrder.isEmpty else { return }

        // When extending selection, use highlightedTask (cursor position)
        // Otherwise, use first selected task
        let currentIndex: Int?
        if extendSelection, let highlighted = highlightedTask {
            currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == highlighted.id })
        } else {
            currentIndex = visibleTasksInOrder.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex > 0 {
            let newTask = visibleTasksInOrder[currentIndex - 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTask = newTask
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil {
            // No selection in current list - select last task
            if let last = visibleTasksInOrder.last {
                selectedTaskIds = [last.id]
                highlightedTask = last
                lastSelectedTaskId = last.id
            }
        }
        // If at top (currentIndex == 0), do nothing (don't wrap around)
    }

    /// Move selection down
    private func moveSelectionDown(extendSelection: Bool = false) {
        guard !visibleTasksInOrder.isEmpty else { return }

        // When extending selection, use highlightedTask (cursor position)
        // Otherwise, use first selected task
        let currentIndex: Int?
        if extendSelection, let highlighted = highlightedTask {
            currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == highlighted.id })
        } else {
            currentIndex = visibleTasksInOrder.firstIndex(where: { selectedTaskIds.contains($0.id) })
        }

        if let currentIndex, currentIndex < visibleTasksInOrder.count - 1 {
            let newTask = visibleTasksInOrder[currentIndex + 1]
            if extendSelection {
                selectedTaskIds.insert(newTask.id)
            } else {
                selectedTaskIds = [newTask.id]
            }
            highlightedTask = newTask
            lastSelectedTaskId = newTask.id
        } else if currentIndex == nil {
            // No selection in current list - select first task
            if let first = visibleTasksInOrder.first {
                selectedTaskIds = [first.id]
                highlightedTask = first
                lastSelectedTaskId = first.id
            }
        }
        // If at bottom, do nothing (don't wrap around)
    }

    /// Delete selected tasks
    private func deleteSelectedTasks() {
        let tasksToDelete = selectedTasks
        guard !tasksToDelete.isEmpty else { return }

        // Clear selection first
        selectedTaskIds.removeAll()
        highlightedTask = nil
        expandedTask = nil

        // Explicitly remove from relationship and delete to trigger SwiftUI observation
        for task in tasksToDelete {
            workspace.tasks.removeAll { $0.id == task.id }
            modelContext.delete(task)
        }
        try? modelContext.save()

        // Sync changes (detached to avoid main actor contention)
        let workspaceId = workspace.syncId ?? workspace.id
        Task.detached {
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: self.modelContext)
        }
    }

    /// Mark selected task(s) as completed and select next task
    private func markSelectedComplete() {
        guard let task = highlightedTask else { return }
        let newStatus: TaskStatus = task.taskStatus == .completed ? .queued : .completed

        // Find next task before changing status (which may remove it from visible list)
        if let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) {
            let nextTask = currentIndex < visibleTasksInOrder.count - 1
                ? visibleTasksInOrder[currentIndex + 1]
                : (currentIndex > 0 ? visibleTasksInOrder[currentIndex - 1] : nil)

            task.updateStatus(newStatus)

            // Select next task if the current one will disappear from this view
            if let next = nextTask, newStatus == .completed && filter != .completed && filter != .all {
                selectTask(next)
            }
        } else {
            task.updateStatus(newStatus)
        }
    }

    /// Mark selected task(s) as cancelled/aborted and select next task
    private func markSelectedCancelled() {
        guard let task = highlightedTask else { return }

        // Find next task before changing status
        if let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }) {
            let nextTask = currentIndex < visibleTasksInOrder.count - 1
                ? visibleTasksInOrder[currentIndex + 1]
                : (currentIndex > 0 ? visibleTasksInOrder[currentIndex - 1] : nil)

            task.updateStatus(.aborted)

            // Select next task if the current one will disappear from this view
            if let next = nextTask, filter != .all {
                selectTask(next)
            }
        } else {
            task.updateStatus(.aborted)
        }
    }

    /// Move selected task up in priority (lower priority number = higher in list)
    private func moveSelectedPriorityUp() {
        guard let task = highlightedTask else { return }
        guard let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }),
              currentIndex > 0 else { return }

        let taskAbove = visibleTasksInOrder[currentIndex - 1]
        let tempPriority = task.priority
        task.priority = taskAbove.priority
        taskAbove.priority = tempPriority

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    /// Move selected task down in priority (higher priority number = lower in list)
    private func moveSelectedPriorityDown() {
        guard let task = highlightedTask else { return }
        guard let currentIndex = visibleTasksInOrder.firstIndex(where: { $0.id == task.id }),
              currentIndex < visibleTasksInOrder.count - 1 else { return }

        let taskBelow = visibleTasksInOrder[currentIndex + 1]
        let tempPriority = task.priority
        task.priority = taskBelow.priority
        taskBelow.priority = tempPriority

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private var headerTitle: String {
        switch filter {
        case .queued: "Tasks"
        case .running: "Agents"
        case .completed: "Completed"
        case .all: "All Tasks"
        }
    }

    private func handleTap(on task: WorkTask, modifiers: EventModifiers = []) {
        let now = Date()
        let isDoubleTap = lastTapTaskId == task.id && now.timeIntervalSince(lastTapTime) < 0.3

        if isDoubleTap {
            // Double-click: toggle expansion
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if expandedTask?.id == task.id {
                    expandedTask = nil
                } else {
                    expandedTask = task
                }
            }
            lastTapTime = .distantPast
            lastTapTaskId = nil
        } else if modifiers.contains(.shift) {
            // Shift+click: extend selection
            extendSelectionTo(task)
            lastTapTime = now
            lastTapTaskId = task.id
        } else if modifiers.contains(.command) {
            // Cmd+click: toggle selection
            toggleTaskSelection(task)
            lastTapTime = now
            lastTapTaskId = task.id
        } else {
            // Single click: select
            selectTask(task)
            lastTapTime = now
            lastTapTaskId = task.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            taskListView
        }
        .background(backgroundView)
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onAppear {
            // Focus the list and sync selection state on appear
            DispatchQueue.main.async {
                isListFocused = true
                syncSelectionState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTasks)) { _ in
            // Restore focus and sync selection when switching back to tasks via Cmd+1
            DispatchQueue.main.async {
                isListFocused = true
                syncSelectionState()
            }
        }
        .modifier(TaskListKeyboardModifier(
            expandedTask: $expandedTask,
            selectedTaskIds: $selectedTaskIds,
            highlightedTask: $highlightedTask,
            showDeleteConfirmation: $showDeleteConfirmation,
            onMoveUp: { extendSelection in moveSelectionUp(extendSelection: extendSelection) },
            onMoveDown: { extendSelection in moveSelectionDown(extendSelection: extendSelection) },
            onSelectAll: selectAllTasks,
            onToggleExpand: toggleSelectedTaskExpansion,
            onMarkComplete: markSelectedComplete,
            onMarkCancelled: markSelectedCancelled,
            onMovePriorityUp: moveSelectedPriorityUp,
            onMovePriorityDown: moveSelectedPriorityDown
        ))
        .alert("Delete Tasks?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteSelectedTasks()
            }
        } message: {
            Text("Are you sure you want to delete \(selectedTaskIds.count) \(selectedTaskIds.count == 1 ? "task" : "tasks")? This action cannot be undone.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .runTaskTriggered)) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                expandedTask = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteTasksTriggered)) { _ in
            if !selectedTaskIds.isEmpty {
                showDeleteConfirmation = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .completeTaskTriggered)) { _ in
            markSelectedComplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelTaskTriggered)) { _ in
            markSelectedCancelled()
        }
        .onChange(of: highlightedTask) { _, newValue in
            if let task = newValue, !selectedTaskIds.contains(task.id) {
                selectedTaskIds = [task.id]
                lastSelectedTaskId = task.id
            }
        }
        .onChange(of: selectedTaskIds) { _, newValue in
            // Ensure highlightedTask stays in sync with selectedTaskIds
            // But don't reset it if it's already part of the selection (preserves cursor for multi-select)
            if let highlighted = highlightedTask, newValue.contains(highlighted.id) {
                // highlightedTask is valid and in selection - leave it alone
                return
            }

            // highlightedTask is not in selection - sync it to first selected task
            if let firstSelected = visibleTasksInOrder.first(where: { newValue.contains($0.id) }) {
                highlightedTask = firstSelected
            } else if newValue.isEmpty {
                highlightedTask = nil
            }
        }
        .onChange(of: expandedTask) { oldValue, newValue in
            // Restore focus to list when task collapses
            if oldValue != nil && newValue == nil {
                // Need async to let the view hierarchy update before restoring focus
                DispatchQueue.main.async {
                    isListFocused = true
                }
            }
        }
    }

    private var headerView: some View {
        HStack(alignment: .center) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 16))
                .foregroundStyle(.blue)

            Text(headerTitle)
                .font(.system(size: 20, weight: .bold))

            Text("\(allFilteredTasks.count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            Spacer()

            Button(action: onNewTask) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: 1000)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var taskListView: some View {
        if allFilteredTasks.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    taskListContent
                }
                .frame(maxWidth: 1000)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity)
            }
            .animation(.easeInOut(duration: 0.2), value: allFilteredTasks.map(\.id))
            .onTapGesture {
                clearSelection()
            }
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        if filter == .queued {
            runningTasksSection
            queuedTasksSection
        } else {
            filteredTasksSection
        }
    }

    @ViewBuilder
    private var runningTasksSection: some View {
        if !runningTasks.isEmpty {
            sectionHeader("Running")
            ForEach(runningTasks, id: \.id) { task in
                makeTaskRow(task: task, position: nil, isDraggable: false)
            }
        }
    }

    @ViewBuilder
    private var queuedTasksSection: some View {
        if !queuedTasks.isEmpty && !runningTasks.isEmpty {
            sectionHeader("Up Next")
        }
        ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { index, task in
            makeDraggableTaskRow(task: task, position: index + 1)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingTask = nil
            return false
        }
    }

    @ViewBuilder
    private var filteredTasksSection: some View {
        ForEach(allFilteredTasks, id: \.id) { task in
            makeTaskRow(task: task, position: nil, isDraggable: false)
        }
    }

    private func makeTaskRow(task: WorkTask, position: Int?, isDraggable: Bool) -> some View {
        TaskRow(
            task: task,
            position: position,
            isHighlighted: isTaskSelected(task),
            isExpanded: expandedTask?.id == task.id,
            isDragTarget: false,
            onTap: { modifiers in handleTap(on: task, modifiers: modifiers) },
            onRun: task.taskStatus == .queued ? { onStartTerminal?(task) } : nil,
            onToggleComplete: { toggleComplete(task) },
            onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onStatusChange: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onDelete: {
                selectTask(task)
                showDeleteConfirmation = true
            }
        )
    }

    private func makeDraggableTaskRow(task: WorkTask, position: Int) -> some View {
        TaskRow(
            task: task,
            position: position,
            isHighlighted: isTaskSelected(task),
            isExpanded: expandedTask?.id == task.id,
            isDragTarget: dropTargetTaskId == task.id,
            onTap: { modifiers in handleTap(on: task, modifiers: modifiers) },
            onRun: { onStartTerminal?(task) },
            onToggleComplete: { toggleComplete(task) },
            onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onStatusChange: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
            onDelete: {
                selectTask(task)
                showDeleteConfirmation = true
            }
        )
        .opacity(draggingTask?.id == task.id ? 0.5 : 1.0)
        .draggable(task.id.uuidString) {
            dragPreview(for: task)
        }
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items: items, targetTask: task)
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetTaskId = isTargeted ? task.id : nil
            }
        }
    }

    private func dragPreview(for task: WorkTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(task.title)
                .font(.system(size: 14))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.25))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .onAppear { draggingTask = task }
    }

    private func handleDrop(items: [String], targetTask: WorkTask) -> Bool {
        guard let droppedIdString = items.first,
              let droppedId = UUID(uuidString: droppedIdString),
              let droppedTask = queuedTasks.first(where: { $0.id == droppedId }),
              droppedTask.id != targetTask.id else {
            return false
        }
        reorderTask(droppedTask, before: targetTask)
        return true
    }

    private var backgroundView: some View {
        Color(white: 27.0 / 255.0)
            .onTapGesture {
                clearSelection()
            }
    }

    private func clearSelection() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            expandedTask = nil
        }
        selectedTaskIds.removeAll()
        highlightedTask = nil
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func toggleComplete(_ task: WorkTask) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if task.taskStatus == .completed {
                task.updateStatus(.queued)
            } else {
                task.updateStatus(.completed)
            }
        }
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private func reorderTask(_ movedTask: WorkTask, before targetTask: WorkTask) {
        // Clear drag state
        draggingTask = nil
        dropTargetTaskId = nil

        // Get current queued tasks in order
        var tasks = queuedTasks

        // Find indices
        guard let fromIndex = tasks.firstIndex(where: { $0.id == movedTask.id }),
              let toIndex = tasks.firstIndex(where: { $0.id == targetTask.id }) else {
            return
        }

        // Don't do anything if same position
        if fromIndex == toIndex { return }

        // Remove from current position and insert at new position
        tasks.remove(at: fromIndex)
        let insertIndex = fromIndex < toIndex ? toIndex - 1 : toIndex
        tasks.insert(movedTask, at: insertIndex)

        // Reassign priorities based on new order
        // Use increments of 10 to leave room for future insertions
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            for (index, task) in tasks.enumerated() {
                let newPriority = (index + 1) * 10
                if task.priority != newPriority {
                    task.updatePriority(newPriority)
                }
            }
        }

        // Sync changes
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No tasks yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Press + to create a task")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Task List Keyboard Modifier

struct TaskListKeyboardModifier: ViewModifier {
    @Binding var expandedTask: WorkTask?
    @Binding var selectedTaskIds: Set<UUID>
    @Binding var highlightedTask: WorkTask?
    @Binding var showDeleteConfirmation: Bool
    var onMoveUp: (_ extendSelection: Bool) -> Void
    var onMoveDown: (_ extendSelection: Bool) -> Void
    var onSelectAll: () -> Void
    var onToggleExpand: () -> Void
    var onMarkComplete: () -> Void
    var onMarkCancelled: () -> Void
    var onMovePriorityUp: () -> Void
    var onMovePriorityDown: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.escape) {
                if expandedTask != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTask = nil
                    }
                    return .handled
                }
                if !selectedTaskIds.isEmpty {
                    selectedTaskIds.removeAll()
                    highlightedTask = nil
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                // Don't capture arrow keys when a task is expanded (let text fields handle them)
                guard expandedTask == nil else { return .ignored }

                if keyPress.modifiers.contains(.command) {
                    // Cmd+Up: move task priority up
                    onMovePriorityUp()
                    return .handled
                }
                onMoveUp(keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { keyPress in
                // Don't capture arrow keys when a task is expanded (let text fields handle them)
                guard expandedTask == nil else { return .ignored }

                if keyPress.modifiers.contains(.command) {
                    // Cmd+Down: move task priority down
                    onMovePriorityDown()
                    return .handled
                }
                onMoveDown(keyPress.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.return) {
                guard !selectedTaskIds.isEmpty else { return .ignored }
                onToggleExpand()
                return .handled
            }
            .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { keyPress in
                guard expandedTask == nil else { return .ignored }

                if keyPress.modifiers == [.command, .option] {
                    // Alt+Cmd+K: mark as cancelled
                    onMarkCancelled()
                    return .handled
                } else if keyPress.modifiers == .command {
                    // Cmd+K: mark as completed
                    onMarkComplete()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [KeyEquivalent("a")], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) {
                    onSelectAll()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(keys: [.delete], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.command) && !selectedTaskIds.isEmpty {
                    showDeleteConfirmation = true
                    return .handled
                }
                return .ignored
            }
    }
}

// MARK: - Workspace Hint Inbox View

struct WorkspaceHintInboxView: View {
    let workspace: Workspace
    let filter: HintFilter
    @Binding var selection: Hint?

    private var hints: [Hint] {
        workspace.tasks.flatMap { $0.hints }.sorted { $0.createdAt > $1.createdAt }
    }

    private var filteredHints: [Hint] {
        switch filter {
        case .pending: return hints.filter { $0.hintStatus == .pending }
        case .answered: return hints.filter { $0.hintStatus == .answered }
        case .all: return hints
        }
    }

    private var headerTitle: String {
        switch filter {
        case .pending: "Pending"
        case .answered: "Resolved"
        case .all: "All"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(headerTitle)
                    .font(.title2.bold())
                Spacer()
                Text("\(filteredHints.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if filteredHints.isEmpty {
                emptyView
            } else {
                List(selection: $selection) {
                    ForEach(filteredHints) { hint in
                        HintRow(hint: hint)
                            .tag(hint)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 280)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(.green)

            Text("No Blockers")
                .font(.headline)

            Text("All clear! AI agents will ask questions here when they need help.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Spacer()

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
        .background(.background)
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

struct TaskRow: View {
    let task: WorkTask
    var position: Int? = nil
    var isHighlighted: Bool = false
    var isExpanded: Bool = false
    var isDragTarget: Bool = false
    var onTap: ((EventModifiers) -> Void)?
    var onRun: (() -> Void)?
    var onToggleComplete: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onDelete: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @State private var showNotes: Bool = false
    @State private var isHovering: Bool = false
    @State private var isTitleFocused: Bool = false
    @State private var isDescriptionFocused: Bool = false
    @State private var isStatusHovering: Bool = false
    @State private var showSkillPicker: Bool = false

    private var isRunning: Bool {
        task.taskStatus == .running
    }

    private var isCompleted: Bool {
        task.taskStatus == .completed
    }

    private var isQueued: Bool {
        task.taskStatus == .queued
    }

    private var checkboxSize: CGFloat { 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row - only this part handles taps for selection/expansion
            HStack(spacing: 12) {
                // Leading indicator
                ZStack {
                    if isRunning {
                        // Claude icon with hover to mark complete
                        RunningTaskIndicator(
                            size: checkboxSize,
                            isHovering: isStatusHovering,
                            onMarkComplete: onToggleComplete
                        )
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isStatusHovering = hovering
                            }
                        }
                    } else if isCompleted {
                        Button(action: { onToggleComplete?() }) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: checkboxSize, height: checkboxSize)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    } else if isQueued {
                        QueuedTaskIndicator(
                            size: checkboxSize,
                            isHovering: isStatusHovering,
                            position: position,
                            onRun: onRun
                        )
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isStatusHovering = hovering
                            }
                        }
                    } else {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: checkboxSize, height: checkboxSize)
                    }
                }

                // Title
                ZStack(alignment: .leading) {
                    // Static text (always present for stable layout)
                    Text(task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isCompleted ? .tertiary : .primary)
                        .strikethrough(isCompleted, color: .secondary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(showNotes ? 0 : 1)

                    // Editable field (appears after expand animation)
                    if showNotes {
                        MultilineTitleField(
                            text: Binding(
                                get: { task.title },
                                set: { task.updateTitle($0) }
                            ),
                            font: .systemFont(ofSize: 14),
                            shouldFocus: isTitleFocused,
                            onEscape: onCollapse,
                            onTab: {
                                isTitleFocused = false
                                isDescriptionFocused = true
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(showNotes) // Allow text field interaction when expanded

                // Subtle time indicator (only in compact)
                if !isExpanded && !isRunning && !isCompleted {
                    Text(task.createdAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            }
            .contextMenu {
                if isQueued, let onRun = onRun {
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    Divider()
                }

                Button {
                    onToggleComplete?()
                } label: {
                    if isCompleted {
                        Label("Mark as Incomplete", systemImage: "circle")
                    } else {
                        Label("Mark as Complete", systemImage: "checkmark.circle.fill")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            // Description - visible in both states
            if isExpanded {
                // Editable in expanded state
                GrowingTextView(
                    text: Binding(
                        get: { task.taskDescription ?? "" },
                        set: { task.updateDescription($0.isEmpty ? nil : $0) }
                    ),
                    placeholder: "Notes",
                    font: .systemFont(ofSize: 13),
                    shouldFocus: isDescriptionFocused,
                    onEscape: onCollapse,
                    onShiftTab: {
                        isDescriptionFocused = false
                        isTitleFocused = true
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .padding(.top, 6)
                .padding(.leading, 32)
                .opacity(showNotes ? 1 : 0)
                .animation(.easeIn(duration: 0.12), value: showNotes)
            } else if let description = task.taskDescription, !description.isEmpty {
                // Read-only preview in collapsed state
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .padding(.top, 4)
                    .padding(.leading, 32)
            }

            // Skills and Status row - only in expanded state
            if isExpanded {
                HStack(spacing: 8) {
                    // Attached skills chips
                    ForEach(task.taskSkills, id: \.id) { taskSkill in
                        if let skill = taskSkill.skill {
                            HStack(spacing: 4) {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 9))
                                Text(skill.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Button {
                                    // Remove skill
                                    modelContext.delete(taskSkill)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.purple.opacity(0.8))
                            )
                        }
                    }

                    // Add skill button
                    Button {
                        showSkillPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Attach skill")
                    .sheet(isPresented: $showSkillPicker) {
                        TaskSkillPickerView(task: task)
                    }

                    Spacer()

                    // Status dropdown
                    Menu {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            Button(action: {
                                // First collapse the task, then update status after animation completes
                                if task.taskStatus != status {
                                    onCollapse?()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        task.updateStatus(status)
                                    }
                                }
                            }) {
                                HStack {
                                    Text(status.menuLabel)
                                    if task.taskStatus == status {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(task.taskStatus.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .tracking(0.5)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(Color(hex: "9A9C9D")!)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(hex: "9A9C9D")!.opacity(isStatusHovering ? 0.5 : 0), lineWidth: 1)
                        )
                        .scaleEffect(isStatusHovering ? 1.05 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isStatusHovering)
                        .onHover { hovering in
                            isStatusHovering = hovering
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 8)
                .padding(.bottom, 8)
                .padding(.horizontal, 12)
                .opacity(showNotes ? 1 : 0)
                .animation(.easeIn(duration: 0.12), value: showNotes)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 10 : 6)
                .fill(isExpanded ? Color(white: 0.20) : (isHighlighted ? Color.orange.opacity(0.08) : .clear))
                .shadow(color: isExpanded ? .black.opacity(0.3) : .clear, radius: isExpanded ? 8 : 0, y: isExpanded ? 4 : 0)
        )
        .overlay(alignment: .top) {
            if isDragTarget {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(height: 3)
                    .padding(.horizontal, 8)
                    .offset(y: -2)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragTarget)
        .contentShape(Rectangle())
        .gesture(
            TapGesture()
                .modifiers(.shift)
                .onEnded { onTap?(.shift) }
        )
        .gesture(
            TapGesture()
                .modifiers(.command)
                .onEnded { onTap?(.command) }
        )
        .onTapGesture {
            onTap?([])
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .padding(.top, isExpanded ? 30 : 0)
        .padding(.bottom, isExpanded ? 45 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isExpanded)
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    showNotes = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isTitleFocused = true
                        isDescriptionFocused = false
                    }
                }
            } else {
                isTitleFocused = false
                isDescriptionFocused = false
                showNotes = false
            }
        }
        .onChange(of: task.taskStatus) { oldStatus, newStatus in
            // Collapse and notify when status changes (e.g., running -> queued)
            if oldStatus != newStatus {
                onStatusChange?()
            }
        }
        .accessibilityIdentifier("TaskRow")
        .accessibilityLabel(task.title)
    }
}

// MARK: - Running Task Indicator

/// Claude icon that pulses from white to orange, shows checkmark on hover
struct RunningTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    var onMarkComplete: (() -> Void)?

    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            if isHovering {
                // Checkmark circle on hover
                Button(action: { onMarkComplete?() }) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.45, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Pulsing Claude icon - plain orange
                ClaudeShape()
                    .fill(Color.orange.opacity(0.7 + pulsePhase * 0.3))
                    .frame(width: size * 0.85, height: size * 0.6)
                    .shadow(color: .orange.opacity(pulsePhase * 0.4), radius: 3)
                    .frame(width: size, height: size)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulsePhase = 1.0
            }
        }
    }
}

/// Indicator for queued tasks - play icon in a circle with hover effect
struct QueuedTaskIndicator: View {
    let size: CGFloat
    let isHovering: Bool
    let position: Int?
    var onRun: (() -> Void)?

    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            if isHovering {
                // Play circle on hover - ready to start
                Button(action: { onRun?() }) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: size, height: size)

                        Circle()
                            .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1.5)
                            .frame(width: size, height: size)

                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.orange)
                    }
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                // Subtle play indicator in a circle
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15 + pulsePhase * 0.1), lineWidth: 1.5)
                        .frame(width: size, height: size)

                    if let pos = position {
                        Text("\(pos)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.35))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulsePhase = 1.0
            }
        }
    }
}

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
                .foregroundStyle(.purple)

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

private class TitleTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?

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
        invalidateIntrinsicContentSize()
    }
}

struct MultilineTitleField: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    @Binding var text: String
    var font: NSFont
    var shouldFocus: Bool
    var onEscape: (() -> Void)?
    var onTab: (() -> Void)?

    func makeNSView(context: NSViewRepresentableContext<MultilineTitleField>) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

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
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.focusRingType = .none
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: NSViewRepresentableContext<MultilineTitleField>) {
        guard let textView = scrollView.documentView as? TitleTextView else { return }

        textView.onEscape = onEscape
        textView.onTab = onTab

        if textView.string != text {
            textView.string = text
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
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(isDragging ? 0.2 : 0.08))
            .frame(width: 1)
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
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 16))
                    .foregroundStyle(.purple)

                Text("Optimizations")
                    .font(.system(size: 20, weight: .bold))

                Spacer()
            }
            .frame(maxWidth: 1000)
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
            .padding(.bottom, 24)

            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundStyle(.tertiary)

                Text("Optimize your agents")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Add skills and context to improve agent performance")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 27.0 / 255.0))
    }
}
#endif
