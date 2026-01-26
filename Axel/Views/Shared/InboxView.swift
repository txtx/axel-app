import SwiftUI

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
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text("No Blockers")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Permissions and questions will appear here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

                    Image(systemName: "rectangle.stack")
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

    /// Send permission response
    private func sendPermissionResponse(allow: Bool) {
        guard let sessionId = event.event.claudeSessionId else {
            print("[InboxView] No session ID for permission response")
            return
        }

        Task {
            do {
                try await inboxService.sendPermissionResponse(sessionId: sessionId, allow: allow)
                await MainActor.run {
                    inboxService.resolveEvent(event.id)
                    selection = nil
                }
            } catch {
                print("[InboxView] Failed to send permission response: \(error)")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                header

                // Allow/Deny buttons for permission requests
                if isPermissionRequest && !isResolved {
                    HStack(spacing: 12) {
                        Button {
                            sendPermissionResponse(allow: false)
                        } label: {
                            Label("Deny", systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)

                        Button {
                            sendPermissionResponse(allow: true)
                        } label: {
                            Label("Allow", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                    }
                }

                // Confirm button for completion events
                if isCompletionEvent && !isResolved {
                    Button {
                        inboxService.resolveEvent(event.id)
                        selection = nil
                    } label: {
                        Label("Confirm", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }

                // Task metrics snapshot (only available for completion events)
                if let snapshot = metricsSnapshot {
                    metricsSection(snapshot)
                }

                Divider()

                // Event details
                detailsSection

                // Tool input section (with diff view for Edit/Write tools)
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

            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            return "Task Completed"
        case "SubagentStop":
            return "Subagent Completed"
        default:
            return event.eventType
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let toolName = event.event.toolName {
                    GridRow {
                        Text("Tool")
                            .foregroundStyle(.secondary)
                        Text(toolName)
                            .fontWeight(.medium)
                    }
                }

                if let cwd = event.event.cwd {
                    GridRow {
                        Text("Directory")
                            .foregroundStyle(.secondary)
                        Text(cwd)
                            .textSelection(.enabled)
                    }
                }

                if let sessionId = event.event.claudeSessionId {
                    GridRow {
                        Text("Session")
                            .foregroundStyle(.secondary)
                        Text(sessionId)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let permissionMode = event.event.permissionMode {
                    GridRow {
                        Text("Mode")
                            .foregroundStyle(.secondary)
                        Text(permissionMode)
                    }
                }
            }
            .font(.body)
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
