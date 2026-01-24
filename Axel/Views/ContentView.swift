import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

#if os(macOS)
// MARK: - Keyboard Shortcuts

enum AppKeyboardShortcut {
    case runTerminal
    case newTerminal
    case closeTerminal

    var key: KeyEquivalent {
        switch self {
        case .runTerminal: return "r"
        case .newTerminal: return "t"
        case .closeTerminal: return "w"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .runTerminal: return .command
        case .newTerminal: return .command
        case .closeTerminal: return .command
        }
    }
}

extension View {
    func keyboardShortcut(for shortcut: AppKeyboardShortcut, action: @escaping () -> Void) -> some View {
        self.background(
            Button("") { action() }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                .hidden()
        )
    }
}
#endif

enum SidebarSection: Hashable {
    case inbox(HintFilter)
    case queue(TaskFilter)
    case skills
    case context
    case team
    case terminals
}

enum HintFilter: String, CaseIterable, Identifiable {
    case pending = "Pending"
    case answered = "Resolved"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .pending: "questionmark.circle"
        case .answered: "checkmark.circle"
        case .all: "tray.full"
        }
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case queued = "Queued"
    case running = "Running"
    case completed = "Completed"
    case all = "All"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "play.circle"
        case .completed: "checkmark.circle"
        case .all: "square.stack"
        }
    }
}

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
        #if os(macOS)
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
        #endif
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

// MARK: - iOS/visionOS Content View

#if os(iOS) || os(visionOS)
struct iOSContentView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    var viewModel: TodoViewModel
    @Binding var sidebarSelection: SidebarSection?
    @Binding var selectedHint: Hint?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedAgent: AgentSelection?
    @Binding var selectedContext: Context?
    @Binding var selectedTeamMember: OrganizationMember?
    @Binding var showTerminal: Bool
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @State private var selectedWorkspace: Workspace?
    @Query(sort: \Workspace.updatedAt, order: .reverse) private var workspaces: [Workspace]

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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

    private func performSync() {
        guard authService.isAuthenticated else { return }
        guard !syncService.isSyncing else { return }

        // Check if we need to run cleanup (first launch after deletion sync was added)
        let hasRunCleanup = UserDefaults.standard.bool(forKey: "hasRunDeletionCleanup")
        if !hasRunCleanup {
            print("[iOSContentView] Running one-time deletion cleanup...")
            Task {
                await syncService.performCleanupSync(context: modelContext)
                UserDefaults.standard.set(true, forKey: "hasRunDeletionCleanup")
            }
        } else {
            // Use background sync (runs entirely off main thread)
            print("[iOSContentView] Triggering background sync...")
            syncService.performFullSyncInBackground(container: modelContext.container)
        }
    }

    var body: some View {
        Group {
        #if os(visionOS)
        // visionOS - Spatial tab-based navigation with ornaments
        visionOSContentView(
            appState: appState,
            viewModel: viewModel,
            selectedHint: $selectedHint,
            selectedTask: $selectedTask,
            selectedAgent: $selectedAgent,
            selectedContext: $selectedContext
        )
        #else
        if horizontalSizeClass == .compact {
            // iPhone - Tab-based navigation
            iPhoneTabView(
                appState: appState,
                viewModel: viewModel,
                selectedHint: $selectedHint,
                selectedTask: $selectedTask,
                selectedAgent: $selectedAgent,
                selectedContext: $selectedContext
            )
        } else {
            // iPad - Split view navigation
            iPadSplitView(
                appState: appState,
                viewModel: viewModel,
                sidebarSelection: $sidebarSelection,
                selectedHint: $selectedHint,
                selectedTask: $selectedTask,
                selectedAgent: $selectedAgent,
                selectedContext: $selectedContext,
                selectedTeamMember: $selectedTeamMember,
                showTerminal: $showTerminal,
                currentHintFilter: currentHintFilter,
                currentTaskFilter: currentTaskFilter
            )
        }
        #endif
        }
        .task {
            print("[iOSContentView] .task started, workspaces count: \(workspaces.count)")

            // Set up SyncScheduler with this context for auto-sync
            SyncScheduler.shared.iosContext = modelContext

            // Select first workspace if none selected
            if selectedWorkspace == nil, let first = workspaces.first {
                selectedWorkspace = first
                print("[iOSContentView] Selected first workspace: \(first.name)")
            }

            // Sync on launch (non-blocking background sync)
            performSync()

            // Register ALL workspaces and start realtime for each (fire-and-forget)
            if authService.isAuthenticated {
                let service = syncService
                let context = modelContext
                for workspace in workspaces {
                    let workspaceId = workspace.syncId ?? workspace.id
                    print("[iOSContentView] Registering workspace: \(workspace.name)")
                    service.registerActiveWorkspace(workspaceId)
                }
                // Start realtime in background - don't block
                Task {
                    for workspace in workspaces {
                        let workspaceId = workspace.syncId ?? workspace.id
                        await service.startRealtimeSync(context: context, workspaceId: workspaceId)
                    }
                }
            } else {
                print("[iOSContentView] Not authenticated, skipping realtime sync")
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
                // Subscribe to all workspaces
                Task {
                    for workspace in workspaces {
                        let workspaceId = workspace.syncId ?? workspace.id
                        syncService.registerActiveWorkspace(workspaceId)
                        await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
                    }
                }
            }
        }
        .onChange(of: workspaces) { oldWorkspaces, newWorkspaces in
            // Register any new workspaces for realtime
            let oldIds = Set(oldWorkspaces.map { $0.syncId ?? $0.id })
            let newIds = Set(newWorkspaces.map { $0.syncId ?? $0.id })

            // New workspaces that weren't in old list
            let addedIds = newIds.subtracting(oldIds)
            if !addedIds.isEmpty && authService.isAuthenticated {
                Task {
                    for workspace in newWorkspaces where addedIds.contains(workspace.syncId ?? workspace.id) {
                        let workspaceId = workspace.syncId ?? workspace.id
                        print("[iOSContentView] New workspace detected, subscribing: \(workspaceId)")
                        syncService.registerActiveWorkspace(workspaceId)
                        await syncService.startRealtimeSync(context: modelContext, workspaceId: workspaceId)
                    }
                }
            }

            // Select first workspace if current selection is gone or none selected
            if selectedWorkspace == nil || !newWorkspaces.contains(where: { $0.id == selectedWorkspace?.id }) {
                selectedWorkspace = newWorkspaces.first
            }
        }
    }
}

// MARK: - iPhone Tab View

struct iPhoneTabView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    var viewModel: TodoViewModel
    @Binding var selectedHint: Hint?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedAgent: AgentSelection?
    @Binding var selectedContext: Context?

    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // Inbox Tab (Hints) - RED icon for call to action
            NavigationStack {
                iPhoneInboxView(selection: $selectedHint)
            }
            .tabItem {
                Label("Inbox", systemImage: "rectangle.stack")
            }
            .tag(0)

            // Tasks Tab
            NavigationStack {
                iPhoneQueueView(viewModel: viewModel, selection: $selectedTask, appState: appState)
            }
            .tabItem {
                Label("Tasks", systemImage: "tray.fill")
            }
            .tag(1)

            // Terminals Tab
            NavigationStack {
                iPhoneTerminalsView()
            }
            .tabItem {
                Label("Terminals", systemImage: "terminal")
            }
            .tag(2)

            // Settings Tab
            NavigationStack {
                iPhoneSettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(3)
        }
        .tint(.blue)
    }
}

// MARK: - Workspace Filter Chips

