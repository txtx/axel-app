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
        var command = "axel claude --pane-id=\(paneId) --port=\(port)"
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

                ResizableDivider(width: currentListColumnWidthBinding, minWidth: 220, maxWidth: 400)

                detailColumnView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebarView(
                workspace: workspace,
                selection: $sidebarSelection
            )
        } detail: {
            sectionView
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 650, idealHeight: 800)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Centered workspace info (Xcode style)
                WorkspaceToolbarHeader(workspace: workspace, showTerminal: $showTerminal)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // Sign in button (only when not authenticated)
                if !authService.isAuthenticated {
                    Button {
                        Task {
                            print("[WorkspaceContentView] Sign in button pressed")
                            await authService.signInWithGitHub()
                            print("[WorkspaceContentView] Sign in completed, error: \(String(describing: authService.authError))")
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
        .keyboardShortcut(for: .closeTerminal) {
            // Only show confirmation when Agents sidebar is selected and a session is selected
            if case .terminals = sidebarSelection, selectedSession != nil {
                showCloseTerminalConfirmation = true
            }
        }
        .keyboardShortcut(for: .showTasks) {
            sidebarSelection = .queue(.queued)
        }
        .keyboardShortcut(for: .showAgents) {
            sidebarSelection = .terminals
        }
        .keyboardShortcut(for: .showInbox) {
            sidebarSelection = .inbox(.pending)
        }
        .keyboardShortcut(for: .showSkills) {
            sidebarSelection = .optimizations(.skills)
        }
        .alert("Close Terminal?", isPresented: $showCloseTerminalConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Close", role: .destructive) {
                if let session = selectedSession {
                    sessionManager.stopSession(session)
                    selectedSession = nil
                }
            }
        } message: {
            Text("This will stop the running terminal session. Any unsaved work may be lost.")
        }
        .sheet(isPresented: $appState.isNewTaskPresented) {
            WorkspaceCreateTaskView(workspace: workspace, isPresented: $appState.isNewTaskPresented) { task in
                startTerminal(for: task)
            }
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
        .onChange(of: selectedTask) { _, _ in
            showTerminal = false
        }
        .task {
            // Connect to inbox service early so we receive events even if inbox view isn't shown
            InboxService.shared.connect()

            // Register this workspace as active for scoped syncing
            let workspaceId = workspace.syncId ?? workspace.id
            syncService.registerActiveWorkspace(workspaceId)

            // Sync on launch if authenticated
            performSync()
            // Start real-time sync for THIS workspace only
            if authService.isAuthenticated {
                await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
            }
        }
        .onDisappear {
            // Unregister workspace when window closes
            let workspaceId = workspace.syncId ?? workspace.id
            syncService.unregisterActiveWorkspace(workspaceId)
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
                    let workspaceId = workspace.syncId ?? workspace.id
                    await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
                }
            }
        }
        .navigationTitle(workspace.name)
        .focusedSceneValue(\.newTaskAction) {
            appState.isNewTaskPresented = true
        }
        .focusedSceneValue(\.runTaskAction, selectedTask != nil ? {
            if let task = selectedTask, task.taskStatus == .queued {
                startTerminal(for: task)
            }
        } : nil)
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
    let workspace: Workspace
    @Environment(\.modelContext) private var modelContext
    let filter: TaskFilter
    @Binding var highlightedTask: WorkTask?
    var onNewTask: () -> Void
    var onStartTerminal: ((WorkTask) -> Void)?
    @State private var expandedTask: WorkTask?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapTaskId: UUID?
    @State private var viewModel = TodoViewModel()
    @State private var showTerminal = false
    @State private var draggingTask: WorkTask?
    @State private var dropTargetTaskId: UUID?

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

    private var headerTitle: String {
        switch filter {
        case .queued: "Tasks"
        case .running: "Agents"
        case .completed: "Completed"
        case .all: "All Tasks"
        }
    }

    private func handleTap(on task: WorkTask) {
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
        } else {
            // Single click: select
            highlightedTask = task
            lastTapTime = now
            lastTapTaskId = task.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
            .padding(.top, 20)
            .padding(.bottom, 24)

            if allFilteredTasks.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if filter == .queued {
                            // Running tasks
                            if !runningTasks.isEmpty {
                                sectionHeader("Running")
                                ForEach(runningTasks, id: \.id) { task in
                                    TaskRow(
                                        task: task,
                                        isHighlighted: highlightedTask?.id == task.id,
                                        isExpanded: expandedTask?.id == task.id,
                                        onTap: { handleTap(on: task) },
                                        onToggleComplete: { toggleComplete(task) },
                                        onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
                                        onStatusChange: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } }
                                    )
                                }
                            }
                            // Queued tasks
                            if !queuedTasks.isEmpty && !runningTasks.isEmpty {
                                sectionHeader("Up Next")
                            }
                            ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { index, task in
                                TaskRow(
                                    task: task,
                                    position: index + 1,
                                    isHighlighted: highlightedTask?.id == task.id,
                                    isExpanded: expandedTask?.id == task.id,
                                    isDragTarget: dropTargetTaskId == task.id,
                                    onTap: { handleTap(on: task) },
                                    onRun: { onStartTerminal?(task) },
                                    onToggleComplete: { toggleComplete(task) },
                                    onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
                                    onStatusChange: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } }
                                )
                                .opacity(draggingTask?.id == task.id ? 0.5 : 1.0)
                                .draggable(task.id.uuidString) {
                                    // Drag preview
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
                                .dropDestination(for: String.self) { items, _ in
                                    guard let droppedIdString = items.first,
                                          let droppedId = UUID(uuidString: droppedIdString),
                                          let droppedTask = queuedTasks.first(where: { $0.id == droppedId }),
                                          droppedTask.id != task.id else {
                                        return false
                                    }
                                    reorderTask(droppedTask, before: task)
                                    return true
                                } isTargeted: { isTargeted in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        dropTargetTaskId = isTargeted ? task.id : nil
                                    }
                                }
                            }
                            .onDrop(of: [.text], isTargeted: nil) { _ in
                                draggingTask = nil
                                return false
                            }
                        } else {
                            ForEach(allFilteredTasks, id: \.id) { task in
                                TaskRow(
                                    task: task,
                                    isHighlighted: highlightedTask?.id == task.id,
                                    isExpanded: expandedTask?.id == task.id,
                                    onTap: { handleTap(on: task) },
                                    onToggleComplete: { toggleComplete(task) },
                                    onCollapse: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } },
                                    onStatusChange: { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedTask = nil } }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: 1000)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
                .animation(.easeInOut(duration: 0.2), value: allFilteredTasks.map(\.id))
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTask = nil
                    }
                    highlightedTask = nil
                }
            }
        }
        .background(
            Color(white: 27.0 / 255.0) // #1B1B1B
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedTask = nil
                    }
                    highlightedTask = nil
                }
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            if expandedTask != nil {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expandedTask = nil
                }
                return .handled
            }
            if highlightedTask != nil {
                highlightedTask = nil
                return .handled
            }
            return .ignored
        }
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
    let workspace: Workspace
    @Binding var isPresented: Bool
    var onRun: ((WorkTask) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @FocusState private var isFocused: Bool

    init(workspace: Workspace, isPresented: Binding<Bool>, onRun: ((WorkTask) -> Void)? = nil) {
        self.workspace = workspace
        self._isPresented = isPresented
        self.onRun = onRun
    }

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

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority = workspace.tasks
            .filter { $0.taskStatus == .queued }
            .map { $0.priority }
            .max() ?? 0

        let task = WorkTask(title: trimmedTitle)
        task.workspace = workspace
        task.priority = maxPriority + 50  // New tasks go to bottom of queue with room for reordering
        modelContext.insert(task)
        isPresented = false

        // Sync to push the new task to Supabase
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }
    }

    private func createAndRunTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority = workspace.tasks
            .filter { $0.taskStatus == .queued }
            .map { $0.priority }
            .max() ?? 0

        let task = WorkTask(title: trimmedTitle)
        task.workspace = workspace
        task.priority = maxPriority + 50
        modelContext.insert(task)
        isPresented = false

        // Sync to push the new task to Supabase, then run
        Task {
            let workspaceId = workspace.syncId ?? workspace.id
            await SyncService.shared.performWorkspaceSync(workspaceId: workspaceId, context: modelContext)
        }

        // Start the terminal for this task
        onRun?(task)
    }
}

