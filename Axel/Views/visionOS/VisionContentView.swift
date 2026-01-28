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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Query(sort: \Workspace.updatedAt, order: .reverse) private var workspaces: [Workspace]

    @State private var selectedSection: SidebarSection? = .queue(.queued)
    @State private var selectedInboxEvent: InboxEvent?
    @State private var selectedMember: OrganizationMember?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Currently selected workspace for filtering
    @State private var selectedWorkspace: Workspace?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VisionSidebarView(
                selection: $selectedSection,
                workspaces: workspaces,
                selectedWorkspace: $selectedWorkspace
            )
            .navigationTitle("Axel")
        } content: {
            contentView
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .ornament(attachmentAnchor: .scene(.top)) {
            VisionStatusOrnament(appState: appState)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VisionQuickActionsOrnament(
                appState: appState,
                onToggleImmersive: toggleImmersiveSpace
            )
        }
        .sheet(isPresented: $appState.isNewTaskPresented) {
            CreateTaskView(isPresented: $appState.isNewTaskPresented)
        }
    }

    // MARK: - Content Column

    @ViewBuilder
    private var contentView: some View {
        switch selectedSection {
        case .queue:
            VisionTaskListView(
                workspace: selectedWorkspace,
                selection: $selectedTask,
                appState: appState
            )
        case .terminals:
            VisionAgentsListView(
                workspace: selectedWorkspace
            )
        case .inbox:
            VisionInboxListView(
                workspace: selectedWorkspace,
                selection: $selectedInboxEvent
            )
        case .optimizations(let filter):
            switch filter {
            case .overview:
                VisionOptimizationsOverview(workspace: selectedWorkspace)
            case .skills:
                VisionSkillsList(selection: $selectedAgent)
            case .context:
                VisionContextList(selection: $selectedContext)
            }
        case .team:
            VisionTeamListView(selection: $selectedMember)
        case .none:
            VisionEmptyState(
                icon: "sidebar.squares.leading",
                title: "Select a Section",
                description: "Choose a section from the sidebar"
            )
        }
    }

    // MARK: - Detail Column

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .queue:
            if let task = selectedTask {
                VisionTodoDetail(todo: task, viewModel: viewModel)
            } else {
                VisionEmptyState(
                    icon: "rectangle.stack",
                    title: "Select a Task",
                    description: "Choose a task to view details"
                )
            }
        case .terminals:
            VisionAgentDetailPlaceholder()
        case .inbox:
            if let event = selectedInboxEvent {
                VisionInboxEventDetail(event: event)
            } else {
                VisionEmptyState(
                    icon: "tray.fill",
                    title: "Select an Event",
                    description: "Choose an inbox event to view details"
                )
            }
        case .optimizations(let filter):
            switch filter {
            case .overview:
                VisionOptimizationsDetailPlaceholder()
            case .skills:
                if let agent = selectedAgent {
                    VisionAgentDetail(agent: agent)
                } else {
                    VisionEmptyState(
                        icon: "hammer.fill",
                        title: "Select a Skill",
                        description: "Choose a skill to edit"
                    )
                }
            case .context:
                if let context = selectedContext {
                    VisionContextDetail(context: context)
                } else {
                    VisionEmptyState(
                        icon: "briefcase.fill",
                        title: "Select a Context",
                        description: "Choose a context to edit"
                    )
                }
            }
        case .team:
            if let member = selectedMember {
                VisionTeamMemberDetail(member: member)
            } else {
                VisionEmptyState(
                    icon: "person.2",
                    title: "Select a Member",
                    description: "Choose a team member to view profile"
                )
            }
        case .none:
            VisionEmptyState(
                icon: "sidebar.squares.trailing",
                title: "No Selection",
                description: "Select an item to see details"
            )
        }
    }

    // MARK: - Immersive Space

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

// MARK: - Vision Sidebar View

struct VisionSidebarView: View {
    @Binding var selection: SidebarSection?
    let workspaces: [Workspace]
    @Binding var selectedWorkspace: Workspace?
    @State private var inboxService = InboxService.shared

