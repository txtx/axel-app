import SwiftUI
import SwiftData
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

struct WorkspacePickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Query(sort: \Workspace.updatedAt, order: .reverse) private var workspaces: [Workspace]
    @State private var hoveredWorkspaceId: UUID?
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Left side - Recent Workspaces
            recentWorkspacesPanel

            Divider()

            // Right side - Open Directory
            openDirectoryPanel
        }
        .frame(width: 700, height: 480)
        .background(.background)
    }

    // MARK: - Recent Workspaces Panel

    private var recentWorkspacesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.title2.weight(.semibold))
                Text("Open a recently used workspace")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 20)

            // Workspaces list
            if workspaces.isEmpty {
                recentEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(workspaces) { workspace in
                            RecentWorkspaceRow(
                                workspace: workspace,
                                isHovered: hoveredWorkspaceId == workspace.id,
                                onOpen: { openWorkspace(workspace) },
                                onDelete: { deleteWorkspace(workspace) }
                            )
                            .onHover { isHovered in
                                hoveredWorkspaceId = isHovered ? workspace.id : nil
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
        }
        .frame(width: 340)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var recentEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            Text("No Recent Workspaces")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Workspaces you open will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Open Directory Panel

    private var openDirectoryPanel: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon and title
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    // .symbolEffect(.pulse, options: .repeating.speed(0.3))  // Disabled - causes hang

                VStack(spacing: 4) {
                    Text("Axel")
                        .font(.largeTitle.weight(.bold))

                    Text("AI-Assisted Development")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Drop zone / Open button
            openDirectoryDropZone

            Spacer()

            // Keyboard hint
            Text("Or drag a folder here")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var openDirectoryDropZone: some View {
        Button {
            selectDirectory()
        } label: {
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                        )

                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

                        VStack(spacing: 4) {
                            Text("Open Directory")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Text("Select a project folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(32)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 240, height: 160)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Actions

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Select a directory for your workspace"

        if panel.runModal() == .OK, let url = panel.url {
            createWorkspaceFromDirectory(url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.hasDirectoryPath else {
                return
            }

            DispatchQueue.main.async {
                createWorkspaceFromDirectory(url)
            }
        }

        return true
    }

    private func createWorkspaceFromDirectory(_ url: URL) {
        // Check if workspace with this path already exists locally
        if let existing = workspaces.first(where: { $0.path == url.path }) {
            openWorkspace(existing)
            return
        }

        let name = url.lastPathComponent
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)

        // Check if workspace with this slug already exists locally (e.g., synced from remote)
        if let existing = workspaces.first(where: { $0.slug == slug }) {
            // Update the path if it's different or missing
            if existing.path != url.path {
                existing.path = url.path
            }
            openWorkspace(existing)
            return
        }

        // Sync first to pull any remote workspaces, then check again
        Task {
            await SyncService.shared.performFullSync(context: modelContext)

            // After sync, check again if workspace exists
            let descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.slug == slug })
            if let existing = try? modelContext.fetch(descriptor).first {
                // Update the path and open
                existing.path = url.path
                await MainActor.run {
                    openWorkspace(existing)
                }
                return
            }

            // Still not found - create new workspace
            await MainActor.run {
                let workspace = Workspace(name: name, slug: slug, path: url.path)
                modelContext.insert(workspace)
                openWorkspace(workspace)
            }

            // Sync again to push the new workspace
            await SyncService.shared.performFullSync(context: modelContext)
        }
    }

    private func openWorkspace(_ workspace: Workspace) {
        // Update the updatedAt timestamp
        workspace.updatedAt = Date()

        openWindow(value: workspace.id)
        dismissWindow(id: "workspace-picker")
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        modelContext.delete(workspace)
    }
}

// MARK: - Recent Workspace Row

struct RecentWorkspaceRow: View {
    let workspace: Workspace
    let isHovered: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                // Folder icon with color based on path existence
                folderIcon

                // Workspace info
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let path = workspace.path {
                        Text(abbreviatePath(path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No directory")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Time ago
                Text(workspace.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // Delete button (shown on hover)
                if isHovered {
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from recent")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog("Remove Workspace?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(workspace.name)\" from your recent workspaces. The directory will not be deleted.")
        }
    }

    private var folderIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(pathExists ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .frame(width: 36, height: 36)

            Image(systemName: pathExists ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 18))
                .foregroundStyle(pathExists ? Color.accentColor : Color.secondary)
        }
    }

    private var pathExists: Bool {
        guard let path = workspace.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func abbreviatePath(_ path: String) -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }
}
#endif
