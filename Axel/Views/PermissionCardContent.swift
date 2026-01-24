import SwiftUI

/// The content displayed inside each permission request card
struct PermissionCardContent: View {
    let event: InboxEvent
    let onDeny: () -> Void
    let onAllow: () -> Void

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

    /// Get the file name from the path
    private var fileName: String? {
        guard let path = filePath else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Get a human-readable description of what's being requested
    private var requestDescription: String {
        switch toolName {
        case "Edit":
            if let name = fileName {
                return "Edit \(name)"
            }
            return "Edit a file"
        case "Write":
            if let name = fileName {
                return "Write \(name)"
            }
            return "Write a file"
        case "Bash":
            return "Run command"
        case "Read":
            if let name = fileName {
                return "Read \(name)"
            }
            return "Read a file"
        case "Glob", "Grep":
            return "Search files"
        case "WebFetch", "WebSearch":
            return "Web access"
        default:
            return "Use \(toolName)"
        }
    }

    /// Get bash command if present
    private var bashCommand: String? {
        guard toolName == "Bash",
              let input = event.event.toolInput,
              let command = input["command"]?.value as? String else {
            return nil
        }
        return command
    }

    /// Icon for the tool
    private var toolIcon: String {
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

    /// Color for the tool icon
    private var toolColor: Color {
        switch toolName {
        case "Edit", "Write": return .orange
        case "Read": return .blue
        case "Bash": return .purple
        case "Glob", "Grep": return .cyan
        case "WebFetch", "WebSearch": return .green
        default: return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // File path or command preview
                    if let command = bashCommand {
                        bashCommandSection(command)
                    } else if let path = filePath {
                        filePathSection(path)
                    }

                    // Diff view for Edit/Write tools
                    if let input = event.event.toolInput {
                        if toolName == "Edit",
                           let path = input["file_path"]?.value as? String,
                           let oldString = input["old_string"]?.value as? String,
                           let newString = input["new_string"]?.value as? String {
                            EditToolDiffView(
                                filePath: path,
                                oldString: oldString,
                                newString: newString
                            )
                            .frame(minHeight: 200, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        } else if toolName == "Write",
                                  let path = input["file_path"]?.value as? String,
                                  let content = input["content"]?.value as? String {
                            WriteToolDiffView(
                                filePath: path,
                                content: content
                            )
                            .frame(minHeight: 200, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }

                    // Directory context
                    if let cwd = event.event.cwd {
                        directorySection(cwd)
                    }
                }
                .padding()
            }

            Divider()

            // Action buttons
            actionButtons
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(UIColor.systemBackground))
        #endif
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Tool icon
            ZStack {
                Circle()
                    .fill(toolColor.opacity(0.15))
                    .frame(width: 50, height: 50)

                Image(systemName: toolIcon)
                    .font(.title2)
                    .foregroundStyle(toolColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(requestDescription)
                    .font(.headline)

                Text(event.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Permission badge
            Text("Permission Required")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding()
    }

    // MARK: - Content Sections

    private func bashCommandSection(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Command", systemImage: "terminal")
                .font(.subheadline)
                .fontWeight(.medium)
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

    private func filePathSection(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("File", systemImage: "doc.text")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Text(path)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func directorySection(_ cwd: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            Text(cwd)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Deny button
            Button(action: onDeny) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Deny")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.leftArrow, modifiers: [])

            // Allow button
            Button(action: onAllow) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Allow")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .padding()
    }
}

// MARK: - Compact Card Content (for stacked cards)

/// A more compact version for background cards in the stack
struct PermissionCardContentCompact: View {
    let event: InboxEvent

    private var toolName: String {
        event.event.toolName ?? "Unknown"
    }

    private var fileName: String? {
        guard let input = event.event.toolInput,
              let path = input["file_path"]?.value as? String else {
            return nil
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var requestDescription: String {
        switch toolName {
        case "Edit":
            if let name = fileName { return "Edit \(name)" }
            return "Edit a file"
        case "Write":
            if let name = fileName { return "Write \(name)" }
            return "Write a file"
        case "Bash":
            return "Run command"
        case "Read":
            if let name = fileName { return "Read \(name)" }
            return "Read a file"
        default:
            return "Use \(toolName)"
        }
    }

    private var toolIcon: String {
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

    private var toolColor: Color {
        switch toolName {
        case "Edit", "Write": return .orange
        case "Read": return .blue
        case "Bash": return .purple
        case "Glob", "Grep": return .cyan
        case "WebFetch", "WebSearch": return .green
        default: return .secondary
        }
    }

    var body: some View {
        VStack {
            Spacer()

            HStack(spacing: 12) {
                Image(systemName: toolIcon)
                    .font(.title2)
                    .foregroundStyle(toolColor)

                Text(requestDescription)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding()

            Spacer()
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(UIColor.systemBackground))
        #endif
    }
}

// MARK: - Preview

/// Helper to create mock InboxEvent for previews
private enum PermissionCardPreviewHelper {
    static var mockEvent: InboxEvent? {
        let mockJSON = """
        {
            "timestamp": "2024-01-15T12:00:00Z",
            "event_type": "hook_event",
            "pane_id": "test-pane",
            "event": {
                "hook_event_name": "PermissionRequest",
                "tool_name": "Edit",
                "cwd": "/Users/test/project",
                "tool_input": {
                    "file_path": "/Users/test/project/src/main.swift",
                    "old_string": "let x = 1",
                    "new_string": "let x = 2"
                }
            }
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InboxEvent.self, from: mockJSON.data(using: .utf8)!)
    }
}

#Preview("Permission Card Content") {
    if let event = PermissionCardPreviewHelper.mockEvent {
        PermissionCardContent(
            event: event,
            onDeny: { },
            onAllow: { }
        )
        .frame(width: 400, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .padding(40)
    } else {
        Text("Preview unavailable")
    }
}
