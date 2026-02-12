import SwiftUI
import SwiftData

#if os(macOS)

// MARK: - Inbox Scene View

/// Unified inbox view showing all pending permission requests and task completions.
///
/// Events come from the SSE `/inbox` endpoint on each terminal's axel-cli server.
/// Due to the shared `.claude/settings.json` hooks problem, events may arrive with
/// wrong pane_ids. This view uses `InboxService.resolvedPaneId(for:)` to correct
/// the pane_id for worktree grouping, response targeting, and data fetching.
///
/// ## Event Lifecycle
/// 1. Claude Code triggers a hook → POST to axel-cli server → SSE broadcast
/// 2. `InboxService` receives via SSE, parses as `InboxEvent`, adds to `events`
/// 3. This view filters for PermissionRequest/Stop events that aren't resolved
/// 4. User interacts (approve/deny/complete) → response sent via `/outbox`
/// 5. Event marked as resolved → disappears from view
struct InboxSceneView: View {
    @State private var inboxService = InboxService.shared
    @State private var selectedPickerIndex = 0
    @Environment(\.terminalSessionManager) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    /// All relevant pending events (permission requests and completions)
    private var allEvents: [InboxEvent] {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return ["PermissionRequest", "Stop"].contains(hookName) && !inboxService.isResolved(event.id)
        }
    }

    /// Build worktree picker items from events
    private var worktreeItems: [(name: String, count: Int)] {
        var items: [(name: String, count: Int)] = [("All", allEvents.count)]

        // Group events by worktree
        var worktreeCounts: [String: Int] = [:]
        for event in allEvents {
            let worktree = worktreeForEvent(event)
            worktreeCounts[worktree, default: 0] += 1
        }

        // "main" first, then others alphabetically
        if let mainCount = worktreeCounts["main"] {
            items.append(("main", mainCount))
        }
        for (name, count) in worktreeCounts.sorted(by: { $0.key < $1.key }) where name != "main" {
            items.append((name, count))
        }

        return items
    }

    /// Map event paneId to worktree display name
    /// Uses resolved paneId (OTEL-corrected) since hook events may carry wrong paneId
    private func worktreeForEvent(_ event: InboxEvent) -> String {
        let paneId = inboxService.resolvedPaneId(for: event)
        // Try TerminalSession first (in-memory, fast)
        if let session = sessionManager.sessions.first(where: { $0.paneId == paneId }) {
            return session.worktreeDisplayName
        }
        // Fallback: look up Terminal model via SwiftData
        let descriptor = FetchDescriptor<Terminal>(predicate: #Predicate { $0.paneId == paneId })
        if let terminal = try? modelContext.fetch(descriptor).first {
            return terminal.worktreeBranch ?? "main"
        }
        return "main"
    }

    /// Filtered events based on selected worktree
    private var filteredEvents: [InboxEvent] {
        guard selectedPickerIndex > 0, selectedPickerIndex < worktreeItems.count else {
            return allEvents
        }
        let selectedWorktree = worktreeItems[selectedPickerIndex].name
        return allEvents.filter { worktreeForEvent($0) == selectedWorktree }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if worktreeItems.count > 1 {
                worktreePickerView
            }

            if filteredEvents.isEmpty {
                EmptyStateView(
                    image: "checkmark.circle",
                    title: "No Blockers",
                    description: "Permissions and questions will appear here"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(filteredEvents) { event in
                            InboxEventCardView(event: event)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.trailing, -24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            navigatePicker(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigatePicker(by: 1)
            return .handled
        }
        .onChange(of: allEvents.count) { _, _ in
            // Clamp picker index if worktree items changed
            if selectedPickerIndex >= worktreeItems.count {
                selectedPickerIndex = 0
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center) {
            Image(systemName: "tray.fill")
                .font(.system(size: 19))
                .foregroundStyle(Color(red: 249/255, green: 25/255, blue: 85/255))

            Text("Inbox")
                .font(.system(size: 24, weight: .bold))

            Text("\(allEvents.count)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            Spacer()
        }
        .frame(maxWidth: 1000)
        .padding(.leading, 64)
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 32)
        .padding(.bottom, 12)
    }

    // MARK: - Worktree Picker

    private var worktreePickerView: some View {
        HStack(spacing: 6) {
            ForEach(Array(worktreeItems.enumerated()), id: \.offset) { index, item in
                let isSelected = index == selectedPickerIndex
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selectedPickerIndex = index
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))

                        if item.count > 0 && index > 0 {
                            Text("\(item.count)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(isSelected ? .primary : .tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
            }

            Spacer()
        }
        .frame(maxWidth: 1000)
        .padding(.leading, 64)
        .padding(.trailing, 40)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selectedPickerIndex)
    }

    // MARK: - Picker Navigation

    private func navigatePicker(by offset: Int) {
        let newIndex = selectedPickerIndex + offset
        guard newIndex >= 0, newIndex < worktreeItems.count else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            selectedPickerIndex = newIndex
        }
    }
}

// MARK: - Inline Event Card

/// An inline card that renders event details with action buttons embedded in the flow.
///
/// Uses `InboxService.resolvedPaneId(for:)` for all pane-dependent operations
/// (terminal lookup, task queue, cost tracking, response targeting) because the
/// raw `event.paneId` may be wrong due to shared `.claude/settings.json` hooks.
private struct InboxEventCardView: View {
    let event: InboxEvent
    @State private var inboxService = InboxService.shared
    @State private var costTracker = CostTracker.shared
    @State private var taskQueueService = TaskQueueService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.terminalSessionManager) private var sessionManager

    @State private var taskTitle: String?
    @State private var currentTask: WorkTask?
    @State private var permissionEvents: [InboxEvent] = []
    @State private var nextQueuedTasks: [WorkTask] = []
    @State private var taskSegments: [TaskSegment] = []

    private var metricsSnapshot: MetricsSnapshot? {
        inboxService.eventMetricsSnapshots[event.id]
    }

    private var isCompletionEvent: Bool {
        event.event.hookEventName == "Stop"
    }

    private var isPermissionRequest: Bool {
        event.event.hookEventName == "PermissionRequest"
    }

    private var isResolved: Bool {
        inboxService.isResolved(event.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            cardHeader

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

            // Metrics snapshot (completion events)
            if let snapshot = metricsSnapshot {
                metricsSection(snapshot)
            }

            // Cost breakdown (completion events)
            if isCompletionEvent && !taskSegments.isEmpty {
                Divider()
                costBreakdownSection
            }

            // Permissions recap (completion events)
            if isCompletionEvent && !permissionEvents.isEmpty {
                Divider()
                permissionsRecapSection
            }

            // Next queued tasks (completion events)
            if isCompletionEvent && !nextQueuedTasks.isEmpty {
                Divider()
                nextTasksSection
            }

            // Tool input / diffs (permission requests)
            if let input = event.event.toolInput {
                toolInputContent(input)
            }

            // Inline action buttons
            if isPermissionRequest && !isResolved {
                inlinePermissionButtons
            }

            // Completion confirm button
            if isCompletionEvent && !isResolved {
                HStack {
                    Spacer()
                    Button {
                        inboxService.resolveEvent(event.id)
                        if let task = currentTask {
                            task.updateStatus(.completed)
                            try? modelContext.save()
                        }
                        let resolvedPane = inboxService.resolvedPaneId(for: event)
                        inboxService.confirmTaskCompletion(forPaneId: resolvedPane)
                    } label: {
                        Label(
                            nextQueuedTasks.isEmpty ? "Mark Completed" : "Complete and Continue",
                            systemImage: nextQueuedTasks.isEmpty ? "checkmark.circle.fill" : "arrow.right.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(nextQueuedTasks.isEmpty ? .green : .blue)
                    .controlSize(.large)
                }
            }
        }
        .padding(20)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onAppear { fetchEventData() }
        .onChange(of: taskQueueService.terminalQueues[inboxService.resolvedPaneId(for: event)]) { _, _ in
            refreshQueuedTasks()
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
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

    // MARK: - Permission Action Buttons (Inline)

    @ViewBuilder
    private var inlinePermissionButtons: some View {
        let options = event.permissionOptions

        VStack(spacing: 10) {
            HStack(spacing: 12) {
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
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
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
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Session-wide options (middle options)
            let middleOptions = options.dropFirst().dropLast()
            if !middleOptions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(middleOptions)) { option in
                        Button {
                            sendPermissionResponse(option: option)
                        } label: {
                            Text(option.shortLabel)
                                .fontWeight(.medium)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Tool Input Content

    @ViewBuilder
    private func toolInputContent(_ input: [String: AnyCodable]) -> some View {
        if event.event.toolName == "Edit",
           let filePath = input["file_path"]?.value as? String,
           let oldString = input["old_string"]?.value as? String,
           let newString = input["new_string"]?.value as? String {
            EditToolDiffView(filePath: filePath, oldString: oldString, newString: newString)
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        } else if event.event.toolName == "Write",
                  let filePath = input["file_path"]?.value as? String,
                  let content = input["content"]?.value as? String {
            WriteToolDiffView(filePath: filePath, content: content)
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        } else {
            toolInputSection(input)
        }
    }

    // MARK: - Tool Input Section (raw)

    @ViewBuilder
    private func toolInputSection(_ input: [String: AnyCodable]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool Input")
                .font(.headline)

            if let filePath = input["file_path"]?.value as? String {
                LabeledContent("File") {
                    Text(filePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

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

    // MARK: - Metrics Section

    @ViewBuilder
    private func metricsSection(_ snapshot: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
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

            HStack(spacing: 16) {
                TokenBreakdownItem(label: "Input", value: snapshot.inputTokens, color: .blue)
                TokenBreakdownItem(label: "Output", value: snapshot.outputTokens, color: .green)
                TokenBreakdownItem(label: "Cache Read", value: snapshot.cacheReadTokens, color: .accentPurple)
                TokenBreakdownItem(label: "Cache Write", value: snapshot.cacheCreationTokens, color: .orange)
            }

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

    // MARK: - Cost Breakdown Section

    @ViewBuilder
    private var costBreakdownSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.accentPurple)
                Text("Cost Breakdown")
                    .font(.headline)
                Spacer()
                Text("\(taskSegments.count) segments")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                let maxTokens = taskSegments.map { $0.tokensUsed }.max() ?? 1
                ForEach(taskSegments) { segment in
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            let width = maxTokens > 0 ? CGFloat(segment.tokensUsed) / CGFloat(maxTokens) * geo.size.width : 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentPurple.opacity(0.6))
                                .frame(width: max(4, width))
                        }
                        .frame(height: 12)
                        .frame(maxWidth: 100)

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
                                    .foregroundStyle(.accentPurple)
                            }
                        }
                        Spacer()
                    }
                }
            }

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
                    .foregroundStyle(.accentPurple)
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

            ForEach(nextQueuedTasks) { task in
                HStack(spacing: 8) {
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
            }
        }
    }

    // MARK: - Helpers

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
        case "PermissionRequest": return .orange
        case "Stop", "SubagentStop": return .green
        default: return .secondary
        }
    }

    private var headerTitle: String {
        switch event.event.hookEventName {
        case "PermissionRequest": return "Permission Request"
        case "Stop": return taskTitle ?? "Task Completed"
        case "SubagentStop": return "Subagent Completed"
        default: return event.eventType
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

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Permission Response

    private func sendPermissionResponse(option: PermissionOption) {
        guard let sessionId = event.event.claudeSessionId else { return }
        // Resolve the correct paneId via OTEL mapping — hook events may carry the
        // wrong paneId due to shared .claude/settings.json across terminals.
        let correctPaneId = CostTracker.shared.paneId(forSessionId: sessionId) ?? event.paneId
        Task {
            do {
                try await inboxService.sendPermissionResponse(
                    sessionId: sessionId,
                    option: option,
                    paneId: correctPaneId
                )
                await MainActor.run {
                    inboxService.resolveEvent(event.id)
                }
            } catch {
                print("[InboxSceneView] Failed to send permission response: \(error)")
            }
        }
    }

    // MARK: - Data Fetching

    private func fetchEventData() {
        let paneId = inboxService.resolvedPaneId(for: event)

        // Permission events from same session (use claudeSessionId for correct grouping)
        let eventSessionId = event.event.claudeSessionId
        permissionEvents = inboxService.events.filter { evt in
            evt.event.claudeSessionId == eventSessionId && evt.event.hookEventName == "PermissionRequest"
        }

        // Look up terminal by resolved paneId
        var terminalDescriptor = FetchDescriptor<Terminal>()
        terminalDescriptor.predicate = #Predicate<Terminal> { terminal in
            terminal.paneId == paneId
        }

        if let terminal = try? modelContext.fetch(terminalDescriptor).first {
            currentTask = terminal.task
            taskTitle = terminal.task?.title

            guard isCompletionEvent else { return }

            let terminalId = terminal.id
            let taskId = terminal.task?.id
            let hintDescriptor = FetchDescriptor<Hint>(
                sortBy: [SortDescriptor(\Hint.createdAt, order: .reverse)]
            )
            if let allHints = try? modelContext.fetch(hintDescriptor) {
                _ = allHints.filter { hint in
                    hint.terminal?.id == terminalId || (taskId != nil && hint.task?.id == taskId)
                }
            }
        }

        guard isCompletionEvent else { return }

        // Queued tasks for this terminal
        let queuedTaskIds = TaskQueueService.shared.tasksQueued(onTerminal: paneId)
        if !queuedTaskIds.isEmpty {
            let taskDescriptor = FetchDescriptor<WorkTask>()
            if let allTasks = try? modelContext.fetch(taskDescriptor) {
                nextQueuedTasks = queuedTaskIds.compactMap { taskId in
                    allTasks.first { $0.id == taskId }
                }
            }
        }

        // Cost segments
        if let tracker = costTracker.taskTracker(forPaneId: paneId) {
            taskSegments = tracker.segments
        }
    }

    private func refreshQueuedTasks() {
        guard isCompletionEvent else { return }
        let paneId = inboxService.resolvedPaneId(for: event)
        let queuedTaskIds = taskQueueService.tasksQueued(onTerminal: paneId)
        guard !queuedTaskIds.isEmpty else {
            nextQueuedTasks = []
            return
        }
        let taskDescriptor = FetchDescriptor<WorkTask>()
        if let allTasks = try? modelContext.fetch(taskDescriptor) {
            nextQueuedTasks = queuedTaskIds.compactMap { taskId in
                allTasks.first { $0.id == taskId }
            }
        }
    }
}

#endif
