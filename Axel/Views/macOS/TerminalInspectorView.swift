import SwiftUI
import SwiftData

#if os(macOS)
// MARK: - Terminal Inspector View
// ============================================================================
// Sheet modal for inspecting terminal session details.
// Shows current task, tokens, history, queue, and status.
//
// Data sources:
// - TerminalSession: paneId, taskId, taskTitle, taskHistory, startedAt
// - SessionStatusService: status (blocked/thinking/active/idle/dormant)
// - CostTracker: token metrics and histogram
// - TaskQueueService: queued tasks count
// ============================================================================

struct TerminalInspectorView: View {
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Services for data aggregation
    private let statusService = SessionStatusService.shared
    @State private var costTracker = CostTracker.shared
    @State private var queueService = TaskQueueService.shared

    // Current task (fetched from modelContext if taskId exists)
    @State private var currentTask: WorkTask?

    // MARK: - Computed Properties

    private var status: SessionStatus {
        session.status
    }

    private var terminalTracker: TerminalCostTracker? {
        guard let paneId = session.paneId else { return nil }
        return costTracker.terminalTrackers[paneId]
    }

    private var inputTokens: Int {
        terminalTracker?.totalInputTokens ?? 0
    }

    private var outputTokens: Int {
        terminalTracker?.totalOutputTokens ?? 0
    }

    private var cacheReadTokens: Int {
        terminalTracker?.totalCacheReadTokens ?? 0
    }

    private var cacheCreationTokens: Int {
        terminalTracker?.totalCacheCreationTokens ?? 0
    }

    private var totalTokens: Int {
        terminalTracker?.totalTokens ?? 0
    }

    private var totalCost: Double {
        terminalTracker?.totalCostUSD ?? 0
    }

    private var histogramValues: [Double] {
        terminalTracker?.histogramValues ?? Array(repeating: 0.1, count: 12)
    }

    private var queueCount: Int {
        guard let paneId = session.paneId else { return 0 }
        return queueService.queueCount(forTerminal: paneId)
    }

    private var uptime: String {
        let interval = Date().timeIntervalSince(session.startedAt)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Current Task section
                    currentTaskSection

                    // Token Metrics section
                    tokenMetricsSection

                    // Task History section
                    if !session.taskHistory.isEmpty {
                        taskHistorySection
                    }

                    // Queue section
                    if queueCount > 0 {
                        queueSection
                    }

                    // Terminal Info section
                    terminalInfoSection
                }
                .padding(20)
            }

            Divider()

            // Footer with Done button
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
        .background(.background)
        .onAppear {
            fetchCurrentTask()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Status indicator
            StatusIndicator(status: status)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskTitle)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    // Status label
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(status.backgroundColor)
                        .clipShape(Capsule())

                    // Uptime
                    Text("Uptime: \(uptime)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Close button
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
    }

    // MARK: - Current Task Section

    private var currentTaskSection: some View {
        InspectorSection(title: "Current Task", icon: "bolt.fill", iconColor: .orange) {
            if let task = currentTask {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)

                    if let description = task.taskDescription, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    HStack(spacing: 12) {
                        Label(task.taskStatus.displayName, systemImage: statusIcon(for: task.taskStatus))
                            .font(.caption)
                            .foregroundStyle(statusColor(for: task.taskStatus))

                        Text("Created \(task.createdAt, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(.secondary)
                    Text("No task assigned")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    // MARK: - Token Metrics Section

    private var tokenMetricsSection: some View {
        InspectorSection(title: "Token Metrics", icon: "chart.bar.fill", iconColor: .purple) {
            VStack(spacing: 12) {
                // Mini histogram
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                        UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 2)
                            .fill(Color.orange)
                            .frame(width: 8, height: max(4, value * 24))
                    }
                }
                .frame(height: 24)
                .frame(maxWidth: .infinity)

                // Token breakdown
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 8) {
                    TokenMetricRow(label: "Input", value: inputTokens, color: .blue)
                    TokenMetricRow(label: "Output", value: outputTokens, color: .green)
                    TokenMetricRow(label: "Cache Read", value: cacheReadTokens, color: .orange)
                    TokenMetricRow(label: "Cache Write", value: cacheCreationTokens, color: .purple)
                }

                Divider()

                // Total and cost
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formatTokenCount(totalTokens))
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Cost")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "$%.4f", totalCost))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    // MARK: - Task History Section

    private var taskHistorySection: some View {
        InspectorSection(title: "Recent Tasks", icon: "clock.arrow.circlepath", iconColor: .blue) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(session.taskHistory.prefix(3), id: \.self) { taskTitle in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(taskTitle)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Queue Section

    private var queueSection: some View {
        InspectorSection(title: "Queue", icon: "list.bullet", iconColor: .orange) {
            HStack {
                Text("\(queueCount) task\(queueCount == 1 ? "" : "s") waiting")
                    .font(.callout)
                Spacer()
                Text("FIFO")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Terminal Info Section

    private var terminalInfoSection: some View {
        InspectorSection(title: "Terminal Info", icon: "terminal.fill", iconColor: .secondary) {
            VStack(spacing: 8) {
                InfoRow(label: "Pane ID", value: session.paneId ?? "N/A")
                InfoRow(label: "Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
                InfoRow(label: "Session ID", value: session.id.uuidString.prefix(8).description + "...")
            }
        }
    }

    // MARK: - Helpers

    private func fetchCurrentTask() {
        guard let taskId = session.taskId else {
            currentTask = nil
            return
        }

        // Fetch from modelContext using the persistentModelID
        if let task = modelContext.model(for: taskId) as? WorkTask {
            currentTask = task
        }
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .backlog, .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private func statusIcon(for status: TaskStatus) -> String {
        switch status {
        case .backlog, .queued: "clock.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .inReview: "eye.circle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }
}

// MARK: - Inspector Section

private struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Section content
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Token Metric Row

private struct TokenMetricRow: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formatValue(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func formatValue(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

// MARK: - Info Row

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

#endif
