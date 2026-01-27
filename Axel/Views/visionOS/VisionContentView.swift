import SwiftUI
import SwiftData

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
            case .inbox: return "tray.fill"
            case .tasks: return "rectangle.stack"
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
                Label("Inbox", systemImage: "tray.fill")
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
                Label("Tasks", systemImage: "rectangle.stack")
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
            VisionSettingsView(appState: appState)
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
                Image(systemName: "rectangle.stack")
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
    @State private var editedDescription: String = ""
    @State private var isPreviewingMarkdown: Bool = false

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
                                todo.updateTitle(newValue)
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

                // Notes/Description
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Notes")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Picker("Mode", selection: $isPreviewingMarkdown) {
                            Text("Edit").tag(false)
                            Text("Preview").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    if isPreviewingMarkdown {
                        // Markdown preview
                        if editedDescription.isEmpty {
                            Text("No notes")
                                .foregroundStyle(.tertiary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        } else {
                            Text(LocalizedStringKey(editedDescription))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    } else {
                        // Edit mode
                        TextField("Add notes...", text: $editedDescription, axis: .vertical)
                            .lineLimit(5...20)
                            .font(.body)
                            .padding(16)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onChange(of: editedDescription) { _, newValue in
                                let newDesc = newValue.isEmpty ? nil : newValue
                                if todo.taskDescription != newDesc {
                                    todo.updateDescription(newDesc)
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
            editedDescription = todo.taskDescription ?? ""
        }
        .onChange(of: todo.id) { _, _ in
            editedTitle = todo.title
            editedDescription = todo.taskDescription ?? ""
        }
        .onChange(of: todo.title) { _, newTitle in
            if editedTitle != newTitle {
                editedTitle = newTitle
            }
        }
        .onChange(of: todo.taskDescription) { _, newDescription in
            let newValue = newDescription ?? ""
            if editedDescription != newValue {
                editedDescription = newValue
            }
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
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var authService = AuthService.shared
    var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                // Command Center Section
                Section("Command Center") {
                    Button {
                        Task {
                            await toggleImmersiveSpace()
                        }
                    } label: {
                        HStack {
                            Label(
                                appState.immersionState == .open ? "Exit Command Center" : "Enter Command Center",
                                systemImage: appState.immersionState == .open ? "xmark.circle" : "visionpro"
                            )
                            Spacer()
                            if appState.immersionState == .inTransition {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(appState.immersionState == .inTransition)

                    Text("Launch your curved ultrawide display with Tasks, Skills, and Inbox in deep space.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

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

    @MainActor
    private func toggleImmersiveSpace() async {
        switch appState.immersionState {
        case .open:
            appState.immersionState = .inTransition
            await dismissImmersiveSpace()
            appState.immersionState = .closed

        case .closed:
            appState.immersionState = .inTransition
            let result = await openImmersiveSpace(id: "ImmersiveSpace")
            switch result {
            case .opened:
                appState.immersionState = .open
            case .error, .userCancelled:
                appState.immersionState = .closed
            @unknown default:
                appState.immersionState = .closed
            }

        case .inTransition:
            break
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