// MARK: - Row Views

struct TaskRow: View {
    let task: WorkTask
    var position: Int? = nil
    var isHighlighted: Bool = false
    var isExpanded: Bool = false
    var isDragTarget: Bool = false
    var onTap: (() -> Void)?
    var onRun: (() -> Void)?
    var onToggleComplete: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onStatusChange: (() -> Void)?
    @State private var showNotes: Bool = false
    @State private var isHovering: Bool = false
    @State private var isTitleFocused: Bool = false
    @State private var isStatusHovering: Bool = false

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
                        .opacity(showNotes ? 0 : 1)

                    // Editable field (appears after expand animation)
                    if showNotes {
                        CursorAtEndTextField(
                            text: Binding(
                                get: { task.title },
                                set: { task.updateTitle($0) }
                            ),
                            shouldFocus: isTitleFocused,
                            font: .systemFont(ofSize: 14),
                            onEscape: onCollapse
                        )
                    }
                }
                .allowsHitTesting(showNotes) // Allow text field interaction when expanded

                Spacer()

                // Subtle time indicator (only in compact)
                if !isExpanded && !isRunning && !isCompleted {
                    Text(task.createdAt, style: .relative)
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }

            // Notes (only in expanded)
            if isExpanded {
                GrowingTextView(
                    text: Binding(
                        get: { task.taskDescription ?? "" },
                        set: { task.updateDescription($0.isEmpty ? nil : $0) }
                    ),
                    placeholder: "Notes",
                    font: .systemFont(ofSize: 14),
                    shouldFocus: showNotes && !isTitleFocused,
                    onEscape: onCollapse
                )
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .padding(.top, 12)
                .padding(.leading, 32)
                .opacity(showNotes ? 1 : 0)
                .animation(.easeIn(duration: 0.12), value: showNotes)

                // Status dropdown - bottom right
                HStack {
                    Spacer()
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
                    }
                }
            } else {
                isTitleFocused = false
                showNotes = false
            }
        }
        .onChange(of: task.taskStatus) { oldStatus, newStatus in
            // Collapse and notify when status changes (e.g., running -> queued)
            if oldStatus != newStatus {
                onStatusChange?()
            }
        }
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

// MARK: - Cursor At End TextField

struct CursorAtEndTextField: NSViewRepresentable {
    typealias NSViewType = NSTextField

    @Binding var text: String
    var shouldFocus: Bool
    var font: NSFont
    var onEscape: (() -> Void)?

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
            return false
        }
    }
}

// MARK: - Growing Text View

private class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""
    var placeholderFont: NSFont = .systemFont(ofSize: 14)
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        onEscape?()
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
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
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
