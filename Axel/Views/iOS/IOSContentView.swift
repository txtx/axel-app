import SwiftUI
import SwiftData

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

#endif
