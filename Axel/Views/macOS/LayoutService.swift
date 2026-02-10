import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Pane Info (from axel CLI)

/// Pane configuration from AXEL.md via axel CLI
struct PaneInfo: Codable, Identifiable, Equatable {
    let type: String
    let name: String
    let color: String?
    let isAi: Bool

    var id: String { type }

    enum CodingKeys: String, CodingKey {
        case type, name, color
        case isAi = "is_ai"
    }

    /// Convert to AIProvider for compatibility
    var provider: AIProvider {
        AIProvider(shellType: type)
    }

    /// Get SwiftUI color from pane color name
    var swiftUIColor: Color {
        guard let colorName = color else { return .gray }
        switch colorName {
        case "orange": return .orange
        case "green": return .green
        case "blue": return .blue
        case "purple": return .accentPurple
        case "yellow": return .yellow
        case "red": return .red
        case "gray", "grey": return .gray
        default: return .gray
        }
    }
}

/// Grid cell information from axel CLI
struct GridCellInfo: Codable, Equatable {
    let paneType: String
    let col: Int
    let row: Int
    let width: Int?
    let height: Int?
    let color: String?

    enum CodingKeys: String, CodingKey {
        case paneType = "pane_type"
        case col, row, width, height, color
    }

    /// Get the color for this cell, falling back to a default
    var swiftUIColor: Color {
        guard let colorName = color else { return .gray }
        switch colorName.lowercased() {
        case "purple": return .accentPurple
        case "yellow": return .yellow
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "gray", "grey": return .gray
        default: return .gray
        }
    }
}

/// Grid layout information from axel CLI
struct GridInfo: Codable, Identifiable, Equatable {
    let name: String
    let type: String  // tmux, tmux_cc, shell
    let paneCount: Int
    let cells: [GridCellInfo]

    var id: String { name }

    var displayName: String {
        name == "default" ? "Default" : name.capitalized
    }

    var typeLabel: String {
        switch type {
        case "tmux_cc": return "iTerm2"
        case "shell": return "No tmux"
        default: return "tmux"
        }
    }

    /// Number of columns in this grid
    var columnCount: Int {
        (cells.map(\.col).max() ?? 0) + 1
    }

    /// Number of rows in this grid
    var rowCount: Int {
        (cells.map(\.row).max() ?? 0) + 1
    }

    /// Get cells organized by column
    var cellsByColumn: [[GridCellInfo]] {
        var columns: [[GridCellInfo]] = Array(repeating: [], count: columnCount)
        for cell in cells {
            if cell.col < columns.count {
                columns[cell.col].append(cell)
            }
        }
        // Sort each column by row
        return columns.map { $0.sorted { $0.row < $1.row } }
    }

    enum CodingKeys: String, CodingKey {
        case name, type, cells
        case paneCount = "pane_count"
    }
}

/// Combined layout output from axel CLI
struct LayoutOutput: Codable {
    let panes: [PaneInfo]
    let grids: [GridInfo]
}

// MARK: - Layout Service

/// Service to fetch layout configurations from axel CLI
@MainActor
final class LayoutService {
    static let shared = LayoutService()
    private init() {}

    /// Cached layout output to avoid redundant CLI calls
    private var cachedLayout: (path: String, output: LayoutOutput)?

    /// Fetch layout from axel CLI (cached)
    private func fetchLayout(in workspacePath: String) async -> LayoutOutput? {
        // Return cached if same path
        if let cached = cachedLayout, cached.path == workspacePath {
            return cached.output
        }

        let axelPath = AxelSetupService.shared.executablePath
        let manifestPath = (workspacePath as NSString).appendingPathComponent("AXEL.md")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [axelPath, "layout", "ls", "--json", "-m", manifestPath]
        process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let layout = try JSONDecoder().decode(LayoutOutput.self, from: data)
            cachedLayout = (workspacePath, layout)
            return layout
        } catch {
            print("[LayoutService] Failed to fetch layout: \(error)")
            return nil
        }
    }

    /// Clear cached layout (call when AXEL.md changes)
    func clearCache() {
        cachedLayout = nil
    }

    /// Fetch panes from AXEL.md via axel CLI
    func listPanes(in workspacePath: String) async -> [PaneInfo] {
        if let layout = await fetchLayout(in: workspacePath) {
            return layout.panes
        }
        // Return default panes as fallback
        return [
            PaneInfo(type: "claude", name: "Claude", color: "orange", isAi: true),
            PaneInfo(type: "codex", name: "Codex", color: "green", isAi: true),
            PaneInfo(type: "shell", name: "Shell", color: "gray", isAi: false)
        ]
    }

    /// Fetch grids from AXEL.md via axel CLI
    func listGrids(in workspacePath: String) async -> [GridInfo] {
        if let layout = await fetchLayout(in: workspacePath) {
            return layout.grids
        }
        // Return default grid as fallback
        return [GridInfo(
            name: "default",
            type: "tmux",
            paneCount: 2,
            cells: [
                GridCellInfo(paneType: "claude", col: 0, row: 0, width: 50, height: nil, color: "orange"),
                GridCellInfo(paneType: "shell", col: 1, row: 0, width: 50, height: nil, color: "gray")
            ]
        )]
    }
}