    var body: some View {
        List(selection: $selection) {
            // Workspace Filter
            if workspaces.count > 1 {
                Section("Workspace") {
                    Picker("Workspace", selection: $selectedWorkspace) {
                        Text("All Workspaces").tag(nil as Workspace?)
                        ForEach(workspaces) { workspace in
                            Text(workspace.name).tag(workspace as Workspace?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            Section("Work") {
                // Tasks
                Label {
                    Text("Tasks")
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.blue)
                }
                .tag(SidebarSection.queue(.queued))

                // Agents
                Label {
                    Text("Agents")
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.orange)
                }
                .tag(SidebarSection.terminals)
            }

            Section("Communication") {
                // Inbox
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        Circle()
                            .fill(inboxService.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                    }
                } icon: {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(.pink)
                }
                .tag(SidebarSection.inbox(.pending))

                // Resolved
                Label {
                    Text("Resolved")
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .tag(SidebarSection.inbox(.answered))
            }

            Section("Optimizations") {
                // Overview
                Label {
                    Text("Overview")
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(.purple)
                }
                .tag(SidebarSection.optimizations(.overview))

                // Skills
                Label {
                    Text("Skills")
                } icon: {
                    Image(systemName: "hammer.fill")
                        .foregroundStyle(.white)
                }
                .tag(SidebarSection.optimizations(.skills))

                // Context
                Label {
                    Text("Context")
                } icon: {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(.white)
                }
                .tag(SidebarSection.optimizations(.context))
            }

            Section("Organization") {
                // Team
                Label {
                    Text("Team")
                } icon: {
                    Image(systemName: "person.2")
                        .foregroundStyle(.cyan)
                }
                .tag(SidebarSection.team)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Status Ornament

struct VisionStatusOrnament: View {
    @Bindable var appState: AppState
    @State private var costTracker = CostTracker.shared
    @State private var authService = AuthService.shared

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

    private var histogramValues: [Double] {
        costTracker.globalHistogramValues
    }

    var body: some View {
        HStack(spacing: 20) {
            // Histogram
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Color.orange.gradient)
                        .frame(width: 6, height: 4 + CGFloat(value) * 16)
                }
            }
            .frame(height: 24)

            // Token count
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.orange)
                Text(formattedTokenCount)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
            }

            // Cost
            if totalCost > 0 {
                Text(String(format: "$%.2f", totalCost))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()
                .frame(height: 20)

            // User
            if let user = authService.currentUser {
                HStack(spacing: 8) {
                    AsyncImage(url: URL(string: user.userMetadata["avatar_url"]?.stringValue ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())

                    Text(user.userMetadata["user_name"]?.stringValue ?? "User")
                        .font(.system(size: 13))
                }
            } else {
                Label("Sign In", systemImage: "person.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}

// MARK: - Quick Actions Ornament

struct VisionQuickActionsOrnament: View {
    @Bindable var appState: AppState
    let onToggleImmersive: () async -> Void

    var body: some View {
        HStack(spacing: 16) {
            // New Task
            Button {
                appState.isNewTaskPresented = true
            } label: {
                Label("New Task", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)

            // Command Center
            Button {
                Task {
                    await onToggleImmersive()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.immersionState == .open ? "xmark.circle" : "visionpro")
                    Text(appState.immersionState == .open ? "Exit Command Center" : "Command Center")
                }
                .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.immersionState == .open ? .red : .blue)
            .disabled(appState.immersionState == .inTransition)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
}

// MARK: - Task List View

struct VisionTaskListView: View {
    let workspace: Workspace?
    @Binding var selection: WorkTask?
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.priority) private var allTasks: [WorkTask]

    private var tasks: [WorkTask] {
        guard let workspace else { return allTasks }
        return allTasks.filter { $0.workspace?.id == workspace.id }
    }

    private var runningTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .running }.sorted { $0.priority < $1.priority }
    }

    private var queuedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .queued }.sorted { $0.priority < $1.priority }
    }

    private var completedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .completed }.sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    var body: some View {
        List(selection: $selection) {
            if !runningTasks.isEmpty {
                Section("Running") {
                    ForEach(runningTasks) { task in
                        VisionTaskRow(task: task)
                            .tag(task)
                    }
                }
            }

            if !queuedTasks.isEmpty {
                Section("Up Next") {
                    ForEach(Array(queuedTasks.enumerated()), id: \.element.id) { index, task in
                        VisionTaskRow(task: task, position: index + 1)
                            .tag(task)
                    }
                }
            }

            if !completedTasks.isEmpty {
                Section("Completed") {
                    ForEach(completedTasks) { task in
                        VisionTaskRow(task: task)
                            .tag(task)
                    }
                }
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.isNewTaskPresented = true
                } label: {
                    Label("New Task", systemImage: "plus")
                }
            }
        }
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView {
                    Label("No Tasks", systemImage: "rectangle.stack")
                } description: {
                    Text("Create a task to get started")
                } actions: {
                    Button("Create Task") {
                        appState.isNewTaskPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct VisionTaskRow: View {
    let task: WorkTask
    var position: Int? = nil

    private var statusColor: Color {
        switch task.taskStatus {
        case .running: return .green
        case .queued: return .blue
        case .completed: return .secondary
        case .inReview: return .orange
        case .aborted: return .red
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Position or Status indicator
            if let position {
                Text("\(position)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else if task.taskStatus == .running {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            } else {
                Image(systemName: task.taskStatus == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(statusColor)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(task.taskStatus == .completed ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let workspace = task.workspace {
                        Text(workspace.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Text(task.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Agents List View

struct VisionAgentsListView: View {
    let workspace: Workspace?
    @Query(sort: \Terminal.createdAt, order: .reverse) private var allTerminals: [Terminal]

    private var terminals: [Terminal] {
        let active = allTerminals.filter { $0.terminalStatus == .running }
        guard let workspace else { return active }
        return active.filter { $0.workspace?.id == workspace.id }
    }

    var body: some View {
        List {
            if terminals.isEmpty {
                ContentUnavailableView {
                    Label("No Active Agents", systemImage: "terminal")
                } description: {
                    Text("Start a task to create an agent")
                }
            } else {
                ForEach(terminals) { terminal in
                    VisionAgentRow(terminal: terminal)
                }
            }
        }
        .navigationTitle("Agents")
    }
}

struct VisionAgentRow: View {
    let terminal: Terminal

    private var statusColor: Color {
        switch terminal.terminalStatus {
        case .running: return .green
        case .paused: return .yellow
        case .completed: return .secondary
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .overlay {
                    if terminal.terminalStatus == .running {
                        Circle()
                            .stroke(statusColor.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1.5)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(terminal.name ?? terminal.paneId ?? "Agent")
                    .font(.headline)

                if let task = terminal.task {
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    if let startedAt = terminal.startedAt {
                        Text("Started \(startedAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Image(systemName: "terminal")
                .font(.title2)
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 8)
    }
}

struct VisionAgentDetailPlaceholder: View {
    var body: some View {
        VisionEmptyState(
            icon: "terminal",
            title: "Agent Terminal",
            description: "Terminal view coming to visionOS"
        )
    }
}

// MARK: - Inbox List View

struct VisionInboxListView: View {
    let workspace: Workspace?
    @Binding var selection: InboxEvent?
    @Query(sort: \InboxEvent.timestamp, order: .reverse) private var allEvents: [InboxEvent]

    private var events: [InboxEvent] {
        // Filter by workspace if selected
        guard let workspace else { return allEvents }
        return allEvents.filter { event in
            event.terminal?.workspace?.id == workspace.id
        }
    }

    private var unresolvedEvents: [InboxEvent] {
        events.filter { !$0.isResolved }
    }

    private var resolvedEvents: [InboxEvent] {
        events.filter { $0.isResolved }
    }

    var body: some View {
        List(selection: $selection) {
            if !unresolvedEvents.isEmpty {
                Section("Pending") {
                    ForEach(unresolvedEvents) { event in
                        VisionInboxEventRow(event: event)
                            .tag(event)
                    }
                }
            }

            if !resolvedEvents.isEmpty {
                Section("Resolved") {
                    ForEach(resolvedEvents.prefix(20)) { event in
                        VisionInboxEventRow(event: event)
                            .tag(event)
                    }
                }
            }
        }
        .navigationTitle("Inbox")
        .overlay {
            if events.isEmpty {
                ContentUnavailableView {
                    Label("No Events", systemImage: "tray")
                } description: {
                    Text("Agent activity will appear here")
                }
            }
        }
    }
}

struct VisionInboxEventRow: View {
    let event: InboxEvent

    private var typeIcon: String {
        switch event.eventType {
        case .toolUse: return "hammer"
        case .toolResult: return "checkmark.circle"
        case .permission: return "lock.shield"
        case .hint: return "questionmark.bubble"
        case .taskStart: return "play.circle"
        case .taskStop: return "stop.circle"
        case .taskMetrics: return "chart.bar"
        case .unknown: return "questionmark"
        }
    }

    private var typeColor: Color {
        switch event.eventType {
        case .toolUse: return .blue
        case .toolResult: return .green
        case .permission: return .orange
        case .hint: return .purple
        case .taskStart: return .green
        case .taskStop: return .red
        case .taskMetrics: return .cyan
        case .unknown: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: typeIcon)
                .font(.title2)
                .foregroundStyle(typeColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title ?? event.eventType.rawValue.capitalized)
                    .font(.headline)
                    .foregroundStyle(event.isResolved ? .secondary : .primary)

                if let subtitle = event.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(event.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !event.isResolved && event.eventType == .permission {
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.vertical, 4)
    }
}

struct VisionInboxEventDetail: View {
    let event: InboxEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 16) {
                    Image(systemName: event.eventType == .permission ? "lock.shield.fill" : "bell.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(event.eventType == .permission ? .orange : .blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title ?? "Event")
                            .font(.title.weight(.semibold))

                        Text(event.timestamp, style: .date)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Content
                if let subtitle = event.subtitle {
                    Text(subtitle)
                        .font(.body)
                }

                // Status
                HStack {
                    Text("Status:")
                        .foregroundStyle(.secondary)
                    Text(event.isResolved ? "Resolved" : "Pending")
                        .foregroundStyle(event.isResolved ? .green : .orange)
                        .fontWeight(.medium)
                }
            }
            .padding(32)
        }
        .navigationTitle("Event Details")
    }
}

// MARK: - Optimizations Views

struct VisionOptimizationsOverview: View {
    let workspace: Workspace?
    @Query(sort: \Skill.updatedAt, order: .reverse) private var allSkills: [Skill]
    @Query(sort: \Context.updatedAt, order: .reverse) private var allContexts: [Context]

    private var skills: [Skill] {
        guard let workspace else { return allSkills }
        return allSkills.filter { $0.workspace?.id == workspace.id }
    }

    private var contexts: [Context] {
        guard let workspace else { return allContexts }
        return allContexts.filter { $0.workspace?.id == workspace.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 48))
                        .foregroundStyle(.purple)

                    Text("Optimizations")
                        .font(.largeTitle.weight(.bold))

                    Text("Improve your agent's performance with skills and context")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // Stats
                HStack(spacing: 40) {
                    VisionStatCard(
                        icon: "hammer.fill",
                        title: "Skills",
                        value: "\(skills.count)",
                        color: .orange
                    )

                    VisionStatCard(
                        icon: "briefcase.fill",
                        title: "Contexts",
                        value: "\(contexts.count)",
                        color: .blue
                    )
                }
                .padding(.horizontal, 32)

                Spacer()
            }
        }
        .navigationTitle("Optimizations")
    }
}

struct VisionStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: 36, weight: .bold).monospacedDigit())

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct VisionOptimizationsDetailPlaceholder: View {
    var body: some View {
        VisionEmptyState(
            icon: "gauge.with.dots.needle.50percent",
            title: "Optimizations Overview",
            description: "Select Skills or Context to manage"
        )
    }
}

// MARK: - Team Views

struct VisionTeamListView: View {
    @Binding var selection: OrganizationMember?
    @Query(sort: \OrganizationMember.createdAt, order: .reverse) private var members: [OrganizationMember]

    var body: some View {
        List(selection: $selection) {
            ForEach(members) { member in
                VisionTeamMemberRow(member: member)
                    .tag(member)
            }
        }
        .navigationTitle("Team")
        .overlay {
            if members.isEmpty {
                ContentUnavailableView {
                    Label("No Team Members", systemImage: "person.2")
                } description: {
                    Text("Team members will appear here")
                }
            }
        }
    }
}

struct VisionTeamMemberRow: View {
    let member: OrganizationMember

    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: member.profile?.avatarUrl ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(member.profile?.displayName ?? member.profile?.email ?? "Member")
                    .font(.headline)

                Text(member.role ?? "member")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.capitalize)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct VisionTeamMemberDetail: View {
    let member: OrganizationMember

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Avatar
                AsyncImage(url: URL(string: member.profile?.avatarUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 100, height: 100)
                .clipShape(Circle())

                // Name
                Text(member.profile?.displayName ?? "Team Member")
                    .font(.title.weight(.semibold))

                // Role
                Text(member.role ?? "member")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textCase(.capitalize)

                // Email
                if let email = member.profile?.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                Divider()
                    .padding(.vertical)

                // Joined
                VStack(spacing: 4) {
                    Text("Joined")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(member.createdAt, style: .date)
                        .font(.subheadline)
                }
            }
            .padding(40)
        }
        .navigationTitle("Profile")
    }
}

// MARK: - visionOS Inbox (Hints) - Legacy compatibility

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

// MARK: - visionOS Task Detail

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

#endif
