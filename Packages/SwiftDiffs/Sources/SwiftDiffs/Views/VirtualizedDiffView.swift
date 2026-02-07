import SwiftUI

/// A high-performance virtualized diff view for large files
/// Uses LazyVStack for efficient rendering of only visible content
public struct VirtualizedDiffView: View {
    private let diff: FileDiff
    private let style: DiffStyle
    private let inlineHighlighting: [UUID: InlineDiffLine]
    private let rowHeight: CGFloat

    @Environment(\.diffTheme) private var theme

    private let engine = DiffEngine()

    public init(
        diff: FileDiff,
        style: DiffStyle = .unified,
        inlineHighlighting: [UUID: InlineDiffLine] = [:],
        rowHeight: CGFloat = 22
    ) {
        self.diff = diff
        self.style = style
        self.inlineHighlighting = inlineHighlighting
        self.rowHeight = rowHeight
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { hunkIndex, hunk in
                        // Hunk header - sticky
                        HunkHeaderView(hunk: hunk)
                            .id("hunk-\(hunkIndex)")

                        switch style {
                        case .unified:
                            ForEach(Array(hunk.lines.enumerated()), id: \.element.id) { lineIndex, line in
                                UnifiedLineView(
                                    line: line,
                                    inlineLine: inlineHighlighting[line.id],
                                    showLineNumbers: true
                                )
                                .frame(height: rowHeight)
                                .id("line-\(hunkIndex)-\(lineIndex)")
                            }

                        case .split:
                            let rows = engine.toSplitRowsSync(hunk: hunk)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { rowIndex, row in
                                SplitRowView(
                                    row: row,
                                    leftInline: row.leftLine.flatMap { inlineHighlighting[$0.id] },
                                    rightInline: row.rightLine.flatMap { inlineHighlighting[$0.id] },
                                    showLineNumbers: true
                                )
                                .frame(height: rowHeight)
                                .id("row-\(hunkIndex)-\(rowIndex)")
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Convenience Initializers

public extension VirtualizedDiffView {
    /// Initialize with two strings to compare
    init(
        old: String,
        new: String,
        style: DiffStyle = .unified,
        contextLines: Int = 3,
        rowHeight: CGFloat = 22
    ) {
        let engine = DiffEngine()
        let diff = engine.diffSync(old: old, new: new, contextLines: contextLines)
        self.init(diff: diff, style: style, rowHeight: rowHeight)
    }

    /// Initialize with a unified diff string
    init(
        unifiedDiff: String,
        style: DiffStyle = .unified,
        rowHeight: CGFloat = 22
    ) {
        let patch = PatchParser.parse(unifiedDiff)
        let diff = patch.files.first ?? FileDiff(oldPath: nil, newPath: nil, hunks: [])
        self.init(diff: diff, style: style, rowHeight: rowHeight)
    }
}

// MARK: - Quick Diff View

/// A simple view that computes and displays a diff
public struct QuickDiffView: View {
    private let old: String
    private let new: String
    private let style: DiffStyle
    private let contextLines: Int

    @State private var diff: FileDiff?
    @State private var inlineHighlighting: [UUID: InlineDiffLine] = [:]

    public init(
        old: String,
        new: String,
        style: DiffStyle = .unified,
        contextLines: Int = 3
    ) {
        self.old = old
        self.new = new
        self.style = style
        self.contextLines = contextLines
    }

    public var body: some View {
        Group {
            if let diff = diff {
                DiffView(
                    diff: diff,
                    style: style,
                    inlineHighlighting: inlineHighlighting,
                    showFileHeader: false
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await computeDiff()
        }
    }

    private func computeDiff() async {
        let engine = DiffEngine()
        let (computedDiff, inlines) = await engine.diffWithInlineHighlighting(
            old: old,
            new: new,
            contextLines: contextLines
        )
        await MainActor.run {
            self.diff = computedDiff
            self.inlineHighlighting = inlines
        }
    }
}

// MARK: - Collapsible File Diff View

/// A diff view for a single file that can be collapsed
public struct CollapsibleFileDiffView: View {
    let diff: FileDiff
    let style: DiffStyle
    @State private var isExpanded: Bool

    @Environment(\.diffTheme) private var theme

    public init(
        diff: FileDiff,
        style: DiffStyle = .unified,
        initiallyExpanded: Bool = true
    ) {
        self.diff = diff
        self.style = style
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(diff.changeType.rawValue)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(diff.displayPath)
                        .font(theme.font)
                        .foregroundColor(.primary)

                    Spacer()

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
            .buttonStyle(.plain)

            // Content
            if isExpanded {
                VirtualizedDiffView(diff: diff, style: style)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.gutterBorder, lineWidth: 1)
        )
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