// MARK: - New Terminal Sheet

/// Sheet for creating a new terminal with worktree and shell selection
/// Supports keyboard navigation: arrow keys to move, Enter to confirm, Escape to cancel
struct NewTerminalSheet: View {
    let workspacePath: String
    let onCreateTerminal: (String?, AIProvider, String?) -> Void  // branch name (nil = main), provider, grid name (nil = default)
    @Environment(\.dismiss) private var dismiss

    @State private var worktrees: [WorktreeInfo] = []
    @State private var panes: [PaneInfo] = []
    @State private var grids: [GridInfo] = []
    @State private var selectedWorktreeIndex: Int = 0
    @State private var selectedPaneIndex: Int = 0
    @State private var selectedGridIndex: Int = 0
    @State private var focusedRow: Int = 0  // 0 = worktrees, 1 = layout, 2 = new branch input
    @State private var isGridModeSelected: Bool = false  // false = pane mode, true = grid mode
    @State private var isLoading = true
    @State private var newBranchName: String = ""
    @FocusState private var isNewBranchFieldFocused: Bool

    /// Whether the "New worktree" option is selected (last index after worktrees)
    private var isNewWorktreeSelected: Bool {
        selectedWorktreeIndex == worktrees.count
    }

    private var selectedWorktree: WorktreeInfo? {
        guard selectedWorktreeIndex < worktrees.count else { return nil }
        return worktrees[selectedWorktreeIndex]
    }

    /// The branch name to use - either from selected worktree or new branch input
    private var selectedBranchName: String? {
        if isNewWorktreeSelected {
            return newBranchName.isEmpty ? nil : newBranchName
        }
        guard let worktree = selectedWorktree else { return nil }
        return worktree.isMain ? nil : worktree.displayName
    }

    private var selectedPane: PaneInfo? {
        guard selectedPaneIndex < panes.count else { return nil }
        return panes[selectedPaneIndex]
    }

    private var selectedGrid: GridInfo? {
        guard selectedGridIndex < grids.count else { return nil }
        return grids[selectedGridIndex]
    }

    /// The grid name to pass (nil means single pane mode)
    private var selectedGridName: String? {
        // Only return grid name when user has selected grid mode
        guard isGridModeSelected, let grid = selectedGrid else { return nil }
        return grid.name
    }

