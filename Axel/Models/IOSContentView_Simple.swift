import SwiftUI
import SwiftData

#if os(iOS) || os(visionOS)

// MARK: - Simple iOS Content View

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
    
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @State private var selectedWorkspace: Workspace?
    @Query(sort: \Workspace.updatedAt, order: .reverse) private var workspaces: [Workspace]

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
        #if os(visionOS)
        // visionOS - Simple content for now
        Text("visionOS Content")
            .foregroundStyle(.secondary)
            .task {
                performSync()
            }
        #else
        if horizontalSizeClass == .compact {
            // iPhone - Use our custom tab view
            iPhoneSimpleTabView()
        } else {
            // iPad - Use the same interface as iPhone for now
            iPhoneSimpleTabView()
        }
        #endif
    }
    
    private func iPhoneSimpleTabView() -> some View {
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
                .sheet(isPresented: $appState.isNewTaskPresented) {
                    SimpleCreateTaskView(isPresented: $appState.isNewTaskPresented)
                }
        }
        .task {
            performSync()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                performSync()
            }
        }
    }
}

// MARK: - Simple Task List View

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.priority) private var tasks: [WorkTask]
    @State private var syncService = SyncService.shared

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
        .refreshable {
            syncService.performFullSyncInBackground(container: modelContext.container)
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

// MARK: - Simple Task Row View

struct TaskRowView: View {
    @Bindable var task: WorkTask
    @State private var syncService = SyncService.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack {
            Button {
                task.toggleComplete()
                syncService.performFullSyncInBackground(container: modelContext.container)
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

// MARK: - Simple Create Task View

struct SimpleCreateTaskView: View {
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

// MARK: - Simple Task View Model

struct TaskViewModel {
    func deleteTodo(_ task: WorkTask, context: ModelContext) async {
        await MainActor.run {
            task.prepareForDeletion()
            context.delete(task)
        }
    }
}

#endif