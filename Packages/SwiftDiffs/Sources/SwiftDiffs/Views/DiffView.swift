import SwiftUI

/// The style of diff display
public enum DiffStyle: String, CaseIterable, Sendable {
    case unified
    case split
}

/// A flexible diff view that supports both unified and split styles
public struct DiffView: View {
    private let diff: FileDiff
    private let style: DiffStyle
    private let inlineHighlighting: [UUID: InlineDiffLine]
    private let showLineNumbers: Bool
    private let showHunkHeaders: Bool
    private let showFileHeader: Bool

    @Environment(\.diffTheme) private var theme

    public init(
        diff: FileDiff,
        style: DiffStyle = .unified,
        inlineHighlighting: [UUID: InlineDiffLine] = [:],
        showLineNumbers: Bool = true,
        showHunkHeaders: Bool = true,
        showFileHeader: Bool = true
    ) {
        self.diff = diff
        self.style = style
        self.inlineHighlighting = inlineHighlighting
        self.showLineNumbers = showLineNumbers
        self.showHunkHeaders = showHunkHeaders
        self.showFileHeader = showFileHeader
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showFileHeader {
                FileHeaderView(diff: diff)
            }

            switch style {
            case .unified:
                UnifiedDiffView(
                    diff: diff,
                    inlineHighlighting: inlineHighlighting,
                    showLineNumbers: showLineNumbers,
                    showHunkHeaders: showHunkHeaders
                )

            case .split:
                SplitDiffView(
                    diff: diff,
                    inlineHighlighting: inlineHighlighting,
                    showLineNumbers: showLineNumbers,
                    showHunkHeaders: showHunkHeaders
                )
            }
        }
    }
}

// MARK: - File Header View

struct FileHeaderView: View {
    let diff: FileDiff

    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            // Change type badge
            Text(diff.changeType.rawValue)
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(badgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // File path
            Text(diff.displayPath)
                .font(theme.font)
                .foregroundColor(.primary)

            Spacer()

            // Stats
            HStack(spacing: 4) {
                if diff.additions > 0 {
                    Text("+\(diff.additions)")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                }
                if diff.deletions > 0 {
                    Text("-\(diff.deletions)")
                        .font(.caption.bold())
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(theme.gutterBackground)
    }

    private var badgeColor: Color {
        switch diff.changeType {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .blue
        case .renamed: return .orange
        case .copied: return .diffPurple
        }
    }
}

// MARK: - Multi-File Diff View

/// A view for displaying multiple file diffs (e.g., from a patch)
public struct PatchView: View {
    private let patch: Patch
    private let style: DiffStyle
    private let expandedFiles: Set<UUID>?

    @Environment(\.diffTheme) private var theme

    public init(
        patch: Patch,
        style: DiffStyle = .unified,
        expandedFiles: Set<UUID>? = nil
    ) {
        self.patch = patch
        self.style = style
        self.expandedFiles = expandedFiles
    }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Summary header
                PatchSummaryView(patch: patch)

                // File diffs
                ForEach(patch.files) { file in
                    DiffView(
                        diff: file,
                        style: style,
                        showFileHeader: true
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.gutterBorder, lineWidth: 1)
                    )
                }
            }
            .padding()
        }
    }
}

// MARK: - Patch Summary

struct PatchSummaryView: View {
    let patch: Patch

    var body: some View {
        HStack(spacing: 16) {
            Label("\(patch.files.count) files", systemImage: "doc.fill")
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .foregroundColor(.green)
                Text("\(patch.totalAdditions)")
                    .foregroundColor(.green)
            }

            HStack(spacing: 4) {
                Image(systemName: "minus")
                    .foregroundColor(.red)
                Text("\(patch.totalDeletions)")
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .font(.subheadline)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: - Interactive Diff View

/// An interactive diff view with controls
public struct InteractiveDiffView: View {
    private let diff: FileDiff
    @State private var style: DiffStyle
    @State private var showLineNumbers: Bool

    @Environment(\.diffTheme) private var theme

    public init(
        diff: FileDiff,
        initialStyle: DiffStyle = .unified,
        showLineNumbers: Bool = true
    ) {
        self.diff = diff
        self._style = State(initialValue: initialStyle)
        self._showLineNumbers = State(initialValue: showLineNumbers)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("Style", selection: $style) {
                    Text("Unified").tag(DiffStyle.unified)
                    Text("Split").tag(DiffStyle.split)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                Spacer()

                Toggle("Line #", isOn: $showLineNumbers)
                    .toggleStyle(.button)
            }
            .padding(8)
            .background(theme.gutterBackground)

            // Diff content
            DiffView(
                diff: diff,
                style: style,
                showLineNumbers: showLineNumbers,
                showHunkHeaders: true,
                showFileHeader: false
            )
        }
    }
}
