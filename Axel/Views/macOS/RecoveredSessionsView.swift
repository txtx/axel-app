import SwiftUI

#if os(macOS)

// MARK: - Recovered Sessions List View

struct RecoveredSessionsListView: View {
    let workspacePath: String?
    @Binding var selection: RecoveredSession?
    @State private var recoveryService = SessionRecoveryService.shared
    @Environment(\.terminalSessionManager) private var sessionManager

    private var trackedPaneIds: Set<String> {
        Set(sessionManager.sessions.compactMap { $0.paneId })
    }

    private var recoveredSessions: [RecoveredSession] {
        recoveryService.untrackedSessions(for: workspacePath, trackedPaneIds: trackedPaneIds)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Recovered Sessions")
                    .font(.title2.bold())
                Spacer()

                Button {
                    Task { await recoveryService.discoverSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(recoveryService.isDiscovering)

                Text("\(recoveredSessions.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if recoveredSessions.isEmpty {
                emptyState
            } else {
                List(recoveredSessions, selection: $selection) { session in
                    RecoveredSessionRow(session: session)
                        .tag(session)
                }
                .listStyle(.plain)
            }
        }
        .task {
            // Discover sessions on appear
            await recoveryService.discoverSessions()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Recovered Sessions", systemImage: "arrow.clockwise.circle")
        } description: {
            Text("No tmux sessions found for this workspace")
        }
    }
}

// MARK: - Recovered Session Row

struct RecoveredSessionRow: View {
    let session: RecoveredSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Session name (truncated UUID)
                    Text(session.name.prefix(8))
                        .font(.body.weight(.medium))
                        .fontDesign(.monospaced)

                    // Attached badge
                    if session.attached {
                        Text("attached")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                // Details
                HStack(spacing: 8) {
                    Text("\(session.panes) pane\(session.panes == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(session.createdDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Recovery indicator
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.yellow)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Recovered Session Detail View

struct RecoveredSessionDetailView: View {
    let session: RecoveredSession
    let workspaceId: UUID
    let workspacePath: String?
    @State private var recoveryService = SessionRecoveryService.shared
    @State private var isKilling = false
    @Environment(\.terminalSessionManager) private var sessionManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Details")
                        .font(.title2.bold())
                    Text(session.name)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Session info
            Form {
                Section {
                    LabeledContent("Panes", value: "\(session.panes)")
                    LabeledContent("Windows", value: "\(session.windows)")
                    LabeledContent("Created", value: session.createdDate.formatted(date: .abbreviated, time: .shortened))
                    if let path = session.workingDir {
                        LabeledContent("Directory") {
                            Text(path)
                                .font(.caption)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(session.attached ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(session.attached ? "Attached" : "Detached")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Spacer()

            // Action buttons
            HStack {
                Button(role: .destructive) {
                    killSession()
                } label: {
                    HStack {
                        if isKilling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "xmark.circle")
                        }
                        Text("Kill Session")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isKilling)

                Spacer()

                Button {
                    attachToSession()
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        Text("Attach")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(20)
        }
    }

    private func attachToSession() {
        // Open in external terminal using tmux attach
        let axelPath = AxelSetupService.shared.executablePath
        let command = "\(axelPath) session join \(session.name)"

        // Try to find an installed terminal to use
        let installedTerminals = TerminalApp.installedApps
        if let terminal = installedTerminals.first {
            terminal.open(withCommand: command)
        } else {
            // Fallback: use Terminal.app via AppleScript
            let script = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }
    }

    private func killSession() {
        isKilling = true

        Task {
            let axelPath = AxelSetupService.shared.executablePath

            let process = Process()
            process.executableURL = URL(fileURLWithPath: axelPath)
            process.arguments = ["session", "kill", session.name, "--confirm"]

            AxelSetupService.shared.configureAxelProcess(process)

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("[RecoveredSession] Failed to kill session: \(error)")
            }

            // Refresh discovered sessions
            await recoveryService.discoverSessions()
            isKilling = false
        }
    }
}

#endif
