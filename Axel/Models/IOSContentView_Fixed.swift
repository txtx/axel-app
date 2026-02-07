import SwiftUI
import SwiftData

#if os(iOS) || os(visionOS)

// MARK: - Clean iOS Content View

struct iOSContentView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    var viewModel: TaskViewModel
    @Binding var sidebarSelection: SidebarSection?
    @Binding var selectedHint: Hint?
    @Binding var selectedTask: WorkTask?
    @Binding var selectedAgent: Skill?
    @Binding var selectedContext: Context?
    @Binding var selectedTeamMember: OrganizationMember?
    @Binding var showTerminal: Bool
    
    @State private var selectedWorkspace: Workspace?
    @Query(sort: \Workspace.updatedAt, order: .reverse) private var workspaces: [Workspace]

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(visionOS)
        // visionOS - Simple content
        VStack {
            Text("visionOS Content")
                .foregroundStyle(.secondary)
            Text("Coming Soon")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        #else
        if horizontalSizeClass == .compact {
            // iPhone - Tab-based navigation
            TabView {
                // Tasks Tab
                NavigationStack {
                    TaskListView()
                        .navigationTitle("Tasks")
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button {
                                    appState.isNewTaskPresented = true
                                } label: {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                }
                .tabItem {
                    Label("Tasks", systemImage: "list.bullet")
                }
                
                // Inbox Tab
                NavigationStack {
                    InboxListView()
                        .navigationTitle("Inbox")
                }
                .tabItem {
                    Label("Inbox", systemImage: "tray")
                }
                
                // Settings Tab
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                }
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
            }
        } else {
            // iPad - Split view navigation  
            NavigationSplitView {
                SidebarListView(selection: $sidebarSelection)
            } content: {
                ContentColumnView(selection: sidebarSelection)
            } detail: {
                DetailColumnView(
                    selection: sidebarSelection,
                    selectedTask: selectedTask,
                    selectedHint: selectedHint,
                    selectedContext: selectedContext
                )
            }
        }
        #endif
        
        // Common modifiers
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
        }
        .task {
            // Select first workspace if none selected
            if selectedWorkspace == nil, let first = workspaces.first {
                selectedWorkspace = first
            }
        }
    }
}

// MARK: - Task List View

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.priority) private var tasks: [WorkTask]

    var body: some View {
        List {
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "tray")
                } description: {
                    Text("Create a task to get started")
                }
            } else {
                ForEach(tasks) { task in
                    TaskRowView(task: task)
                }
                .onDelete(perform: deleteTasks)
            }
        }
    }
    
    private func deleteTasks(at offsets: IndexSet) {
        for index in offsets {
            let task = tasks[index]
            task.prepareForDeletion()
            modelContext.delete(task)
        }
    }
}

// MARK: - Task Row View

struct TaskRowView: View {
    @Bindable var task: WorkTask
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack {
            Button {
                task.toggleComplete()
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                
                if let description = task.taskDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                HStack {
                    Text(task.taskStatus.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor(for: task.taskStatus))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    
                    Spacer()
                    
                    Text(task.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
    
    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .backlog: .blue
        case .queued: .orange
        case .running: .green
        case .completed: .gray
        case .inReview: .purple
        case .aborted: .red
        }
    }
}

// MARK: - Inbox List View

struct InboxListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Hint> { hint in
            hint.hintStatus == .pending
        },
        sort: \Hint.createdAt,
        order: .reverse
    ) private var pendingHints: [Hint]

    var body: some View {
        List {
            if pendingHints.isEmpty {
                ContentUnavailableView {
                    Label("No Questions", systemImage: "checkmark.seal")
                } description: {
                    Text("All clear! AI agents will ask questions here when they need help.")
                }
            } else {
                ForEach(pendingHints) { hint in
                    HintRowView(hint: hint)
                }
            }
        }
    }
}

// MARK: - Hint Row View

