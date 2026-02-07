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
    @State private var selectedWorkspaceId: UUID?
    @State private var hoveredWorkspaceId: UUID?
    @State private var isTargeted = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var selectedIndex: Int? {
        guard let selectedId = selectedWorkspaceId else { return nil }
        return workspaces.firstIndex { $0.id == selectedId }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left side - Branding and Actions
            brandingPanel

            // Right side - Recent Workspaces
            recentWorkspacesPanel
        }
        .frame(width: 760, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.return) { openSelectedWorkspace(); return .handled }
        .onKeyPress(.escape) { dismissWindow(id: "workspace-picker"); return .handled }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .onAppear {
            // Select first workspace by default
            if selectedWorkspaceId == nil, let first = workspaces.first {
                selectedWorkspaceId = first.id
            }

            // Show only the red close button, hide minimize and zoom
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for window in NSApplication.shared.windows {
                    if window.identifier?.rawValue == "workspace-picker" ||
                       window.title == "Axel" {
                        // Hide minimize and zoom, keep close
                        for buttonType: NSWindow.ButtonType in [.miniaturizeButton, .zoomButton] {
                            if let button = window.standardWindowButton(buttonType) {
                                button.isHidden = true
                            }
                        }
                        break
                    }
                }
            }
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !workspaces.isEmpty else { return }

        if let currentIndex = selectedIndex {
            let newIndex = max(0, min(workspaces.count - 1, currentIndex + delta))
            selectedWorkspaceId = workspaces[newIndex].id
        } else {
            selectedWorkspaceId = workspaces.first?.id
        }
    }

    private func openSelectedWorkspace() {
        guard let selectedId = selectedWorkspaceId,
              let workspace = workspaces.first(where: { $0.id == selectedId }) else { return }
        openWorkspace(workspace)
    }

    // MARK: - Branding Panel (Left)

    private var brandingPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon and title
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)

                VStack(spacing: 2) {
                    Text("Axel")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white)

                    Text("Version \(appVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }

            Spacer()

            // Action buttons
            VStack(spacing: 6) {
                XcodeStyleButton(
                    icon: "folder",
                    title: "Open Workspace...",
                    action: selectDirectory
                )
            }
            .padding(.horizontal, 24)

            Spacer()
                .frame(height: 40)
        }
        .frame(width: 280)
        .background(Color(white: 0.12))
    }

    // MARK: - Recent Workspaces Panel (Right)

    private var recentWorkspacesPanel: some View {
        VStack(spacing: 0) {
            if workspaces.isEmpty {
                recentEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaces) { workspace in
                            RecentWorkspaceRow(
                                workspace: workspace,
                                isSelected: selectedWorkspaceId == workspace.id,
                                isHovered: hoveredWorkspaceId == workspace.id,
                                onOpen: { openWorkspace(workspace) },
                                onDelete: { deleteWorkspace(workspace) }
                            )
                            .onTapGesture(count: 2) {
                                openWorkspace(workspace)
                            }
                            .onTapGesture(count: 1) {
                                selectedWorkspaceId = workspace.id
                            }
                            .onHover { isHovered in
                                hoveredWorkspaceId = isHovered ? workspace.id : nil
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.18))
    }

    private var recentEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(Color.white.opacity(0.2))

            Text("No Recent Workspaces")
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.5))

            Text("Workspaces you open will appear here")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.3))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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

// MARK: - Xcode-Style Button

struct XcodeStyleButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Icon in dark rounded rect
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.1))
                    )

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.85))

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Recent Workspace Row

struct RecentWorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isHovered: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    private var pathExists: Bool {
        guard let path = workspace.path else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Folder icon (Xcode-style)
            folderIcon

            // Workspace info
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.9))
                    .lineLimit(1)

                if let path = workspace.path {
                    Text(abbreviatePath(path))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : Color.white.opacity(0.45))
                        .lineLimit(1)
                } else {
                    Text("No directory")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.5) : Color.white.opacity(0.3))
                }
            }

            Spacer()

            // Delete button (shown on hover, not when selected)
            if isHovered && !isSelected {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Remove from recent")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Group {
                if isSelected {
                    Color.accentColor
                } else if isHovered {
                    Color.white.opacity(0.06)
                } else {
                    Color.clear
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .confirmationDialog("Remove Workspace?", isPresented: $showDeleteConfirmation) {
            Button("Remove", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(workspace.name)\" from your recent workspaces. The directory will not be deleted.")
        }
    }

    private var folderIcon: some View {
        Image(systemName: pathExists ? "folder.fill" : "folder.badge.questionmark")
            .font(.system(size: 28))
            .foregroundStyle(isSelected ? .white : Color(red: 0.35, green: 0.78, blue: 0.98))
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
