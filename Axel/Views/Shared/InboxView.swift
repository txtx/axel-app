import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Events we care about: PermissionRequest, Stop
private let relevantEventTypes = ["PermissionRequest", "Stop"]

/// View mode for the inbox
enum InboxViewMode: String, CaseIterable {
    case list = "List"
    case cards = "Cards"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .cards: return "rectangle.stack"
        }
    }
}

// MARK: - Inbox View (unified wrapper)

/// Unified inbox view that can switch between list and card stack modes
struct InboxView: View {
    @Binding var selection: InboxEvent?
    @State private var inboxService = InboxService.shared

    private var pendingEvents: [InboxEvent] {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return relevantEventTypes.contains(hookName) && !inboxService.isResolved(event.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Inbox")
                    .font(.title2.bold())
                Spacer()
                if !pendingEvents.isEmpty {
                    Text("\(pendingEvents.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if pendingEvents.isEmpty {
                EmptyStateView(
                    image: "checkmark.circle",
                    title: "No Blockers",
                    description: "Permissions and questions will appear here"
                )
            } else {
                List(pendingEvents, selection: $selection) { event in
                    InboxEventListRow(event: event)
                        .tag(event)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
        .onAppear {
            inboxService.connect()
            // Auto-select the first item when inbox opens
            if selection == nil, let first = pendingEvents.first {
                selection = first
            }
        }
        .onChange(of: pendingEvents) { _, newEvents in
            // Auto-select the first item when events change and nothing is selected
            if selection == nil, let first = newEvents.first {
                selection = first
            }
        }
    }
}

// MARK: - Inbox List Content (extracted from InboxListView)

/// The list content portion of the inbox (without header)
struct InboxListContent: View {
    @Binding var selection: InboxEvent?
    @State private var inboxService = InboxService.shared

    /// Pending events (not yet resolved)
    private var pendingEvents: [InboxEvent] {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return relevantEventTypes.contains(hookName) && !inboxService.isResolved(event.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Connection status bar
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(inboxService.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text(inboxService.isConnected ? "Live" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !pendingEvents.isEmpty {
                    Button {
                        inboxService.clearEvents()
                        selection = nil
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            // Events list
            if pendingEvents.isEmpty {
                emptyState
            } else {
                List(pendingEvents, selection: $selection) { event in
                    InboxEventListRow(event: event)
                        .tag(event)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.background)
        .onAppear {
            inboxService.connect()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green.opacity(0.5))

            Text("No Blockers")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            if inboxService.isConnected {
                Text("Permissions and questions will appear here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if let error = inboxService.connectionError {
                Text("Connection error: \(error.localizedDescription)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                Button("Reconnect") {
                    inboxService.reconnect()
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            } else {
                Text("Connecting to axel server...")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inbox List View (legacy, for compatibility)

/// List view for selecting inbox events
struct InboxListView: View {
    @Binding var selection: InboxEvent?
    @State private var inboxService = InboxService.shared

    /// Pending events (not yet resolved)
    private var pendingEvents: [InboxEvent] {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return relevantEventTypes.contains(hookName) && !inboxService.isResolved(event.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with connection status
            HStack {
                Text("Activity")
                    .font(.headline)

                Spacer()

                // Connection indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(inboxService.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)

                    Text(inboxService.isConnected ? "Live" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !pendingEvents.isEmpty {
                    Button {
                        inboxService.clearEvents()
                        selection = nil
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Events list
            if pendingEvents.isEmpty {
                VStack(spacing: 12) {
                    Spacer()

                    Image(systemName: "tray.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.quaternary)

                    Text("No Blockers")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)

                    if inboxService.isConnected {
                        Text("Permissions and questions will appear here")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    } else if let error = inboxService.connectionError {
                        Text("Connection error: \(error.localizedDescription)")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)

                        Button("Reconnect") {
                            inboxService.reconnect()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    } else {
                        Text("Connecting to axel server...")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pendingEvents, selection: $selection) { event in
                    InboxEventListRow(event: event)
                        .tag(event)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            inboxService.connect()
        }
    }
}

/// A compact row for the list view
struct InboxEventListRow: View {
    let event: InboxEvent

    private var icon: String {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return iconForTool(event.event.toolName)
        case "Stop":
            return "checkmark.circle"
        case "SubagentStop":
            return "person.2.circle"
        default:
            return "bell"
        }
    }

    private var iconColor: Color {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return .orange
        case "Stop", "SubagentStop":
            return .green
        default:
            return .secondary
        }
    }

    private var title: String {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return permissionTitle
        case "Stop":
            return "Task completed"
        case "SubagentStop":
            return "Subagent completed"
        default:
            return event.eventType
        }
    }

    private var permissionTitle: String {
        let toolName = event.event.toolName ?? "Unknown"
        if let input = event.event.toolInput,
           let path = input["file_path"]?.value as? String {
            return "\(toolName) \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        if toolName == "Bash",
           let input = event.event.toolInput,
           let cmd = input["command"]?.value as? String {
            let truncated = cmd.prefix(30)
            return "Run: \(truncated)\(cmd.count > 30 ? "..." : "")"
        }
        return "Use \(toolName)"
    }

    private var subtitle: String? {
        if let cwd = event.event.cwd {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(event.timestamp, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func iconForTool(_ toolName: String?) -> String {
        switch toolName {
        case "Edit": return "pencil.tip.crop.circle"
        case "Write": return "square.and.pencil"
        case "Read": return "doc.text"
        case "Bash": return "terminal"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        default: return "lock.shield"
        }
    }
}

// MARK: - Inbox Event Detail View (for detail column)

/// Detail view for a selected inbox event
struct InboxEventDetailView: View {
    let event: InboxEvent
    @Binding var selection: InboxEvent?
    @State private var inboxService = InboxService.shared
    @State private var costTracker = CostTracker.shared
    @State private var taskQueueService = TaskQueueService.shared
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
    @Environment(\.terminalSessionManager) private var sessionManager
    #endif

    /// Hints associated with this terminal/task (for completion events)
    @State private var taskHints: [Hint] = []

    /// Permission request events from the same pane (in-memory)
    @State private var permissionEvents: [InboxEvent] = []

    /// Next queued tasks in the workspace
    @State private var nextQueuedTasks: [WorkTask] = []

    /// Drag-and-drop state for task reordering
    @State private var draggingTaskId: UUID?
    @State private var dropTargetIndex: Int?

    /// Task cost segments from CostTracker
    @State private var taskSegments: [TaskSegment] = []

    /// The workspace for this event (used for starting next task)
    @State private var eventWorkspace: Workspace?

    /// Get metrics snapshot for this event (only for completion events)
    private var metricsSnapshot: MetricsSnapshot? {
        inboxService.eventMetricsSnapshots[event.id]
    }

    /// Whether this is a completion event
    private var isCompletionEvent: Bool {
        event.event.hookEventName == "Stop"
    }

    /// Whether this is a permission request event
    private var isPermissionRequest: Bool {
        event.event.hookEventName == "PermissionRequest"
    }

    /// Whether this event has been resolved
    private var isResolved: Bool {
        inboxService.isResolved(event.id)
    }

    /// Send permission response with selected option
    private func sendPermissionResponse(option: PermissionOption) {
        guard let sessionId = event.event.claudeSessionId else {
            print("[InboxView] No session ID for permission response")
            return
        }

        Task {
            do {
                try await inboxService.sendPermissionResponse(
                    sessionId: sessionId,
                    option: option,
                    paneId: event.paneId
                )
                await MainActor.run {
                    inboxService.resolveEvent(event.id)
                    selection = nil
                }
            } catch {
                print("[InboxView] Failed to send permission response: \(error)")
            }
        }
    }

    /// The task title for this terminal (fetched on appear)
    @State private var taskTitle: String?

    /// The current task on this terminal (for marking complete)
    @State private var currentTask: WorkTask?

    /// Fetch task context and related data
    private func fetchEventData() {
        let paneId = event.paneId

        // Fetch permission request events from the same pane (in-memory)
        permissionEvents = inboxService.events.filter { evt in
            evt.paneId == paneId && evt.event.hookEventName == "PermissionRequest"
        }

        // Fetch terminal by paneId
        var terminalDescriptor = FetchDescriptor<Terminal>()
        terminalDescriptor.predicate = #Predicate<Terminal> { terminal in
            terminal.paneId == paneId
        }

        if let terminal = try? modelContext.fetch(terminalDescriptor).first {
            // Get task and title
            currentTask = terminal.task
            taskTitle = terminal.task?.title

            // Get workspace from task or terminal
            eventWorkspace = terminal.task?.workspace ?? terminal.workspace

            // Only fetch hints for completion events
            guard isCompletionEvent else { return }

            // Get hints for this terminal OR for the associated task
            let terminalId = terminal.id
            let taskId = terminal.task?.id
            let hintDescriptor = FetchDescriptor<Hint>(
                sortBy: [SortDescriptor(\Hint.createdAt, order: .reverse)]
            )
            if let allHints = try? modelContext.fetch(hintDescriptor) {
                // Include hints linked to this terminal OR to the task
                taskHints = allHints.filter { hint in
                    hint.terminal?.id == terminalId || (taskId != nil && hint.task?.id == taskId)
                }
            }
        }

        // Fetch queued tasks for completion events - only tasks queued on this terminal
        guard isCompletionEvent else { return }

        // Get task IDs queued on this specific terminal from TaskQueueService
        let queuedTaskIds = TaskQueueService.shared.tasksQueued(onTerminal: paneId)

        guard !queuedTaskIds.isEmpty else {
            nextQueuedTasks = []
            return
        }

        // Fetch tasks by ID, preserving queue order
        let taskDescriptor = FetchDescriptor<WorkTask>()
        if let allTasks = try? modelContext.fetch(taskDescriptor) {
            // Map task IDs to tasks, preserving queue order
            nextQueuedTasks = queuedTaskIds.compactMap { taskId in
                allTasks.first { $0.id == taskId }
            }
        }

        // Fetch task cost segments from CostTracker (use paneId)
        if let tracker = costTracker.taskTracker(forPaneId: event.paneId) {
            taskSegments = tracker.segments
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    header

                    // Task context for permission requests
                    if isPermissionRequest, let title = taskTitle {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                            Text("Task: \(title)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Task metrics snapshot (only available for completion events)
                    if let snapshot = metricsSnapshot {
                        metricsSection(snapshot)
                    }

                    // Cost breakdown by segments (from CostTracker)
                    if isCompletionEvent && !taskSegments.isEmpty {
                        Divider()
                        costBreakdownSection
                    }

                    // Permissions recap for completion events
                    if isCompletionEvent && !permissionEvents.isEmpty {
                        Divider()
                        permissionsRecapSection
                    }

                    // Next queued tasks for completion events (only if there are tasks queued on this terminal)
                    if isCompletionEvent && !nextQueuedTasks.isEmpty {
                        Divider()
                        nextTasksSection
                    }

                    // Confirm button for completion events (after queue section)
                    if isCompletionEvent && !isResolved {
                        HStack {
                            Spacer()
                            Button {
                                // Resolve the current event
                                inboxService.resolveEvent(event.id)

                                // Mark the current task as completed
                                if let task = currentTask {
                                    task.updateStatus(.completed)
                                    try? modelContext.save()
                                }

                                // Trigger queue consumption via notification
                                // This will dequeue and start the next task if one is queued
                                inboxService.confirmTaskCompletion(forPaneId: event.paneId)

                                selection = nil
                            } label: {
                                Label(nextQueuedTasks.isEmpty ? "Done" : "Complete and Continue", systemImage: nextQueuedTasks.isEmpty ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(nextQueuedTasks.isEmpty ? .green : .blue)
                            .controlSize(.large)
                        }
                    }

                    // Tool input section for permission requests (with diff view for Edit/Write tools)
                    if let input = event.event.toolInput {
                        if event.event.toolName == "Edit",
                           let filePath = input["file_path"]?.value as? String,
                           let oldString = input["old_string"]?.value as? String,
                           let newString = input["new_string"]?.value as? String {
                            // Show diff view for Edit tool
                            EditToolDiffView(
                                filePath: filePath,
                                oldString: oldString,
                                newString: newString
                            )
                            .frame(minHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        } else if event.event.toolName == "Write",
                                  let filePath = input["file_path"]?.value as? String,
                                  let content = input["content"]?.value as? String {
                            // Show diff view for Write tool
                            WriteToolDiffView(
                                filePath: filePath,
                                content: content
                            )
                            .frame(minHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        } else {
                            // Show raw tool input for other tools
                            toolInputSection(input)
                        }
                    }

                    // Bottom padding to make room for floating buttons
                    if isPermissionRequest && !isResolved {
                        Color.clear.frame(height: 100)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Floating action buttons for permission requests
            if isPermissionRequest && !isResolved {
                permissionActionButtons
            }
        }
        .onAppear {
            fetchEventData()
        }
        .onChange(of: taskQueueService.terminalQueues[event.paneId]) { _, _ in
            // Refresh queued tasks when the queue changes
            refreshQueuedTasks()
        }
    }

    /// Refresh only the queued tasks list (lighter weight than full fetch)
    private func refreshQueuedTasks() {
        guard isCompletionEvent else { return }

        let paneId = event.paneId
        let queuedTaskIds = taskQueueService.tasksQueued(onTerminal: paneId)

        guard !queuedTaskIds.isEmpty else {
            nextQueuedTasks = []
            return
        }

        // Fetch tasks by ID, preserving queue order
        let taskDescriptor = FetchDescriptor<WorkTask>()
        if let allTasks = try? modelContext.fetch(taskDescriptor) {
            nextQueuedTasks = queuedTaskIds.compactMap { taskId in
                allTasks.first { $0.id == taskId }
            }
        }
    }

    // MARK: - Cost Breakdown Section

    @ViewBuilder
    private var costBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.purple)
                Text("Cost Breakdown")
                    .font(.headline)
                Spacer()
                Text("\(taskSegments.count) segments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Segment bars visualization
            VStack(spacing: 4) {
                let maxTokens = taskSegments.map { $0.tokensUsed }.max() ?? 1
                ForEach(taskSegments) { segment in
                    HStack(spacing: 8) {
                        // Segment bar
                        GeometryReader { geo in
                            let width = maxTokens > 0 ? CGFloat(segment.tokensUsed) / CGFloat(maxTokens) * geo.size.width : 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.purple.opacity(0.6))
                                .frame(width: max(4, width))
                        }
                        .frame(height: 12)
                        .frame(maxWidth: 100)

                        // Segment info
                        VStack(alignment: .leading, spacing: 1) {
                            Text(segment.description)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(formatTokens(segment.tokensUsed))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "$%.4f", segment.costUsed))
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }
                        }
                        Spacer()
                    }
                }
            }

            // Total summary
            HStack {
                Spacer()
                let totalTokens = taskSegments.reduce(0) { $0 + $1.tokensUsed }
                let totalCost = taskSegments.reduce(0.0) { $0 + $1.costUsed }
                Text("Total: \(formatTokens(totalTokens)) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "$%.4f", totalCost))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.purple)
            }
        }
    }

    // MARK: - Permissions Recap Section

    @ViewBuilder
    private var permissionsRecapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Permissions Granted")
                    .font(.headline)
                Spacer()
                Text("\(permissionEvents.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(permissionEvents) { permEvent in
                PermissionRecapRow(event: permEvent, isResolved: inboxService.isResolved(permEvent.id))
            }
        }
    }

    // MARK: - Next Tasks Section

    @ViewBuilder
    private var nextTasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundStyle(.blue)
                Text("Up Next")
                    .font(.headline)
                Spacer()
                Text("\(nextQueuedTasks.count) queued")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Group {
                ForEach(Array(nextQueuedTasks.enumerated()), id: \.element.id) { index, task in
                    let isBeingDragged = draggingTaskId == task.id

                    // Show drop placeholder before this item if it's the drop target
                    if let targetIndex = dropTargetIndex,
                       targetIndex == index,
                       !isBeingDragged {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.078, green: 0.078, blue: 0.078))
                            .frame(height: 28)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.caption)

                        Circle()
                            .fill(task.priority > 0 ? Color.orange : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)

                        Text(task.title)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        if task.priority > 0 {
                            Text("P\(task.priority)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                    )
                    .contentShape(Rectangle())
                    .frame(height: isBeingDragged ? 0 : nil)
                    .opacity(isBeingDragged ? 0 : 1)
                    .clipped()
                    .onDrag {
                        draggingTaskId = task.id
                        return NSItemProvider(object: task.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], isTargeted: Binding(
                        get: { dropTargetIndex == index },
                        set: { isTargeted in
                            if isTargeted {
                                dropTargetIndex = index
                            } else if dropTargetIndex == index {
                                dropTargetIndex = nil
                            }
                        }
                    )) { providers in
                        // Capture state before clearing - must clear synchronously
                        // to ensure task reappears even if async callback fails
                        let targetIndex = index
                        let currentDropTarget = dropTargetIndex
                        draggingTaskId = nil
                        dropTargetIndex = nil

                        guard let provider = providers.first,
                              currentDropTarget == targetIndex else {
                            return false
                        }

                        provider.loadObject(ofClass: NSString.self) { item, _ in
                            DispatchQueue.main.async {
                                guard let droppedId = item as? String,
                                      let droppedUUID = UUID(uuidString: droppedId),
                                      let fromIndex = nextQueuedTasks.firstIndex(where: { $0.id == droppedUUID }),
                                      fromIndex != targetIndex else {
                                    return
                                }
                                moveTask(from: fromIndex, to: targetIndex)
                            }
                        }
                        return true
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: draggingTaskId)
                .animation(.easeInOut(duration: 0.15), value: dropTargetIndex)
            }
        }
    }

    /// Handle drag-and-drop reordering of queued tasks
    private func moveTask(from sourceIndex: Int, to destinationIndex: Int) {
        let movedTask = nextQueuedTasks[sourceIndex]

        // Update the local array for immediate UI feedback
        nextQueuedTasks.remove(at: sourceIndex)
        // After removal, indices shift down - adjust destination if moving forward
        let insertIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        nextQueuedTasks.insert(movedTask, at: insertIndex)

        // Persist the reorder in TaskQueueService
        taskQueueService.reorder(taskId: movedTask.id, toIndex: insertIndex, inTerminal: event.paneId)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIcon)
                .font(.largeTitle)
                .foregroundStyle(headerColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(event.timestamp, format: .dateTime)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    // MARK: - Permission Action Buttons

    @ViewBuilder
    private var permissionActionButtons: some View {
        let options = event.permissionOptions

        VStack(spacing: 12) {
            // Primary row: Yes and No buttons
            HStack(spacing: 16) {
                // No button (last option, destructive)
                if let noOption = options.last, noOption.isDestructive {
                    Button {
                        sendPermissionResponse(option: noOption)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark")
                                .fontWeight(.semibold)
                            Text(noOption.shortLabel)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: .red.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }

                // Yes button (first option)
                if let yesOption = options.first, !yesOption.isDestructive {
                    Button {
                        sendPermissionResponse(option: yesOption)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                            Text(yesOption.shortLabel)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: .green.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Secondary row: Session-wide options (middle options)
            let middleOptions = options.dropFirst().dropLast()
            if !middleOptions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(middleOptions)) { option in
                        Button {
                            sendPermissionResponse(option: option)
                        } label: {
                            Text(option.shortLabel)
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 20)
    }

    private var headerIcon: String {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return iconForTool(event.event.toolName)
        case "Stop":
            return "checkmark.circle.fill"
        case "SubagentStop":
            return "person.2.circle.fill"
        default:
            return "bell.fill"
        }
    }

    private var headerColor: Color {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return .orange
        case "Stop", "SubagentStop":
            return .green
        default:
            return .secondary
        }
    }

    private var headerTitle: String {
        switch event.event.hookEventName {
        case "PermissionRequest":
            return "Permission Request"
        case "Stop":
            return taskTitle ?? "Task Completed"
        case "SubagentStop":
            return "Subagent Completed"
        default:
            return event.eventType
        }
    }

    @ViewBuilder
    private func toolInputSection(_ input: [String: AnyCodable]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Input")
                .font(.headline)

            // Show file path prominently if present
            if let filePath = input["file_path"]?.value as? String {
                LabeledContent("File") {
                    Text(filePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            // Show command prominently if Bash
            if let command = input["command"]?.value as? String {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .foregroundStyle(.secondary)

                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }

            // Show old/new string for Edit
            if let oldString = input["old_string"]?.value as? String {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Old Content")
                        .foregroundStyle(.secondary)

                    Text(oldString.prefix(500) + (oldString.count > 500 ? "..." : ""))
                        .font(.system(.caption, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }

            if let newString = input["new_string"]?.value as? String {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Content")
                        .foregroundStyle(.secondary)

                    Text(newString.prefix(500) + (newString.count > 500 ? "..." : ""))
                        .font(.system(.caption, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func iconForTool(_ toolName: String?) -> String {
        switch toolName {
        case "Edit": return "pencil.tip.crop.circle.fill"
        case "Write": return "square.and.pencil.circle.fill"
        case "Read": return "doc.text.fill"
        case "Bash": return "terminal.fill"
        case "Glob", "Grep": return "magnifyingglass.circle.fill"
        case "WebFetch", "WebSearch": return "globe"
        default: return "lock.shield.fill"
        }
    }

    // MARK: - Metrics Section

    @ViewBuilder
    private func metricsSection(_ snapshot: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Big highlights: Cost and Tokens
            HStack(spacing: 16) {
                // Cost - primary highlight
                VStack(spacing: 4) {
                    Text(snapshot.formattedCost)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Cost")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Tokens - secondary highlight
                VStack(spacing: 4) {
                    Text(formatTokens(snapshot.totalTokens))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Tokens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Token breakdown (compact)
            HStack(spacing: 16) {
                TokenBreakdownItem(label: "Input", value: snapshot.inputTokens, color: .blue)
                TokenBreakdownItem(label: "Output", value: snapshot.outputTokens, color: .green)
                TokenBreakdownItem(label: "Cache Read", value: snapshot.cacheReadTokens, color: .purple)
                TokenBreakdownItem(label: "Cache Write", value: snapshot.cacheCreationTokens, color: .orange)
            }

            // Lines changed (if any)
            if snapshot.linesAdded > 0 || snapshot.linesRemoved > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text("+\(snapshot.linesAdded)")
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                    Text("-\(snapshot.linesRemoved)")
                        .foregroundStyle(.red)
                        .fontWeight(.medium)
                    Text("lines")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

/// A compact token breakdown item
struct TokenBreakdownItem: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(formatTokens(value))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Permission Recap Row (expandable)

/// An expandable row for permission recap in task completed view
struct PermissionRecapRow: View {
    let event: InboxEvent
    let isResolved: Bool

    @State private var isExpanded = false

    private var toolName: String {
        event.event.toolName ?? "Unknown"
    }

    private var filePath: String? {
        event.event.toolInput?["file_path"]?.value as? String
    }

    private var command: String? {
        event.event.toolInput?["command"]?.value as? String
    }

    private var iconName: String {
        switch toolName {
        case "Edit": return "pencil.tip.crop.circle.fill"
        case "Write": return "square.and.pencil.circle.fill"
        case "Read": return "doc.text.fill"
        case "Bash": return "terminal.fill"
        case "Glob", "Grep": return "magnifyingglass.circle.fill"
        case "WebFetch", "WebSearch": return "globe"
        default: return "lock.shield.fill"
        }
    }

    private var summary: String {
        if let path = filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        } else if let cmd = command {
            return String(cmd.prefix(40)) + (cmd.count > 40 ? "..." : "")
        }
        return toolName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Main row - tappable to expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(.orange)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(toolName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if isResolved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let path = filePath {
                        HStack(alignment: .top) {
                            Text("File:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }

                    if let cmd = command {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Command:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(cmd)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.05))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .textSelection(.enabled)
                        }
                    }

                    // For Edit tool, show old/new strings
                    if toolName == "Edit" {
                        if let oldString = event.event.toolInput?["old_string"]?.value as? String {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Removed:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(oldString.prefix(200)) + (oldString.count > 200 ? "..." : ""))
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.red.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .textSelection(.enabled)
                            }
                        }
                        if let newString = event.event.toolInput?["new_string"]?.value as? String {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Added:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(newString.prefix(200)) + (newString.count > 200 ? "..." : ""))
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.green.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    // For Write tool, show content preview
                    if toolName == "Write" {
                        if let content = event.event.toolInput?["content"]?.value as? String {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Content:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(content.prefix(200)) + (content.count > 200 ? "..." : ""))
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.green.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Legacy Views (kept for compatibility)

/// A row displaying an inbox event (PermissionRequest, Stop, SubagentStop)
struct InboxEventRow: View {
    let event: InboxEvent

    var body: some View {
        switch event.event.hookEventName {
        case "PermissionRequest":
            PermissionRequestRow(event: event)
        case "Stop":
            StopEventRow(event: event, isSubagent: false)
        case "SubagentStop":
            StopEventRow(event: event, isSubagent: true)
        default:
            EmptyView()
        }
    }
}

/// A row displaying a Stop or SubagentStop event
struct StopEventRow: View {
    let event: InboxEvent
    let isSubagent: Bool

    @State private var isExpanded = false

    private var title: String {
        isSubagent ? "Subagent completed" : "Task completed"
    }

    private var workingDirectory: String? {
        guard let cwd = event.event.cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: isSubagent ? "person.2.circle" : "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)

                    if let dir = workingDirectory {
                        Text(dir)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(event.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    if let cwd = event.event.cwd {
                        DetailRow(label: "Directory", value: cwd)
                    }

                    if let sessionId = event.event.claudeSessionId {
                        DetailRow(label: "Session", value: String(sessionId.prefix(8)) + "...")
                    }
                }
                .padding(.leading, 34)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A row displaying a permission request from Claude
struct PermissionRequestRow: View {
    let event: InboxEvent

    @State private var isExpanded = false

    /// Extract the tool name from the event
    private var toolName: String {
        event.event.toolName ?? "Unknown"
    }

    /// Extract file path if present in tool input
    private var filePath: String? {
        guard let input = event.event.toolInput,
              let path = input["file_path"]?.value as? String else {
            return nil
        }
        return path
    }

    /// Get a human-readable description of what's being requested
    private var requestDescription: String {
        switch toolName {
        case "Edit":
            if let path = filePath {
                return "Edit \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Edit a file"
        case "Write":
            if let path = filePath {
                return "Write \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Write a file"
        case "Bash":
            if let input = event.event.toolInput,
               let command = input["command"]?.value as? String {
                let truncated = command.prefix(50)
                return "Run: \(truncated)\(command.count > 50 ? "..." : "")"
            }
            return "Run a command"
        case "Read":
            if let path = filePath {
                return "Read \(URL(fileURLWithPath: path).lastPathComponent)"
            }
            return "Read a file"
        default:
            return "Use \(toolName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Main row
            HStack(spacing: 10) {
                // Icon based on tool
                Image(systemName: iconForTool)
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(requestDescription)
                        .font(.body)
                        .fontWeight(.medium)

                    if let path = filePath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Text(event.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    if let cwd = event.event.cwd {
                        DetailRow(label: "Directory", value: cwd)
                    }

                    DetailRow(label: "Tool", value: toolName)

                    // Tool input preview
                    if let input = event.event.toolInput {
                        ToolDataView(title: "Input", data: input)
                    }
                }
                .padding(.leading, 34)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private var iconForTool: String {
        switch toolName {
        case "Edit": return "pencil.tip.crop.circle"
        case "Write": return "square.and.pencil"
        case "Read": return "doc.text"
        case "Bash": return "terminal"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        default: return "lock.shield"
        }
    }
}

/// A labeled detail row
struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            Spacer()
        }
    }
}

/// View for displaying tool input/response data
struct ToolDataView: View {
    let title: String
    let data: [String: AnyCodable]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(formatJSON(data))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func formatJSON(_ data: [String: AnyCodable]) -> String {
        let dict = data.mapValues { $0.value }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        // Limit length for display
        if jsonString.count > 500 {
            return String(jsonString.prefix(500)) + "\n..."
        }
        return jsonString
    }
}

// MARK: - Previews

#Preview("Inbox - Card Stack") {
    @Previewable @State var selection: InboxEvent? = nil
    InboxView(selection: $selection)
        .frame(width: 450, height: 600)
}

#Preview("Inbox - List") {
    @Previewable @State var selection: InboxEvent? = nil
    InboxListView(selection: $selection)
        .frame(width: 350, height: 500)
}