struct HintRowView: View {
    @Bindable var hint: Hint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hint.title)
                .font(.body)
                .foregroundStyle(.primary)
            
            if let description = hint.hintDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            
            if let task = hint.task {
                Text("Task: \(task.title)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            
            HStack {
                Text(hint.hintType.rawValue.capitalized)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                
                Spacer()
                
                Text(hint.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Workspace.name) private var workspaces: [Workspace]

    var body: some View {
        List {
            Section("Workspaces") {
                if workspaces.isEmpty {
                    Text("No workspaces")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workspaces) { workspace in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name)
                                .font(.body)
                            if let path = workspace.path {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
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
    }
}

// MARK: - Sidebar List View (iPad)

struct SidebarListView: View {
    @Binding var selection: SidebarSection?
    
    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: SidebarSection.queue(.backlog)) {
                Label("Tasks", systemImage: "list.bullet")
            }
            
            NavigationLink(value: SidebarSection.inbox(.pending)) {
                Label("Inbox", systemImage: "tray")
            }
            
            NavigationLink(value: SidebarSection.optimizations(.skills)) {
                Label("Skills", systemImage: "hammer")
            }
            
            NavigationLink(value: SidebarSection.optimizations(.context)) {
                Label("Context", systemImage: "doc.text")
            }
        }
        .navigationTitle("Axel")
    }
}

// MARK: - Content Column View (iPad)

struct ContentColumnView: View {
    let selection: SidebarSection?
    
    var body: some View {
        Group {
            switch selection {
            case .queue:
                TaskListView()
                    .navigationTitle("Tasks")
            case .inbox:
                InboxListView()
                    .navigationTitle("Inbox")
            case .optimizations(.skills):
                SkillsListView()
                    .navigationTitle("Skills")
            case .optimizations(.context):
                ContextListView()
                    .navigationTitle("Context")
            default:
                ContentUnavailableView {
                    Label("Select Section", systemImage: "sidebar.left")
                } description: {
                    Text("Choose a section from the sidebar")
                }
            }
        }
    }
}

// MARK: - Detail Column View (iPad)

struct DetailColumnView: View {
    let selection: SidebarSection?
    let selectedTask: WorkTask?
    let selectedHint: Hint?
    let selectedContext: Context?
    
    var body: some View {
        Group {
            if let task = selectedTask {
                TaskDetailView(task: task)
            } else if let hint = selectedHint {
                HintDetailView(hint: hint)
            } else if let context = selectedContext {
                ContextDetailView(context: context)
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "doc")
                } description: {
                    Text("Select an item to view details")
                }
            }
        }
    }
}

// MARK: - Skills List View

struct SkillsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.name) private var skills: [Skill]

    var body: some View {
        List {
            if skills.isEmpty {
                ContentUnavailableView {
                    Label("No Skills", systemImage: "sparkles")
                } description: {
                    Text("Skills define what your agent can do")
                }
            } else {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name)
                            .font(.body)
                        Text(skill.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Context List View

struct ContextListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Context.name) private var contexts: [Context]

    var body: some View {
        List {
            if contexts.isEmpty {
                ContentUnavailableView {
                    Label("No Context", systemImage: "doc.text")
                } description: {
                    Text("Context provides background for your agent")
                }
            } else {
                ForEach(contexts) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.name)
                            .font(.body)
                        Text(context.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Create Task View

struct CreateTaskView: View {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var modelContext
    @State private var title: String = ""
    @State private var description: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Task Details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createTask()
                        isPresented = false
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
    
    private func createTask() {
        let task = WorkTask(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        )
        modelContext.insert(task)
    }
}

// MARK: - Task Detail View

struct TaskDetailView: View {
    @Bindable var task: WorkTask

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(task.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                if let description = task.taskDescription {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text(task.taskStatus.displayName)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(statusColor(for: task.taskStatus))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)
                    
                    HStack {
                        Text("Created:")
                        Spacer()
                        Text(task.createdAt, style: .date)
                            .foregroundStyle(.secondary)
                    }
                    
                    HStack {
                        Text("Updated:")
                        Spacer()
                        Text(task.updatedAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let completedAt = task.completedAt {
                        HStack {
                            Text("Completed:")
                            Spacer()
                            Text(completedAt, style: .date)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .backlog: .blue
        case .queued: .orange
        case .running: .green
        case .completed: .gray
        case .inReview: .purple
        case .aborted: .red
        }
    }
}

// MARK: - Hint Detail View

struct HintDetailView: View {
    @Bindable var hint: Hint

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(hint.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                if let description = hint.hintDescription {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                
                if let task = hint.task {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Related Task")
                            .font(.headline)
                        Text(task.title)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Question")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Context Detail View

struct ContextDetailView: View {
    @Bindable var context: Context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(context.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text(context.content)
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding()
        }
        .navigationTitle("Context")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Task View Model

struct TaskViewModel {
    func deleteTodo(_ task: WorkTask, context: ModelContext) async {
        await MainActor.run {
            task.prepareForDeletion()
            context.delete(task)
        }
    }
}

#endif