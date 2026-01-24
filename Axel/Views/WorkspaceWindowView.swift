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
#endif