    /// Whether the Create button should be disabled
    private var cannotConfirm: Bool {
        // For new worktree, require a branch name
        if isNewWorktreeSelected && newBranchName.isEmpty { return true }
        // Either a pane or a grid must be selected
        if isGridModeSelected {
            return selectedGrid == nil
        } else {
            return selectedPane == nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                VStack(spacing: 24) {
                    // Worktree selection
                    VStack(spacing: 8) {
                        Label("Worktree", systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(Array(worktrees.enumerated()), id: \.element.id) { index, worktree in
                                CompactWorktreeChip(
                                    worktree: worktree,
                                    isSelected: index == selectedWorktreeIndex && !isNewWorktreeSelected,
                                    isFocused: focusedRow == 0
                                )
                                .onTapGesture {
                                    selectedWorktreeIndex = index
                                    focusedRow = 0
                                    isNewBranchFieldFocused = false
                                }
                            }

                            // "New worktree" option
                            NewWorktreeChip(
                                isSelected: isNewWorktreeSelected,
                                isFocused: focusedRow == 0 || focusedRow == 2
                            )
                            .onTapGesture {
                                selectedWorktreeIndex = worktrees.count
                                focusedRow = 2
                                isNewBranchFieldFocused = true
                            }
                        }

                        // New branch name input (shown when "New worktree" is selected)
                        if isNewWorktreeSelected {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 14))
                                TextField("Branch name (e.g., feat/auth)", text: $newBranchName)
                                    .textFieldStyle(.plain)
                                    .focused($isNewBranchFieldFocused)
                                    .onSubmit {
                                        confirmSelection()
                                    }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(focusedRow == 2 ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                            .frame(maxWidth: 300)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -8)),
                                removal: .scale(scale: 0.9, anchor: .top).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNewWorktreeSelected)

                    // Layout selection - panes on left, grids on right
                    VStack(spacing: 8) {
                        Label("Layout", systemImage: "rectangle.split.2x1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            // Panes on the left
                            HStack(spacing: 8) {
                                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                                    CompactPaneChip(
                                        pane: pane,
                                        isSelected: !isGridModeSelected && index == selectedPaneIndex,
                                        isFocused: focusedRow == 1 && !isGridModeSelected
                                    )
                                    .onTapGesture {
                                        selectedPaneIndex = index
                                        isGridModeSelected = false
                                        focusedRow = 1
                                    }
                                }
                            }

                            // Separator and grid visualizations (always show)
                            if !grids.isEmpty {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 1)
                                    .frame(height: 40)

                                // Grid visualizations on the right
                                HStack(spacing: 12) {
                                    ForEach(Array(grids.enumerated()), id: \.element.id) { index, grid in
                                        GridVisualization(
                                            grid: grid,
                                            isSelected: isGridModeSelected && (grids.count == 1 || index == selectedGridIndex),
                                            isFocused: focusedRow == 1 && isGridModeSelected
                                        )
                                        .onTapGesture {
                                            selectedGridIndex = index
                                            isGridModeSelected = true
                                            focusedRow = 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Divider()

            // Action buttons
            HStack {
                Text("↑↓ row  ←→ select  ⏎ create  esc cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    confirmSelection()
                } label: {
                    Text("Create")
                }
                .buttonStyle(.borderedProminent)
                .disabled(cannotConfirm)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(height: 56)
        }
        .frame(width: 1000, height: isNewWorktreeSelected ? 420 : 380)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isNewWorktreeSelected)
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .keyboardNavigation(
            onUp: { moveRow(-1) },
            onDown: { moveRow(1) },
            onLeft: { moveSelection(-1) },
            onRight: { moveSelection(1) },
            onEnter: { confirmSelection() },
            onEscape: { dismiss() }
        )
        .task {
            async let worktreesTask = WorktreeService.shared.listWorktrees(in: workspacePath)
            async let panesTask = LayoutService.shared.listPanes(in: workspacePath)
            async let gridsTask = LayoutService.shared.listGrids(in: workspacePath)

            worktrees = await worktreesTask
            panes = await panesTask.filter { $0.isAi }  // Only show AI panes
            grids = await gridsTask
            isLoading = false
        }
    }

    private func moveRow(_ delta: Int) {
        // Row 0 = worktrees, Row 1 = panes, Row 2 = new branch input (only when new worktree selected)
        if isNewWorktreeSelected {
            // When new worktree is selected, allow moving to row 2 (input field)
            if delta > 0 && focusedRow == 0 {
                focusedRow = 2  // Go to input field
                isNewBranchFieldFocused = true
            } else if delta > 0 && focusedRow == 2 {
                focusedRow = 1  // Go to panes
                isNewBranchFieldFocused = false
            } else if delta < 0 && focusedRow == 1 {
                focusedRow = 2  // Go back to input field
                isNewBranchFieldFocused = true
            } else if delta < 0 && focusedRow == 2 {
                focusedRow = 0  // Go back to worktrees
                isNewBranchFieldFocused = false
            }
        } else {
            focusedRow = max(0, min(1, focusedRow + delta))
            isNewBranchFieldFocused = false
        }
    }

    private func moveSelection(_ delta: Int) {
        if focusedRow == 0 {
            let newIndex = selectedWorktreeIndex + delta
            // Include the "New worktree" option (at index worktrees.count)
            selectedWorktreeIndex = max(0, min(worktrees.count, newIndex))
            // If we selected "New worktree", focus the text field
            if isNewWorktreeSelected {
                focusedRow = 2
                isNewBranchFieldFocused = true
            }
        } else if focusedRow == 1 {
            // Row 1 has both panes and grids
            // Total items = panes.count + grids.count
            let totalItems = panes.count + grids.count

            // Current position depends on whether we're in grid mode or pane mode
            let currentPosition: Int
            if isGridModeSelected {
                currentPosition = panes.count + selectedGridIndex
            } else {
                currentPosition = selectedPaneIndex
            }
            let newPosition = max(0, min(totalItems - 1, currentPosition + delta))

            if newPosition < panes.count {
                // Moving to pane
                selectedPaneIndex = newPosition
                isGridModeSelected = false
            } else {
                // Moving to grid
                selectedGridIndex = newPosition - panes.count
                isGridModeSelected = true
            }
        }
        // Row 2 (input field) doesn't have left/right selection
    }

    private func confirmSelection() {
        // For new worktree, require a branch name
        if isNewWorktreeSelected && newBranchName.isEmpty { return }

        if isGridModeSelected, let grid = selectedGrid {
            // Grid mode - launch the full grid
            // Use the first pane's provider for tracking, or default to .claude
            let provider = panes.first?.provider ?? .claude
            onCreateTerminal(selectedBranchName, provider, grid.name)
        } else if let pane = selectedPane {
            // Pane mode - launch single pane
            onCreateTerminal(selectedBranchName, pane.provider, nil)
        }
        dismiss()
    }
}

// MARK: - Keyboard Navigation Modifier

/// View modifier that adds keyboard navigation support
struct KeyboardNavigationModifier: ViewModifier {
    let onUp: () -> Void
    let onDown: () -> Void
    let onLeft: () -> Void
    let onRight: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) { onUp(); return .handled }
            .onKeyPress(.downArrow) { onDown(); return .handled }
            .onKeyPress(.leftArrow) { onLeft(); return .handled }
            .onKeyPress(.rightArrow) { onRight(); return .handled }
            .onKeyPress(.return) { onEnter(); return .handled }
            .onKeyPress(.escape) { onEscape(); return .handled }
    }
}

extension View {
    func keyboardNavigation(
        onUp: @escaping () -> Void,
        onDown: @escaping () -> Void,
        onLeft: @escaping () -> Void,
        onRight: @escaping () -> Void,
        onEnter: @escaping () -> Void,
        onEscape: @escaping () -> Void
    ) -> some View {
        modifier(KeyboardNavigationModifier(
            onUp: onUp,
            onDown: onDown,
            onLeft: onLeft,
            onRight: onRight,
            onEnter: onEnter,
            onEscape: onEscape
        ))
    }
}

// MARK: - Compact Worktree Chip

/// Compact chip with icon on top and small label beneath
struct CompactWorktreeChip: View {
    let worktree: WorktreeInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: worktree.isMain ? "folder.fill" : "arrow.triangle.branch")
                .font(.system(size: 36))
                .foregroundStyle(worktree.isMain ? .orange : .accentPurple)