struct WorkspaceFilterChips: View {
    let workspaces: [Workspace]
    @Binding var selectedWorkspaceId: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    label: "All",
                    isSelected: selectedWorkspaceId == nil,
                    color: .blue
                ) {
                    selectedWorkspaceId = nil
                }

                ForEach(workspaces) { workspace in
                    FilterChip(
                        label: workspace.name,
                        isSelected: selectedWorkspaceId == workspace.id,
                        color: .blue
                    ) {
                        if selectedWorkspaceId == workspace.id {
                            selectedWorkspaceId = nil
                        } else {
                            selectedWorkspaceId = workspace.id
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? color : Color.white.opacity(0.08))
                .foregroundStyle(isSelected ? .white : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iPhone Inbox View (Hints)

/// View mode for iPhone inbox
enum iPhoneInboxViewMode: String, CaseIterable {
    case cards = "Cards"
    case list = "List"

    var icon: String {
        switch self {
        case .cards: return "rectangle.stack"
        case .list: return "list.bullet"
        }
    }
}

struct iPhoneInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hint.createdAt, order: .reverse) private var allHints: [Hint]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]

    @Binding var selection: Hint?
    @State private var filterWorkspaceId: UUID?
    @State private var syncService = SyncService.shared
    @AppStorage("iPhoneInboxViewMode") private var viewMode: iPhoneInboxViewMode = .cards

    private var hints: [Hint] {
        guard let filterWorkspaceId else { return allHints }
        return allHints.filter { hint in
            hint.task?.workspace?.id == filterWorkspaceId
        }
    }

    private var pendingHints: [Hint] {
        hints.filter { $0.hintStatus == .pending }
    }

    var body: some View {
        Group {
            #if os(iOS)
            switch viewMode {
            case .cards:
                iPhoneInboxCardStackView(selection: $selection)
            case .list:
                listContent
            }
            #else
            listContent
            #endif
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Hint.self) { hint in
            iPhoneHintDetailView(hint: hint)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack {
                    Text("Inbox")
                        .font(.headline)
                    if pendingHints.count > 0 {
                        Text("\(pendingHints.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange)
                            .clipShape(Capsule())
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Picker("View", selection: $viewMode) {
                    ForEach(iPhoneInboxViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
        }
    }

    private var listContent: some View {
        List {
            // Workspace filter chips
            if !workspaces.isEmpty {
                Section {
                    WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            if !pendingHints.isEmpty {
                Section("Pending") {
                    ForEach(pendingHints) { hint in
                        NavigationLink(value: hint) {
                            iPhoneHintRow(hint: hint)
                        }
                    }
                }
            }

            let answeredHints = hints.filter { $0.hintStatus == .answered }
            if !answeredHints.isEmpty {
                Section("Resolved") {
                    ForEach(answeredHints) { hint in
                        NavigationLink(value: hint) {
                            iPhoneHintRow(hint: hint)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // Trigger background sync using container (runs off main thread)
            syncService.performFullSyncInBackground(container: modelContext.container)
            // Brief pause for visual feedback
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        .overlay {
            if hints.isEmpty {
                ContentUnavailableView {
                    Label("No Blockers", systemImage: "checkmark.seal")
                } description: {
                    Text("All clear! AI agents will ask questions here when they need help.")
                }
            }
        }
    }
}

struct iPhoneHintRow: View {
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

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.title)
                    .font(.body)
                    .foregroundStyle(hint.hintStatus == .pending ? .primary : .secondary)
                    .lineLimit(2)

                if let task = hint.task {
                    Text(task.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if hint.hintStatus == .pending {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

struct iPhoneHintDetailView: View {
    @Bindable var hint: Hint
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOption: String?
    @State private var selectedOptions: Set<String> = []
    @State private var textResponse: String = ""

    var body: some View {
        Form {
            Section {
                Text(hint.title)
                    .font(.headline)

                if let description = hint.hintDescription {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            if hint.hintStatus == .pending {
                Section("Your Response") {
                    responseContent
                }

                Section {
                    Button {
                        submitResponse()
                    } label: {
                        Label("Submit", systemImage: "paperplane.fill")
                    }
                    .disabled(!canSubmit)
                }
            } else {
                Section("Your Response") {
                    if let data = hint.responseData,
                       let response = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
                        Text(response.description)
                            .foregroundStyle(.green)
                    }

                    if let answeredAt = hint.answeredAt {
                        Text("Resolved \(answeredAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Question")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var responseContent: some View {
        switch hint.hintType {
        case .exclusiveChoice:
            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        selectedOption = option.value
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedOption == option.value {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        case .multipleChoice:
            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        if selectedOptions.contains(option.value) {
                            selectedOptions.remove(option.value)
                        } else {
                            selectedOptions.insert(option.value)
                        }
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedOptions.contains(option.value) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        case .textInput:
            TextField("Enter your response", text: $textResponse, axis: .vertical)
                .lineLimit(3...6)
        }
    }

    private var canSubmit: Bool {
        switch hint.hintType {
        case .exclusiveChoice: selectedOption != nil
        case .multipleChoice: !selectedOptions.isEmpty
        case .textInput: !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submitResponse() {
        var response: Any
        switch hint.hintType {
        case .exclusiveChoice: response = selectedOption ?? ""
        case .multipleChoice: response = Array(selectedOptions)
        case .textInput: response = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = try? JSONEncoder().encode(AnyCodableValue(response)) {
            hint.responseData = data
        }
        hint.hintStatus = .answered
        hint.answeredAt = Date()
        dismiss()
    }
}

// MARK: - iPhone Tasks View

struct iPhoneQueueView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.priority) private var allTasks: [WorkTask]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]

    var viewModel: TodoViewModel
    @Binding var selection: WorkTask?
    @Bindable var appState: AppState
    @State private var filterWorkspaceId: UUID?
    @State private var syncService = SyncService.shared

    private var selectedWorkspace: Workspace? {
        guard let filterWorkspaceId else { return nil }
        return workspaces.first { $0.id == filterWorkspaceId }
    }

    private var tasks: [WorkTask] {
        guard let filterWorkspaceId else { return allTasks }
        return allTasks.filter { $0.workspace?.id == filterWorkspaceId }
    }

    private var queuedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .queued }.sorted { $0.priority < $1.priority }
    }

    private var runningTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .running }.sorted { $0.priority < $1.priority }
    }

    private var completedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .completed }.sorted { $0.completedAt ?? $0.updatedAt > $1.completedAt ?? $1.updatedAt }
    }

    private var activeCount: Int {
        runningTasks.count + queuedTasks.count
    }

    private var allFilteredTasks: [WorkTask] {
        runningTasks + queuedTasks + completedTasks
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.blue)

                        Text("Tasks")
                            .font(.system(size: 28, weight: .bold))

                        Spacer()
                    }

                    // Workspace filter
                    if !workspaces.isEmpty {
                        WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 20)

                if allFilteredTasks.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "tray")
                            .font(.system(size: 40, weight: .thin))
                            .foregroundStyle(.tertiary)
                        Text("No tasks yet")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if !runningTasks.isEmpty {
                                sectionHeader("Running")
                                ForEach(runningTasks, id: \.id) { task in
                                    NavigationLink(value: task) {
                                        SlickTaskRow(task: task, position: nil)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !queuedTasks.isEmpty {
                                if !runningTasks.isEmpty {
                                    sectionHeader("Up Next")
                                }
                                ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { index, task in
                                    NavigationLink(value: task) {
                                        SlickTaskRow(task: task, position: index + 1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if !completedTasks.isEmpty {
                                sectionHeader("Completed")
                                ForEach(completedTasks, id: \.id) { task in
                                    NavigationLink(value: task) {
                                        SlickTaskRow(task: task, position: nil)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 80)
                    }
                    .refreshable {
                        syncService.performFullSyncInBackground(container: modelContext.container)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }

            // Floating action button
            Button {
                appState.isNewTaskPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.blue)
                    .clipShape(Circle())
                    .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .background(Color(white: 0.11))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: WorkTask.self) { task in
            iPhoneTaskDetailView(task: task, viewModel: viewModel)
        }
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented, workspace: selectedWorkspace)
                .presentationDetents([.medium])
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.35))
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
        }
        .padding(.leading, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}


struct iPhoneTaskDetailView: View {
    @Bindable var task: WorkTask
    var viewModel: TodoViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var isPreviewingMarkdown: Bool = false
    @State private var syncService = SyncService.shared

    var body: some View {
        Form {
            Section {
                TextField("Task", text: $editedTitle, axis: .vertical)
                    .font(.body)
                    .onChange(of: editedTitle) { _, newValue in
                        // Only update if the value actually changed
                        guard newValue != task.title else { return }
                        task.updateTitle(newValue)
                    }
            }

            // Description (Markdown)
            Section {
                Picker("Mode", selection: $isPreviewingMarkdown) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if isPreviewingMarkdown {
                    if editedDescription.isEmpty {
                        Text("No description")
                            .foregroundStyle(.tertiary)
                            .italic()
                    } else {
                        Text(LocalizedStringKey(editedDescription))
                    }
                } else {
                    TextEditor(text: $editedDescription)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .onChange(of: editedDescription) { _, newValue in
                            // Only update if the value actually changed
                            let newDesc = newValue.isEmpty ? nil : newValue
                            guard newDesc != task.taskDescription else { return }
                            task.updateDescription(newDesc)
                        }

                    Text("Supports **bold**, *italic*, `code`, - lists, # headings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Description (Markdown)")
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(task.taskStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Created")
                    Spacer()
                    Text(task.createdAt, style: .date)
                        .foregroundStyle(.secondary)
                }

                if task.taskStatus == .completed, let completedAt = task.completedAt {
                    HStack {
                        Text("Completed")
                        Spacer()
                        Text(completedAt, style: .relative)
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Change Status") {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        withAnimation {
                            // Use automerge-aware method to track local changes
                            if status == .completed {
                                task.markCompleted()
                            } else {
                                task.updateStatus(status)
                            }
                        }
                        Task {
                            await syncService.performFullSync(context: modelContext)
                        }
                    } label: {
                        HStack {
                            Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                .foregroundStyle(.primary)
                            Spacer()
                            if task.taskStatus == status {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    Task {
                        await viewModel.deleteTodo(task, context: modelContext)
                    }
                    dismiss()
                } label: {
                    Label("Delete Task", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.id) { _, _ in
            // Task selection changed
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.title) { _, newTitle in
            // Update local state when sync updates title
            if editedTitle != newTitle {
                editedTitle = newTitle
            }
        }
        .onChange(of: task.taskDescription) { _, newDescription in
            // Update local state when sync updates description
            let newValue = newDescription ?? ""
            if editedDescription != newValue {
                editedDescription = newValue
            }
        }
        .onDisappear {
            // Sync changes when leaving the detail view
            Task {
                await syncService.performFullSync(context: modelContext)
            }
        }
    }
}

// MARK: - iPhone Skills View

struct iPhoneSkillsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.updatedAt, order: .reverse) private var skills: [Skill]
    @Binding var selection: Skill?
    @State private var isCreating = false

    var body: some View {
        List {
            ForEach(skills) { skill in
                NavigationLink(value: skill) {
                    iPhoneSkillRow(skill: skill)
                }
            }
            .onDelete(perform: deleteSkills)
        }
        .listStyle(.plain)
        .navigationTitle("Skills")
        .navigationDestination(for: Skill.self) { skill in
            iPhoneSkillDetailView(skill: skill)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateSkillView(isPresented: $isCreating, onCreated: { skill in
                selection = skill
            })
        }
        .overlay {
            if skills.isEmpty {
                ContentUnavailableView {
                    Label("No Skills", systemImage: "sparkles")
                } description: {
                    Text("Skills define what your agent can do")
                }
            }
        }
    }

    private func deleteSkills(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(skills[index])
        }
    }
}

struct iPhoneSkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.body)
                    .lineLimit(1)

                Text(skill.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct iPhoneSkillDetailView: View {
    @Bindable var skill: Skill
    @State private var editedContent: String = ""

    var body: some View {
        TextEditor(text: $editedContent)
            .font(.system(.body, design: .monospaced))
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                editedContent = skill.content
            }
            .onChange(of: editedContent) { _, newValue in
                skill.updateContent(newValue)
            }
    }
}

// MARK: - iPhone Context View

struct iPhoneContextView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Context.updatedAt, order: .reverse) private var contexts: [Context]
    @Binding var selection: Context?
    @State private var isCreating = false

    var body: some View {
        List {
            ForEach(contexts) { context in
                NavigationLink(value: context) {
                    iPhoneContextRow(context: context)
                }
            }
            .onDelete(perform: deleteContexts)
        }
        .listStyle(.plain)
        .navigationTitle("Context")
        .navigationDestination(for: Context.self) { context in
            iPhoneContextDetailView(context: context)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateContextView(isPresented: $isCreating, selection: $selection)
        }
        .overlay {
            if contexts.isEmpty {
                ContentUnavailableView {
                    Label("No Context", systemImage: "doc.text")
                } description: {
                    Text("Context provides background for your agent")
                }
            }
        }
    }

    private func deleteContexts(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(contexts[index])
        }
    }
}

struct iPhoneContextRow: View {
    let context: Context

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.name)
                    .font(.body)
                    .lineLimit(1)

                Text(context.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct iPhoneContextDetailView: View {
    @Bindable var context: Context
    @State private var editedContent: String = ""

    var body: some View {
        TextEditor(text: $editedContent)
            .font(.system(.body, design: .monospaced))
            .navigationTitle(context.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                editedContent = context.content
            }
            .onChange(of: editedContent) { _, newValue in
                context.updateContent(newValue)
            }
    }
}

// MARK: - iPhone Terminals View

struct iPhoneTerminalsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Terminals", systemImage: "terminal")
        } description: {
            Text("Running terminal sessions will appear here")
        }
        .navigationTitle("Terminals")
    }
}

// MARK: - iPhone Settings View

struct iPhoneSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Organization.name) private var organizations: [Organization]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared

    var body: some View {
        List {
            // Sync Section
            if authService.isAuthenticated {
                Section("Sync") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if syncService.isSyncing {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Syncing...")
                                        .foregroundStyle(.secondary)
                                }
                            } else if let lastSync = syncService.lastSyncDate {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Synced")
                                        .foregroundStyle(.green)
                                }
                                Text(lastSync, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not synced yet")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            Task {
                                await syncService.performFullSync(context: modelContext)
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.title3)
                        }
                        .disabled(syncService.isSyncing)
                    }

                    if let error = syncService.syncError {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }


            // Organization Section
            Section {
                if organizations.isEmpty {
                    Text("No organizations")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(organizations) { org in
                        HStack {
                            Image(systemName: "building.2")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(org.name)
                                    .foregroundStyle(.primary)
                                Text("\(workspaces.filter { $0.organization?.id == org.id }.count) workspaces")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Organization")
            } footer: {
                Text("Workspaces and tasks are synced across your organization")
            }

            // Account Section
            Section("Account") {
                if authService.isAuthenticated {
                    if let user = authService.currentUser {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: user.userMetadata["avatar_url"]?.stringValue ?? "")) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.userMetadata["user_name"]?.stringValue ?? user.email ?? "User")
                                    .font(.body.weight(.medium))
                                if let email = user.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        Button(role: .destructive) {
                            Task {
                                await signOutAndWipeData()
                            }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } else {
                    Button {
                        Task {
                            await authService.signInWithGitHub()
                        }
                    } label: {
                        HStack {
                            Label("Sign in with GitHub", systemImage: "arrow.right.circle.fill")
                            Spacer()
                            if authService.isLoading {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(authService.isLoading)

                    Text("Sign in to sync your tasks, skills, and context across all your devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = authService.authError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Agent") {
                NavigationLink {
                    Text("Agent Settings")
                } label: {
                    Label("Agent Configuration", systemImage: "cpu")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }

    private func signOutAndWipeData() async {
        await authService.signOut(clearingLocalData: modelContext)
    }
}

// MARK: - iPad Split View

struct iPadSplitView: View {
    @Bindable var appState: AppState
    var viewModel: TodoViewModel
    @Binding var sidebarSelection: SidebarSection?
    @Binding var selectedHint: Hint?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedAgent: AgentSelection?
    @Binding var selectedContext: Context?
    @Binding var selectedTeamMember: OrganizationMember?
    @Binding var showTerminal: Bool
    var currentHintFilter: HintFilter
    var currentTaskFilter: TaskFilter

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $sidebarSelection,
                onNewTask: { appState.isNewTaskPresented = true }
            )
        } content: {
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
                Text("Terminals")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
            case .team:
                if let member = selectedTeamMember {
                    TeamMemberDetailView(member: member)
                } else {
                    EmptyTeamSelectionView()
                }
            case .queue:
                if let task = selectedTask {
                    TaskDetailView(task: task, viewModel: viewModel, showTerminal: $showTerminal, selectedTask: $selectedTask)
                } else {
                    EmptyTaskSelectionView()
                }
            default:
                if let hint = selectedHint {
                    HintDetailView(hint: hint)
                } else {
                    EmptyHintSelectionView()
                }
            }
        }
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
                .presentationDetents([.medium])
        }
        .onChange(of: selectedTask) { _, _ in
            showTerminal = false
        }
    }
}

// MARK: - Slick Task Row (shared iOS/visionOS)

struct SlickTaskRow: View {
    let task: WorkTask
    var position: Int? = nil

    private let indicatorSize: CGFloat = 26

    private var isRunning: Bool { task.taskStatus == .running }
    private var isCompleted: Bool { task.taskStatus == .completed }
    private var isQueued: Bool { task.taskStatus == .queued }

    var body: some View {
        HStack(spacing: 16) {
            // Leading status indicator
            ZStack {
                if isRunning {
                    HStack(alignment: .bottom, spacing: 2) {
                        RoundedRectangle(cornerRadius: 1).frame(width: 3.5, height: 7)
                        RoundedRectangle(cornerRadius: 1).frame(width: 3.5, height: 12)
                        RoundedRectangle(cornerRadius: 1).frame(width: 3.5, height: 16)
                        RoundedRectangle(cornerRadius: 1).frame(width: 3.5, height: 9)
                    }
                    .foregroundStyle(.orange)
                    .frame(width: indicatorSize, height: indicatorSize)
                } else if isCompleted {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: indicatorSize, height: indicatorSize)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else if isQueued {
                    if let pos = position {
                        Text("\(pos)")
                            .font(.system(size: 14, weight: .bold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: indicatorSize, height: indicatorSize)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                            .frame(width: indicatorSize, height: indicatorSize)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                        .frame(width: indicatorSize, height: indicatorSize)
                }
            }

            // Title
            Text(task.title)
                .font(.system(size: 17))
                .foregroundStyle(isCompleted ? .tertiary : .primary)
                .strikethrough(isCompleted, color: .secondary)
                .lineLimit(2)

            Spacer(minLength: 4)

            // Relative time
            if !isRunning {
                Text(task.createdAt, style: .relative)
                    .font(.system(size: 12))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - visionOS Content View

#if os(visionOS)
struct visionOSContentView: View {
    @Bindable var appState: AppState
    var viewModel: TodoViewModel
    @Binding var selectedHint: Hint?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedAgent: AgentSelection?
    @Binding var selectedContext: Context?

    @State private var selectedTab: VisionTab = .inbox

    enum VisionTab: String, CaseIterable {
        case inbox = "Inbox"
        case tasks = "Tasks"
        case skills = "Skills"
        case context = "Context"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .inbox: return "rectangle.stack"
            case .tasks: return "tray.fill"
            case .skills: return "sparkles"
            case .context: return "doc.text"
            case .settings: return "gear"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Inbox (Hints)
            NavigationSplitView {
                VisionHintList(selection: $selectedHint)
            } detail: {
                if let hint = selectedHint {
                    VisionHintDetailView(hint: hint)
                } else {
                    VisionEmptyState(
                        icon: "questionmark.bubble",
                        title: "Select a Question",
                        description: "Choose a question to respond"
                    )
                }
            }
            .tabItem {
                Label("Inbox", systemImage: "rectangle.stack")
            }
            .tag(VisionTab.inbox)

            // Tasks
            NavigationStack {
                VisionInboxList(viewModel: viewModel, selection: $selectedTask, appState: appState)
                    .navigationDestination(for: WorkTask.self) { task in
                        VisionTodoDetail(todo: task, viewModel: viewModel)
                    }
            }
            .tabItem {
                Label("Tasks", systemImage: "tray.fill")
            }
            .tag(VisionTab.tasks)

            // Skills
            NavigationSplitView {
                VisionSkillsList(selection: $selectedAgent)
            } detail: {
                if let agent = selectedAgent {
                    VisionAgentDetail(agent: agent)
                } else {
                    VisionEmptyState(
                        icon: "sparkles",
                        title: "Select a Skill",
                        description: "Choose a skill to edit its content"
                    )
                }
            }
            .tabItem {
                Label("Skills", systemImage: "sparkles")
            }
            .tag(VisionTab.skills)

            // Context
            NavigationSplitView {
                VisionContextList(selection: $selectedContext)
            } detail: {
                if let context = selectedContext {
                    VisionContextDetail(context: context)
                } else {
                    VisionEmptyState(
                        icon: "doc.text",
                        title: "Select a Context",
                        description: "Choose a context to edit its content"
                    )
                }
            }
            .tabItem {
                Label("Context", systemImage: "doc.text")
            }
            .tag(VisionTab.context)

            // Settings
            VisionSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(VisionTab.settings)
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
        }
    }
}

// MARK: - visionOS Inbox

struct VisionInboxList: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.priority) private var allTasks: [WorkTask]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]

    var viewModel: TodoViewModel
    @Binding var selection: WorkTask?
    @Bindable var appState: AppState
    @State private var filterWorkspaceId: UUID?
    @State private var syncService = SyncService.shared

    private var tasks: [WorkTask] {
        guard let filterWorkspaceId else { return allTasks }
        return allTasks.filter { $0.workspace?.id == filterWorkspaceId }
    }

    private var runningTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .running }.sorted { $0.priority < $1.priority }
    }

    private var queuedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .queued }.sorted { $0.priority < $1.priority }
    }

    private var completedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .completed }.sorted { $0.completedAt ?? $0.updatedAt > $1.completedAt ?? $1.updatedAt }
    }

    private var activeCount: Int {
        runningTasks.count + queuedTasks.count
    }

    private var allFilteredTasks: [WorkTask] {
        runningTasks + queuedTasks + completedTasks
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)

                Text("Tasks")
                    .font(.system(size: 24, weight: .bold))

                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                }

                Spacer()

                Button {
                    appState.isNewTaskPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
            .padding(.bottom, 20)

            // Workspace filter
            if !workspaces.isEmpty {
                WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)
            }

            if allFilteredTasks.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(.tertiary)
                    Text("No tasks yet")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Tap + to create a task")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if !runningTasks.isEmpty {
                            sectionHeader("Running")
                            ForEach(runningTasks, id: \.id) { task in
                                NavigationLink(value: task) {
                                    SlickTaskRow(task: task, position: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !queuedTasks.isEmpty {
                            if !runningTasks.isEmpty {
                                sectionHeader("Up Next")
                            }
                            ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { index, task in
                                NavigationLink(value: task) {
                                    SlickTaskRow(task: task, position: index + 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !completedTasks.isEmpty {
                            sectionHeader("Completed")
                            ForEach(completedTasks, id: \.id) { task in
                                NavigationLink(value: task) {
                                    SlickTaskRow(task: task, position: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(white: 27.0 / 255.0))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }
}

struct VisionTodoDetail: View {
    @Bindable var todo: WorkTask
    var viewModel: TodoViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var editedTitle: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Title
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Task", text: $editedTitle, axis: .vertical)
                        .font(.largeTitle.weight(.medium))
                        .onChange(of: editedTitle) { _, newValue in
                            // Only update if value actually changed
                            if todo.title != newValue {
                                todo.title = newValue
                            }
                        }

                    HStack(spacing: 24) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                            Text(todo.createdAt, style: .date)
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)

                        if todo.isCompleted, let completedAt = todo.completedAt {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark")
                                Text("Completed \(completedAt, style: .relative)")
                            }
                            .font(.title3)
                            .foregroundStyle(.green)
                        }
                    }
                }

                // Actions
                HStack(spacing: 20) {
                    Button {
                        Task {
                            await viewModel.toggleComplete(todo, context: modelContext)
                        }
                    } label: {
                        Label(
                            todo.isCompleted ? "Mark Active" : "Mark Complete",
                            systemImage: todo.isCompleted ? "circle" : "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(todo.isCompleted ? .secondary : .blue)

                    Button(role: .destructive) {
                        Task {
                            await viewModel.deleteTodo(todo, context: modelContext)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(40)
        }
        .navigationTitle("Task")
        .onAppear {
            editedTitle = todo.title
        }
    }
}

// MARK: - visionOS Skills

struct VisionSkillsList: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.updatedAt, order: .reverse) private var allSkills: [Skill]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @Binding var selection: AgentSelection?
    @State private var isCreating = false
    @State private var filterWorkspaceId: UUID?

    private var skills: [Skill] {
        guard let filterWorkspaceId else { return allSkills }
        return allSkills.filter { $0.workspace?.id == filterWorkspaceId }
    }

    var body: some View {
        List(selection: $selection) {
            if !workspaces.isEmpty {
                Section {
                    WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(skills) { skill in
                VisionSkillRow(skill: skill)
                    .tag(AgentSelection.skill(skill))
            }
            .onDelete(perform: deleteSkills)
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Label("Add Skill", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateSkillView(isPresented: $isCreating, onCreated: { skill in
                selection = .skill(skill)
            })
        }
        .overlay {
            if skills.isEmpty {
                ContentUnavailableView {
                    Label("No Skills", systemImage: "sparkles")
                } description: {
                    Text("Skills define what your agent can do")
                }
            }
        }
    }

    private func deleteSkills(at offsets: IndexSet) {
        for index in offsets {
            let skill = skills[index]
            if case .skill(let selected) = selection, selected == skill {
                selection = nil
            }
            modelContext.delete(skill)
        }
    }
}

struct VisionSkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.headline)

                Text(skill.updatedAt, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct VisionAgentDetail: View {
    let agent: AgentSelection

    var body: some View {
        switch agent {
        case .local(let file):
            VisionLocalAgentDetail(agent: file)
        case .skill(let skill):
            VisionSkillDetail(skill: skill)
        }
    }
}

struct VisionLocalAgentDetail: View {
    let agent: LocalAgentFile

    var body: some View {
        ScrollView {
            Text(agent.content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .navigationTitle(agent.name)
    }
}

struct VisionSkillDetail: View {
    @Bindable var skill: Skill
    @State private var editedContent: String = ""

    var body: some View {
        TextEditor(text: $editedContent)
            .font(.system(.body, design: .monospaced))
            .padding(24)
            .navigationTitle(skill.name)
            .onAppear {
                editedContent = skill.content
            }
            .onChange(of: editedContent) { _, newValue in
                skill.updateContent(newValue)
            }
    }
}

// MARK: - visionOS Context

struct VisionContextList: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Context.updatedAt, order: .reverse) private var allContexts: [Context]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @Binding var selection: Context?
    @State private var isCreating = false
    @State private var filterWorkspaceId: UUID?

    private var contexts: [Context] {
        guard let filterWorkspaceId else { return allContexts }
        return allContexts.filter { $0.workspace?.id == filterWorkspaceId }
    }

    var body: some View {
        List(selection: $selection) {
            if !workspaces.isEmpty {
                Section {
                    WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(contexts) { context in
                VisionContextRow(context: context)
                    .tag(context)
            }
            .onDelete(perform: deleteContexts)
        }
        .navigationTitle("Context")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreating = true
                } label: {
                    Label("Add Context", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateContextView(isPresented: $isCreating, selection: $selection)
        }
        .overlay {
            if contexts.isEmpty {
                ContentUnavailableView {
                    Label("No Context", systemImage: "doc.text")
                } description: {
                    Text("Context provides background for your agent")
                }
            }
        }
    }

    private func deleteContexts(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(contexts[index])
        }
    }
}

struct VisionContextRow: View {
    let context: Context

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.name)
                    .font(.headline)

                Text(context.updatedAt, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct VisionContextDetail: View {
    @Bindable var context: Context
    @State private var editedContent: String = ""

    var body: some View {
        TextEditor(text: $editedContent)
            .font(.system(.body, design: .monospaced))
            .padding(24)
            .navigationTitle(context.name)
            .onAppear {
                editedContent = context.content
            }
            .onChange(of: editedContent) { _, newValue in
                context.updateContent(newValue)
            }
    }
}

// MARK: - visionOS Settings

struct VisionSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var authService = AuthService.shared

    var body: some View {
        NavigationStack {
            List {
                // Account Section
                Section("Account") {
                    if authService.isAuthenticated {
                        if let user = authService.currentUser {
                            HStack(spacing: 16) {
                                AsyncImage(url: URL(string: user.userMetadata["avatar_url"]?.stringValue ?? "")) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.userMetadata["user_name"]?.stringValue ?? user.email ?? "User")
                                        .font(.headline)
                                    if let email = user.email {
                                        Text(email)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 8)

                            Button(role: .destructive) {
                                Task {
                                    await authService.signOut(clearingLocalData: modelContext)
                                }
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    } else {
                        Button {
                            Task {
                                await authService.signInWithGitHub()
                            }
                        } label: {
                            HStack {
                                Label("Sign in with GitHub", systemImage: "arrow.right.circle.fill")
                                Spacer()
                                if authService.isLoading {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(authService.isLoading)

                        Text("Sign in to sync your tasks, skills, and context across all your devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let error = authService.authError {
                        Text(error.localizedDescription)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section("Agent") {
                    NavigationLink {
                        Text("Agent Configuration")
                            .font(.title)
                    } label: {
                        Label("Agent Configuration", systemImage: "cpu")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Platform")
                        Spacer()
                        Text("visionOS")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - visionOS Empty State

struct VisionEmptyState: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.title.weight(.medium))
                .foregroundStyle(.secondary)

            Text(description)
                .font(.title3)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - visionOS Hints

struct VisionHintList: View {
    @Query(sort: \Hint.createdAt, order: .reverse) private var allHints: [Hint]
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]
    @Binding var selection: Hint?
    @State private var filterWorkspaceId: UUID?

    private var hints: [Hint] {
        guard let filterWorkspaceId else { return allHints }
        return allHints.filter { $0.task?.workspace?.id == filterWorkspaceId }
    }

    private var pendingHints: [Hint] {
        hints.filter { $0.hintStatus == .pending }
    }

    private var answeredHints: [Hint] {
        hints.filter { $0.hintStatus == .answered }
    }

    var body: some View {
        List(selection: $selection) {
            if !workspaces.isEmpty {
                Section {
                    WorkspaceFilterChips(workspaces: workspaces, selectedWorkspaceId: $filterWorkspaceId)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }

            if !pendingHints.isEmpty {
                Section("Pending") {
                    ForEach(pendingHints) { hint in
                        VisionHintRow(hint: hint)
                            .tag(hint)
                    }
                }
            }

            if !answeredHints.isEmpty {
                Section("Resolved") {
                    ForEach(answeredHints) { hint in
                        VisionHintRow(hint: hint)
                            .tag(hint)
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            if pendingHints.count > 0 {
                ToolbarItem(placement: .automatic) {
                    Text("\(pendingHints.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange)
                        .clipShape(Capsule())
                }
            }
        }
        .overlay {
            if hints.isEmpty {
                ContentUnavailableView {
                    Label("No Questions", systemImage: "questionmark.bubble")
                } description: {
                    Text("Questions from your agents will appear here")
                }
            }
        }
    }
}

struct VisionHintRow: View {
    let hint: Hint

    private var typeIcon: String {
        switch hint.hintType {
        case .exclusiveChoice: "circle.circle"
        case .multipleChoice: "checklist"
        case .textInput: "text.cursor"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: typeIcon)
                .font(.title2)
                .foregroundStyle(hint.hintStatus == .pending ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.title)
                    .font(.headline)
                    .foregroundStyle(hint.hintStatus == .pending ? .primary : .secondary)
                    .lineLimit(2)

                if let task = hint.task {
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if hint.hintStatus == .pending {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 8)
    }
}

struct VisionHintDetailView: View {
    @Bindable var hint: Hint
    @Environment(\.modelContext) private var modelContext
    @State private var selectedOption: String?
    @State private var selectedOptions: Set<String> = []
    @State private var textResponse: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text(hint.title)
                        .font(.largeTitle.weight(.medium))

                    if let description = hint.hintDescription, !description.isEmpty {
                        Text(description)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                            Text(hint.createdAt, style: .date)
                        }
                        .font(.title3)
                        .foregroundStyle(.secondary)

                        Text(hint.hintStatus == .pending ? "Pending" : "Resolved")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(hint.hintStatus == .pending ? .blue : .green)
                            .clipShape(Capsule())
                    }
                }

                Divider()

                // Response section
                if hint.hintStatus == .pending {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your Response")
                            .font(.title2.weight(.semibold))

                        responseContent
                    }

                    Button {
                        submitResponse()
                    } label: {
                        Label("Submit", systemImage: "paperplane.fill")
                            .font(.headline)
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your Response")
                            .font(.title2.weight(.semibold))

                        if let data = hint.responseData,
                           let response = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
                            Text(response.description)
                                .font(.title3)
                                .foregroundStyle(.green)
                        }

                        if let answeredAt = hint.answeredAt {
                            Text("Resolved \(answeredAt, style: .relative)")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(40)
        }
        .navigationTitle("Question")
    }

    @ViewBuilder
    private var responseContent: some View {
        switch hint.hintType {
        case .exclusiveChoice:
            if let options = hint.options {
                VStack(spacing: 8) {
                    ForEach(options, id: \.value) { option in
                        Button {
                            selectedOption = option.value
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedOption == option.value {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(selectedOption == option.value ? Color.blue.opacity(0.1) : Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .multipleChoice:
            if let options = hint.options {
                VStack(spacing: 8) {
                    ForEach(options, id: \.value) { option in
                        Button {
                            if selectedOptions.contains(option.value) {
                                selectedOptions.remove(option.value)
                            } else {
                                selectedOptions.insert(option.value)
                            }
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedOptions.contains(option.value) {
                                    Image(systemName: "checkmark.square.fill")
                                        .foregroundStyle(.blue)
                                } else {
                                    Image(systemName: "square")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(selectedOptions.contains(option.value) ? Color.blue.opacity(0.1) : Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .textInput:
            TextField("Enter your response", text: $textResponse, axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var canSubmit: Bool {
        switch hint.hintType {
        case .exclusiveChoice: selectedOption != nil
        case .multipleChoice: !selectedOptions.isEmpty
        case .textInput: !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submitResponse() {
        var response: Any
        switch hint.hintType {
        case .exclusiveChoice: response = selectedOption ?? ""
        case .multipleChoice: response = Array(selectedOptions)
        case .textInput: response = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = try? JSONEncoder().encode(AnyCodableValue(response)) {
            hint.responseData = data
        }
        hint.hintStatus = .answered
        hint.answeredAt = Date()

        // Trigger sync
        SyncService.shared.performFullSyncInBackground(container: modelContext.container)
    }
}
#endif
#endif

// MARK: - Workspace Header (Xcode style)

#if os(macOS)
struct WorkspaceHeaderView: View {
    @Binding var showTerminal: Bool
    @Environment(\.terminalSessionManager) private var sessionManager

    private let headerHeight: CGFloat = 35

    private var terminalsCount: Int {
        sessionManager.runningCount
    }

    // TODO: Replace with actual queue count
    private var queueCount: Int {
        0
    }

    var body: some View {
        HStack(spacing: 12) {
            // Terminals count
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                Text("\(terminalsCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(terminalsCount > 0 ? .green : .secondary)

            // Queue count
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 11))
                Text("\(queueCount)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(queueCount > 0 ? .green : .secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: headerHeight, alignment: .center)
    }
}

// Orb - the capsule container that holds pills
struct OrbView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 0)
            .padding(.bottom, 12)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.00))
                    .offset(y: 0)
            )
    }
}

// MARK: - Pills (inside Orb)

struct WorkspacePill: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

struct DestinationPill: View {
    let appName: String
    let destination: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "app.fill")
                .font(.system(size: 10))
            Text(appName)
                .font(.system(size: 11))
            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 10))
            Text(destination)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
#endif

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarSection?
    @Query private var hints: [Hint]
    @Query private var tasks: [WorkTask]
    @Query private var skills: [Skill]
    @Query private var contexts: [Context]
    @Query private var members: [OrganizationMember]
    var onNewTask: () -> Void
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
    @Environment(\.terminalSessionManager) private var sessionManager
    #endif

    private var pendingHintsCount: Int {
        hints.filter { $0.hintStatus == .pending }.count
    }

    private var answeredHintsCount: Int {
        hints.filter { $0.hintStatus == .answered }.count
    }

    private var queuedTasksCount: Int {
        tasks.filter { $0.taskStatus == .queued }.count
    }

    private var runningTasksCount: Int {
        tasks.filter { $0.taskStatus == .running }.count
    }

    #if os(macOS)
    private var runningCount: Int {
        sessionManager.runningCount
    }
    #else
    private var runningCount: Int {
        runningTasksCount
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Spacer()
                    .frame(height: 4)
                    .listRowSeparator(.hidden)

                // Inbox (Hints that need answers - RED = call to action / bottleneck)
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        if pendingHintsCount > 0 {
                            Text("\(pendingHintsCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red)
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.red, .secondary)
                }
                .tag(SidebarSection.inbox(.pending))

                // Indented sub-items for hints
                Label {
                    HStack {
                        Text("Resolved")
                        Spacer()
                        if answeredHintsCount > 0 {
                            Text("\(answeredHintsCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.inbox(.answered))

                // Tasks (BLUE)
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
                    Image(systemName: "tray.fill")
                        .foregroundStyle(.blue)
                }
                .tag(SidebarSection.queue(.queued))

                // Coding Agents
                Label {
                    HStack {
                        Text("Agents")
                        Spacer()
                        if runningTasksCount > 0 {
                            Text("\(runningTasksCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.green)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.queue(.running))

                // Coding Agents (root)
                Label {
                    Text("Agents")
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(.orange)
                }
                .listRowSeparator(.hidden)

                // Terminals (first under Coding Agents)
                Label {
                    HStack {
                        Text("Terminals")
                        Spacer()
                        if runningCount > 0 {
                            Text("\(runningCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: runningCount > 0 ? "terminal.fill" : "terminal")
                        .foregroundStyle(runningCount > 0 ? .green : .secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.terminals)

                // Skills (second under Coding Agents)
                Label {
                    HStack {
                        Text("Skills")
                        Spacer()
                        if !skills.isEmpty {
                            Text("\(skills.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.skills)

                // Context (third under Coding Agents)
                Label {
                    HStack {
                        Text("Context")
                        Spacer()
                        if !contexts.isEmpty {
                            Text("\(contexts.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.context)

                // Team (fourth under Coding Agents)
                Label {
                    HStack {
                        Text("Team")
                        Spacer()
                        if !members.isEmpty {
                            Text("\(members.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.team)

                #if os(macOS)
                // Show running sessions under Terminals
                ForEach(sessionManager.sessions) { session in
                    Label {
                        Text(session.taskTitle)
                            .lineLimit(1)
                    } icon: {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.leading, 32)
                    .font(.callout)
                    .listRowSeparator(.hidden)
                }
                #endif
            }
            .listStyle(.sidebar)
            #if os(macOS)
            .scrollContentBackground(.hidden)
            #endif

            Divider()

            // Account/Sync section
            HStack(spacing: 10) {
                if authService.isAuthenticated {
                    if let user = authService.currentUser {
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
                                await syncService.performFullSync(context: modelContext)
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
                } else {
                    Button {
                        Task {
                            await authService.signInWithGitHub()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle")
                                .font(.system(size: 20))
                            Text("Sign in to Sync")
                                .font(.callout)
                            Spacer()
                            if authService.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(authService.isLoading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Axel")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        #endif
    }
}


struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Hint Inbox View (Middle Column)

struct HintInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hint.createdAt, order: .reverse) private var hints: [Hint]

    let filter: HintFilter
    @Binding var selection: Hint?

    private var filteredHints: [Hint] {
        switch filter {
        case .pending: hints.filter { $0.hintStatus == .pending }
        case .answered: hints.filter { $0.hintStatus == .answered }
        case .all: hints
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header with filter name
            HStack {
                Text(filter == .pending ? "Inbox" : filter.rawValue)
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
            #endif

            if filteredHints.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHints) { hint in
                            HintRowView(hint: hint, isSelected: selection?.id == hint.id)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        selection = hint
                                    }
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }
            }
        }
        #if os(iOS)
        .navigationTitle(filter.rawValue)
        #else
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
        #endif
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(emptyDescription)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .pending: "No Blockers"
        case .answered: "No Resolved Items"
        case .all: "No Blockers"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .pending: "checkmark.seal"
        case .answered: "checkmark.circle"
        case .all: "checkmark.seal"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .pending: "All clear! AI agents will ask questions here when they need help."
        case .answered: "Questions you've answered will appear here"
        case .all: "No questions from AI agents yet"
        }
    }
}

struct HintRowView: View {
    let hint: Hint
    var isSelected: Bool = false

    private var typeIcon: String {
        switch hint.hintType {
        case .exclusiveChoice: "circle.circle"
        case .multipleChoice: "checklist"
        case .textInput: "text.cursor"
        }
    }

    private var typeColor: Color {
        switch hint.hintStatus {
        case .pending: .blue
        case .answered: .green
        case .cancelled: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Type indicator
            Image(systemName: typeIcon)
                .font(.title2)
                .foregroundStyle(typeColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(hint.hintStatus == .pending ? .primary : .secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let task = hint.task {
                        Text(task.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(hint.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Status badge
            if hint.hintStatus == .pending {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }
}

// MARK: - Hint Detail View

struct HintDetailView: View {
    @Bindable var hint: Hint
    @Environment(\.modelContext) private var modelContext
    @State private var selectedOption: String?
    @State private var selectedOptions: Set<String> = []
    @State private var textResponse: String = ""

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: hint.hintStatus == .pending ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(hint.hintStatus == .pending ? .blue : .green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.title)
                        .font(.headline)
                        .lineLimit(1)

                    if let task = hint.task {
                        Text("From: \(task.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if hint.hintStatus == .pending {
                    Text("Awaiting Response")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("Resolved")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Description
                    if let description = hint.hintDescription {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    // Response UI based on type
                    if hint.hintStatus == .pending {
                        responseUI
                    } else {
                        answeredUI
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
        .onAppear {
            loadExistingResponse()
        }
    }

    @ViewBuilder
    private var responseUI: some View {
        switch hint.hintType {
        case .exclusiveChoice:
            exclusiveChoiceUI
        case .multipleChoice:
            multipleChoiceUI
        case .textInput:
            textInputUI
        }
    }

    private var exclusiveChoiceUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select one option:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        selectedOption = option.value
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedOption == option.value ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selectedOption == option.value ? .blue : .secondary)

                            Text(option.label)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOption == option.value ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            submitButton
        }
    }

    private var multipleChoiceUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select all that apply:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        if selectedOptions.contains(option.value) {
                            selectedOptions.remove(option.value)
                        } else {
                            selectedOptions.insert(option.value)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedOptions.contains(option.value) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedOptions.contains(option.value) ? .blue : .secondary)

                            Text(option.label)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOptions.contains(option.value) ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            submitButton
        }
    }

    private var textInputUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your response:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            TextEditor(text: $textResponse)
                .font(.body)
                .frame(minHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            submitButton
        }
    }

    private var submitButton: some View {
        HStack {
            Spacer()

            Button {
                submitResponse()
            } label: {
                Label("Submit", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .padding(.top, 8)
    }

    private var canSubmit: Bool {
        switch hint.hintType {
        case .exclusiveChoice:
            return selectedOption != nil
        case .multipleChoice:
            return !selectedOptions.isEmpty
        case .textInput:
            return !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submitResponse() {
        var response: Any

        switch hint.hintType {
        case .exclusiveChoice:
            response = selectedOption ?? ""
        case .multipleChoice:
            response = Array(selectedOptions)
        case .textInput:
            response = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Encode response
        if let data = try? JSONEncoder().encode(AnyCodableValue(response)) {
            hint.responseData = data
        }

        hint.hintStatus = .answered
        hint.answeredAt = Date()
    }

    private func loadExistingResponse() {
        // Load any existing response for editing
    }

    @ViewBuilder
    private var answeredUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Response:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let data = hint.responseData,
               let response = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
                Text(response.description)
                    .font(.body)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
            }

            if let answeredAt = hint.answeredAt {
                Text("Resolved \(answeredAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// Helper for encoding/decoding responses
struct AnyCodableValue: Codable, CustomStringConvertible {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([String].self) {
            value = array
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [String] {
            try container.encode(array)
        }
    }

    var description: String {
        if let string = value as? String {
            return string
        } else if let array = value as? [String] {
            return array.joined(separator: ", ")
        }
        return String(describing: value)
    }
}

// MARK: - Empty Hint Selection View

struct EmptyHintSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "questionmark.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Question Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a question from the inbox to respond")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Task Detail View (Right Panel)

struct TaskDetailView: View {
    @Bindable var task: WorkTask
    let viewModel: TodoViewModel
    @Binding var showTerminal: Bool
    @Binding var selectedTask: WorkTask?
    var onStartTerminal: ((WorkTask) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var isPreviewingMarkdown: Bool = false
    @State private var syncService = SyncService.shared
    @State private var showDeleteConfirmation: Bool = false
    @FocusState private var isTitleFocused: Bool

    private var statusColor: Color {
        switch task.taskStatus {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private var statusIcon: String {
        switch task.taskStatus {
        case .queued: "clock.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .inReview: "eye.circle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(statusColor)

                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                // Status badge
                Text(task.taskStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Capsule())

                // Run in Terminal button
                if task.taskStatus == .queued {
                    Button {
                        onStartTerminal?(task)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Editable title
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Task title", text: $editedTitle, axis: .vertical)
                            .font(.title.weight(.medium))
                            .textFieldStyle(.plain)
                            .onChange(of: editedTitle) { _, newValue in
                                if task.title != newValue {
                                    task.title = newValue
                                }
                            }

                        // Description - using TextField instead of TextEditor to avoid hang
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Description")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                // Edit/Preview toggle
                                Picker("Mode", selection: $isPreviewingMarkdown) {
                                    Label("Edit", systemImage: "pencil")
                                        .tag(false)
                                    Label("Preview", systemImage: "eye")
                                        .tag(true)
                                }
                                .pickerStyle(.segmented)
                                .fixedSize()
                            }

                            if isPreviewingMarkdown {
                                // Markdown preview
                                ScrollView {
                                    if editedDescription.isEmpty {
                                        Text("No description")
                                            .foregroundStyle(.tertiary)
                                            .italic()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(LocalizedStringKey(editedDescription))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .frame(minHeight: 120)
                                .padding(12)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                            } else {
                                // Multi-line TextField instead of TextEditor (TextEditor causes hang)
                                TextField("Description", text: $editedDescription, axis: .vertical)
                                    .lineLimit(5...20)
                                    .font(.system(.body, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                    .onChange(of: editedDescription) { _, newValue in
                                        let newDesc = newValue.isEmpty ? nil : newValue
                                        if task.taskDescription != newDesc {
                                            task.updateDescription(newDesc)
                                        }
                                    }

                                // Markdown hints
                                HStack(spacing: 16) {
                                    Text("**bold**")
                                    Text("*italic*")
                                    Text("`code`")
                                    Text("[link](url)")
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }

                        // Created date
                        HStack {
                            Label {
                                Text("Created \(task.createdAt, style: .relative)")
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            if task.taskStatus == .completed, let completedAt = task.completedAt {
                                Label {
                                    Text("Completed \(completedAt, style: .relative)")
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                                .font(.callout)
                                .foregroundStyle(.green)
                            }
                        }
                    }

                    // Status Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Status")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(TaskStatus.allCases, id: \.self) { status in
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if status == .completed {
                                            task.markCompleted()
                                            selectedTask = nil
                                        } else {
                                            task.updateStatus(status)
                                        }
                                    }
                                    Task {
                                        await syncService.performFullSync(context: modelContext)
                                    }
                                } label: {
                                    Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(task.taskStatus == status ? statusColorFor(status) : .secondary)
                            }
                        }
                    }

                    Divider()

                    // Delete
                    HStack {
                        Spacer()

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Task", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(task.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(.background)
        .alert("Delete Task", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteTodo(task, context: modelContext)
                    selectedTask = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(task.title)\"? This action cannot be undone.")
        }
        .onAppear {
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.id) { _, _ in
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.title) { _, newTitle in
            if editedTitle != newTitle {
                editedTitle = newTitle
            }
        }
        .onChange(of: task.taskDescription) { _, newDescription in
            let newValue = newDescription ?? ""
            if editedDescription != newValue {
                editedDescription = newValue
            }
        }
        .onDisappear {
            Task {
                await SyncService.shared.performFullSync(context: modelContext)
            }
        }
    }

    /* NOTE: TextEditor was replaced with TextField(axis: .vertical) because TextEditor
       causes the app to hang when used in this view hierarchy. This appears to be a SwiftUI bug. */

    private func statusColorFor(_ status: TaskStatus) -> Color {
        switch status {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }
}

// MARK: - Empty Task Selection View

struct EmptyTaskSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "square.stack")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Task Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a task from the queue to view details")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Create Task View

struct CreateTaskView: View {
    @Binding var isPresented: Bool
    var workspace: Workspace?
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(iOS)
        NavigationStack {
            createTaskContent
                .navigationTitle("New Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            createTask()
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #else
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

                Text("Press ⏎ to save")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                Button("Save") {
                    createTask()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 480, height: 180)
        .background(.background)
        .onAppear {
            isFocused = true
        }
        #endif
    }

    #if os(iOS)
    private var createTaskContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 4)

                TextField("What needs to be done?", text: $title, axis: .vertical)
                    .font(.title3)
                    .focused($isFocused)
            }
            .padding()

            Spacer()
        }
        .onAppear {
            isFocused = true
        }
    }
    #endif

    private func createTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority: Int
        if let workspace {
            maxPriority = workspace.tasks
                .filter { $0.taskStatus == .queued }
                .map { $0.priority }
                .max() ?? 0
        } else {
            // No workspace filter - check all tasks
            let descriptor = FetchDescriptor<WorkTask>(
                predicate: #Predicate { $0.status == "queued" }
            )
            let existingTasks = (try? modelContext.fetch(descriptor)) ?? []
            maxPriority = existingTasks.map { $0.priority }.max() ?? 0
        }

        let todo = WorkTask(title: trimmedTitle)
        todo.workspace = workspace
        todo.priority = maxPriority + 50  // New tasks go to bottom of queue
        modelContext.insert(todo)
        isPresented = false

        // Sync to push the new task to Supabase
        Task {
            await SyncService.shared.performFullSync(context: modelContext)
        }
    }
}

// MARK: - Queue Views (Tasks List)

struct QueueListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.createdAt, order: .reverse) private var tasks: [WorkTask]

    let filter: TaskFilter
    @Binding var selection: WorkTask?
    var onNewTask: () -> Void

    private var filteredTasks: [WorkTask] {
        switch filter {
        case .queued: tasks.filter { $0.taskStatus == .queued }
        case .running: tasks.filter { $0.taskStatus == .running }
        case .completed: tasks.filter { $0.taskStatus == .completed }
        case .all: tasks
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

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack {
                Text(headerTitle)
                    .font(.title2.bold())
                Spacer()
                Text("\(filteredTasks.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #endif

            if filteredTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTasks) { task in
                            TaskRowView(task: task, isSelected: selection?.id == task.id)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        selection = task
                                    }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: filteredTasks.map(\.id))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
        #endif
        .background(.background)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewTask) {
                    Image(systemName: "plus")
                }
            }
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(emptyDescription)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button(action: onNewTask) {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .queued: "No Tasks"
        case .running: "Nothing Coding Agents"
        case .completed: "No Completed Tasks"
        case .all: "No Tasks"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .queued: "tray"
        case .running: "terminal"
        case .completed: "checkmark.circle"
        case .all: "tray"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .queued: "Create a task to get started"
        case .running: "Start a task to see it here"
        case .completed: "Complete a task to see it here"
        case .all: "Create your first task"
        }
    }
}

struct TaskRowView: View {
    let task: WorkTask
    var isSelected: Bool = false

    private var statusColor: Color {
        switch task.taskStatus {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private var statusIcon: String {
        switch task.taskStatus {
        case .queued: "clock.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .inReview: "eye.circle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Status indicator
            Image(systemName: statusIcon)
                .font(.title2)
                .frame(width: 24, height: 24)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(task.taskStatus == .completed ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(task.taskStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    Text(task.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Priority indicator
            if task.priority > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }
}

// MARK: - Window Drag Area (macOS only)

#if os(macOS)
struct WindowDragArea: NSViewRepresentable {
    typealias NSViewType = NSView
    typealias Coordinator = Void

    @MainActor @preconcurrency
    func makeNSView(context: NSViewRepresentableContext<WindowDragArea>) -> NSView {
        let view = DraggableView()
        view.wantsLayer = true
        return view
    }

    @MainActor @preconcurrency
    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<WindowDragArea>) {}
}

class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
#endif

// MARK: - Previews

#Preview {
    ContentView(appState: AppState())
        .modelContainer(PreviewContainer.shared.container)
}

#Preview("Create Task") {
    CreateTaskView(isPresented: .constant(true))
        .modelContainer(PreviewContainer.shared.container)
}
