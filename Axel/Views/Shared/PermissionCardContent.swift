import SwiftUI

/// The content displayed inside each permission request card
struct PermissionCardContent: View {
    let event: InboxEvent
    let onSelectOption: (PermissionOption) -> Void
    @FocusState private var isFocused: Bool

    /// The "allow" option (first non-destructive option)
    private var allowOption: PermissionOption? {
        event.permissionOptions.first { !$0.isDestructive }
    }

    /// The "deny" option (last destructive option)
    private var denyOption: PermissionOption? {
        if let last = event.permissionOptions.last, last.isDestructive {
            return last
        }
        return nil
    }

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
        case "Bash": return .accentPurple
        case "Glob", "Grep": return .cyan
        case "WebFetch", "WebSearch": return .green
        default: return .secondary
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
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

                        // Bottom padding to make room for floating buttons
                        Color.clear.frame(height: 80)
                    }
                    .padding()
                }
            }
            .background(.background)

            // Floating action buttons
            actionButtons
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear { isFocused = true }
        .onKeyPress(.escape) {
            if let option = denyOption {
                onSelectOption(option)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if let option = allowOption {
                onSelectOption(option)
                return .handled
            }
            return .ignored
        }
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
        let options = event.permissionOptions

        return VStack(spacing: 12) {
            // Primary row: Yes and No buttons
            HStack(spacing: 12) {
                // No button (last option, destructive)
                if let noOption = options.last, noOption.isDestructive {
                    Button(action: { onSelectOption(noOption) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                                .fontWeight(.semibold)
                            Text(noOption.shortLabel)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: .red.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                // Yes button (first option)
                if let yesOption = options.first, !yesOption.isDestructive {
                    Button(action: { onSelectOption(yesOption) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                            Text(yesOption.shortLabel)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                        .shadow(color: .green.opacity(0.3), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }

            // Secondary row: Session-wide options (middle options)
            let middleOptions = options.dropFirst().dropLast()
            if !middleOptions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(middleOptions)) { option in
                        Button(action: { onSelectOption(option) }) {
                            Text(option.shortLabel)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(
                            KeyEquivalent(Character(String(option.id))),
                            modifiers: []
                        )
                    }
                }
                .font(.callout.weight(.medium))
            }
        }
        .font(.body.weight(.medium))
        .padding(.bottom, 20)
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
        case "Bash": return .accentPurple
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
        .background(.background)
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

    /// Mock event with permission suggestions (shows session-wide option)
    static var mockEventWithSuggestions: InboxEvent? {
        let mockJSON = """
        {
            "timestamp": "2024-01-15T12:00:00Z",
            "event_type": "hook_event",
            "pane_id": "test-pane",
            "event": {
                "hook_event_name": "PermissionRequest",
                "tool_name": "Edit",
                "cwd": "/Users/test/project",
                "permission_suggestions": [
                    {
                        "type": "setMode",
                        "mode": "acceptEdits",
                        "destination": "session"
                    }
                ],
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

#Preview("Permission Card - Simple") {
    if let event = PermissionCardPreviewHelper.mockEvent {
        PermissionCardContent(
            event: event,
            onSelectOption: { option in
                print("Selected: \(option.label)")
            }
        )
        .frame(width: 400, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .padding(40)
    } else {
        Text("Preview unavailable")
    }
}

#Preview("Permission Card - With Session Option") {
    if let event = PermissionCardPreviewHelper.mockEventWithSuggestions {
        PermissionCardContent(
            event: event,
            onSelectOption: { option in
                print("Selected: \(option.label)")
            }
        )
        .frame(width: 400, height: 500)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .padding(40)
    } else {
        Text("Preview unavailable")
    }
}