            Text(worktree.displayName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - New Worktree Chip

/// Chip for creating a new worktree with a custom branch name
struct NewWorktreeChip: View {
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 36))
                .foregroundStyle(.green)

            Text("New")
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - Compact Pane Chip

/// Compact chip with icon on top and small label beneath
struct CompactPaneChip: View {
    let pane: PaneInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return pane.swiftUIColor
        } else if isSelected {
            return pane.swiftUIColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if pane.isAi {
                    AIProviderIcon(provider: pane.provider, size: 40)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(pane.swiftUIColor)
                }
            }
            .frame(height: 50)  // Match grid visualization height

            Text(pane.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? pane.swiftUIColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
    }
}

// MARK: - Grid Visualization

/// Visual representation of a grid layout (same size as CompactPaneChip: 112x104)
struct GridVisualization: View {
    let grid: GridInfo
    let isSelected: Bool
    let isFocused: Bool

    private var borderColor: Color {
        if isSelected && isFocused {
            return .accentColor
        } else if isSelected {
            return .accentColor.opacity(0.5)
        }
        return Color.primary.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Grid visualization - larger to fill the cell
            HStack(alignment: .top, spacing: 3) {
                ForEach(Array(grid.cellsByColumn.enumerated()), id: \.offset) { colIndex, columnCells in
                    let colWidth = columnCells.first?.width ?? (100 / grid.columnCount)

                    VStack(spacing: 3) {
                        ForEach(Array(columnCells.enumerated()), id: \.offset) { rowIndex, cell in
                            // Calculate height as proportion of total column height (47 = 50 - 3 spacing)
                            let totalHeight: CGFloat = 47
                            let spacing: CGFloat = CGFloat(columnCells.count - 1) * 3
                            let availableHeight = totalHeight - spacing
                            let rowHeight = cell.height ?? (100 / columnCells.count)
                            let cellHeight = availableHeight * CGFloat(rowHeight) / 100

                            RoundedRectangle(cornerRadius: 4)
                                .fill(cell.swiftUIColor.opacity(isSelected ? 0.7 : 0.4))
                                .frame(
                                    width: CGFloat(colWidth) * 0.8,
                                    height: cellHeight
                                )
                        }
                    }
                }
            }
            .frame(width: 80, height: 50)

            Text(grid.displayName)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .frame(width: 112, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: isSelected && isFocused ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}
#endif
