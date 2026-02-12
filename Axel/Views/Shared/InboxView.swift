import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inbox Event Row (used by visionOS)

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

    private var toolName: String {
        event.event.toolName ?? "Unknown"
    }

    private var filePath: String? {
        guard let input = event.event.toolInput,
              let path = input["file_path"]?.value as? String else {
            return nil
        }
        return path
    }

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
            HStack(spacing: 10) {
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

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    if let cwd = event.event.cwd {
                        DetailRow(label: "Directory", value: cwd)
                    }

                    DetailRow(label: "Tool", value: toolName)

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

// MARK: - Shared Components (used by InboxSceneView and visionOS)

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
        if jsonString.count > 500 {
            return String(jsonString.prefix(500)) + "\n..."
        }
        return jsonString
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

// MARK: - Diff View

/// Renders a unified diff with syntax-colored +/- lines
struct RawDiffView: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(line.background)
                }
            }
        }
        .frame(maxHeight: 300)
        .background(Color(.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var diffLines: [RawDiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            if text.hasPrefix("+++") || text.hasPrefix("---") {
                return RawDiffLine(text: text, color: .secondary, background: .clear)
            } else if text.hasPrefix("@@") {
                return RawDiffLine(text: text, color: .purple, background: Color.purple.opacity(0.05))
            } else if text.hasPrefix("+") {
                return RawDiffLine(text: text, color: .green, background: Color.green.opacity(0.08))
            } else if text.hasPrefix("-") {
                return RawDiffLine(text: text, color: .red, background: Color.red.opacity(0.08))
            } else {
                return RawDiffLine(text: text, color: .primary.opacity(0.6), background: .clear)
            }
        }
    }
}

struct RawDiffLine {
    let text: String
    let color: Color
    let background: Color
}
