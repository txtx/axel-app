import SwiftUI
import SwiftData

#if os(macOS)
struct WorkspaceWindowView: View {
    let workspaceId: UUID
    @Environment(\.modelContext) private var modelContext
    @State private var localWorkspace: Workspace?  // Workspace from workspace-specific container
    @State private var workspaceContainer: ModelContainer?
    @State private var appState = AppState()
    @State private var loadError: String?
    @State private var showAxelSetupSheet: Bool = false
    @State private var axelSetupService = AxelSetupService.shared

    var body: some View {
        Group {
            if let workspace = localWorkspace, let container = workspaceContainer {
                WorkspaceContentView(workspace: workspace, appState: appState)
                    .modelContainer(container)
            } else if let error = loadError {
                errorView(error)
            } else {
                loadingView
            }
        }
        .task {
            await loadWorkspace()
        }
        .task {
            // Check if axel is installed
            let isInstalled = await axelSetupService.checkInstallation()
            if !isInstalled {
                showAxelSetupSheet = true
            }
        }
        .sheet(isPresented: $showAxelSetupSheet) {
            AxelSetupSheet(isPresented: $showAxelSetupSheet)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading workspace...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Failed to Load Workspace")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Retry") {
                loadError = nil
                Task {
                    await loadWorkspace()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func loadWorkspace() async {
        // Load workspace metadata from shared container
        let descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == workspaceId }
        )

        do {
            let workspaces = try modelContext.fetch(descriptor)
            if let sharedWorkspace = workspaces.first {
                // Get or create workspace-specific container
                let effectiveId = sharedWorkspace.syncId ?? sharedWorkspace.id
                let container = try WorkspaceContainerManager.shared.container(for: effectiveId)
                workspaceContainer = container

                // Ensure workspace exists in workspace container (copies metadata)
                try WorkspaceContainerManager.shared.ensureWorkspaceInContainer(sharedWorkspace, container: container)

                // Get workspace from workspace container (this is what views will use)
                localWorkspace = try WorkspaceContainerManager.shared.workspace(from: container, id: sharedWorkspace.id)

                // Set model context on InboxService for hint persistence
                InboxService.shared.modelContext = container.mainContext
            } else {
                loadError = "Workspace not found"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Axel Setup Sheet

struct AxelSetupSheet: View {
    @Binding var isPresented: Bool
    @State private var axelSetupService = AxelSetupService.shared
    @State private var isInstalling: Bool = false
    @State private var installError: String?
    @State private var installSuccess: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text("Install Axel CLI")
                    .font(.title2.bold())

                Text("The Axel CLI is required to run AI agents. Would you like to install it to ~/.local/bin/axel?")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Status area
            VStack(spacing: 12) {
                if isInstalling {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Installing...")
                            .foregroundStyle(.secondary)
                    }
                } else if installSuccess {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Installed successfully!")
                            .foregroundStyle(.green)
                    }
                } else if let error = installError {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Installation failed")
                                .foregroundStyle(.orange)
                        }
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Text("This will download and install axel from GitHub to ~/.local/bin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 60)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Skip") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)

                Spacer()

                if installSuccess {
                    Button("Done") {
                        isPresented = false
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Install") {
                        Task {
                            await performInstall()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 400)
        .background(.background)
    }

    private func performInstall() async {
        isInstalling = true
        installError = nil

        let success = await axelSetupService.installFromRelease()

        isInstalling = false

        if success {
            installSuccess = true
        } else {
            installError = axelSetupService.lastError ?? "Unknown error"
        }
    }
}

// MARK: - Axel Setup Service
// ============================================================================
// Service to check and manage axel CLI installation.
// Handles:
// - Checking if axel is in PATH
// - Installing axel to ~/.local/bin/ (preferred location)
// - Checking if workspace has AXEL.md
// ============================================================================

@MainActor
@Observable
final class AxelSetupService {

    // MARK: - Singleton

    static let shared = AxelSetupService()

    // MARK: - State

    /// Whether axel CLI is available in PATH
    private(set) var isAxelInstalled: Bool = false

    /// Path where axel was found (if installed)
    private(set) var axelPath: String?

    /// Whether we're currently checking installation
    private(set) var isChecking: Bool = false

    /// Whether we're currently installing
    private(set) var isInstalling: Bool = false

    /// Last error message
    private(set) var lastError: String?

    // MARK: - Constants

    /// Locations to check for axel binary
    private let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/axel",
        "/usr/local/bin/axel",
        "/opt/homebrew/bin/axel",
        "\(NSHomeDirectory())/.cargo/bin/axel"
    ]

    // MARK: - Initialization

    private init() {
        // Check on init
        Task {
            await checkInstallation()
        }
    }

    // MARK: - Public API

    /// Check if axel is installed and available
    @discardableResult
    func checkInstallation() async -> Bool {
        isChecking = true
        defer { isChecking = false }

        // First check our known locations
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                axelPath = path
                isAxelInstalled = true
                return true
            }
        }

        // Try to find via `which` command
        if let whichPath = await findAxelViaWhich() {
            axelPath = whichPath
            isAxelInstalled = true
            return true
        }

        isAxelInstalled = false
        axelPath = nil
        return false
    }

    /// Install axel using the official install script from GitHub
    func installFromRelease() async -> Bool {
        isInstalling = true
        lastError = nil
        defer { isInstalling = false }

        // Run the install script from GitHub
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "curl -fsSL https://raw.githubusercontent.com/txtx/axel/main/scripts/install.sh | bash"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                // Verify installation succeeded
                let installed = await checkInstallation()
                if installed {
                    return true
                } else {
                    lastError = "Install script completed but axel not found in PATH"
                    return false
                }
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                lastError = "Install script failed: \(output)"
                return false
            }
        } catch {
            lastError = "Failed to run install script: \(error.localizedDescription)"
            return false
        }
    }

    /// Check if a workspace directory has AXEL.md
    func hasAxelManifest(at workspacePath: String?) -> Bool {
        guard let path = workspacePath else { return false }
        let manifestPath = (path as NSString).appendingPathComponent("AXEL.md")
        return FileManager.default.fileExists(atPath: manifestPath)
    }

    /// Get the command prefix to initialize workspace if needed
    /// Returns empty string if no init needed, or "axel init --workspace <name> && " if init is needed
    func getInitCommandPrefix(workspacePath: String?, workspaceName: String) -> String {
        guard let path = workspacePath else { return "" }

        if hasAxelManifest(at: path) {
            return ""
        }

        // Need to initialize the workspace first
        // Shell-escape the workspace name
        let escaped = workspaceName.replacingOccurrences(of: "'", with: "'\\''")
        return "axel init --workspace '\(escaped)' && "
    }

    // MARK: - Private

    private func findAxelViaWhich() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["axel"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    return output
                }
            }
        } catch {
            // which command failed, axel not in PATH
        }

        return nil
    }
}
#endif
