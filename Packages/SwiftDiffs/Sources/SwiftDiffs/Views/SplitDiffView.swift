import SwiftUI

/// A split diff view (side-by-side comparison)
public struct SplitDiffView: View {
    private let diff: FileDiff
    private let inlineHighlighting: [UUID: InlineDiffLine]
    private let showLineNumbers: Bool
    private let showHunkHeaders: Bool

    @Environment(\.diffTheme) private var theme

    private let engine = DiffEngine()

    public init(
        diff: FileDiff,
        inlineHighlighting: [UUID: InlineDiffLine] = [:],
        showLineNumbers: Bool = true,
        showHunkHeaders: Bool = true
    ) {
        self.diff = diff
        self.inlineHighlighting = inlineHighlighting
        self.showLineNumbers = showLineNumbers
        self.showHunkHeaders = showHunkHeaders
    }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.hunks) { hunk in
                    if showHunkHeaders {
                        HunkHeaderView(hunk: hunk)
                    }

                    let rows = engine.toSplitRowsSync(hunk: hunk)
                    ForEach(rows) { row in
                        SplitRowView(
                            row: row,
                            leftInline: row.leftLine.flatMap { inlineHighlighting[$0.id] },
                            rightInline: row.rightLine.flatMap { inlineHighlighting[$0.id] },
                            showLineNumbers: showLineNumbers
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Split Row View

struct SplitRowView: View {
    let row: SplitDiffRow
    let leftInline: InlineDiffLine?
    let rightInline: InlineDiffLine?
    let showLineNumbers: Bool

    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Left side (old)
            SplitSideView(
                line: row.leftLine,
                inlineLine: leftInline,
                showLineNumbers: showLineNumbers,
                isLeftSide: true
            )

            // Divider
            Rectangle()
                .fill(theme.gutterBorder)
                .frame(width: 1)

            // Right side (new)
            SplitSideView(
                line: row.rightLine,
                inlineLine: rightInline,
                showLineNumbers: showLineNumbers,
                isLeftSide: false
            )
        }
        .frame(minHeight: 20)
    }
}

// MARK: - Split Side View

struct SplitSideView: View {
    let line: DiffLine?
    let inlineLine: InlineDiffLine?
    let showLineNumbers: Bool
    let isLeftSide: Bool

    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showLineNumbers {
                // Line number
                let lineNum = isLeftSide ? line?.oldLineNumber : line?.newLineNumber
                Text(lineNum.map { String($0) } ?? "")
                    .font(theme.lineNumberFont)
                    .foregroundColor(theme.lineNumberText)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 4)
                    .background(theme.gutterBackground)

                Rectangle()
                    .fill(theme.gutterBorder)
                    .frame(width: 1)
            }

            // Content
            if let line = line {
                if let inlineLine = inlineLine {
                    InlineHighlightedText(segments: inlineLine.segments, lineType: line.type)
                        .font(theme.font)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(backgroundColor(for: line.type))
                } else {
                    Text(line.content)
                        .font(theme.font)
                        .foregroundColor(textColor(for: line.type))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .background(backgroundColor(for: line.type))
                }
            } else {
                // Empty placeholder
                Text("")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(theme.gutterBackground.opacity(0.5))
            }
        }
    }

    private func backgroundColor(for type: DiffLineType) -> Color {
        switch type {
        case .context: return theme.contextBackground
        case .addition: return theme.additionBackground
        case .deletion: return theme.deletionBackground
        }
    }

    private func textColor(for type: DiffLineType) -> Color {
        switch type {
        case .context: return theme.contextText
        case .addition: return theme.additionText
        case .deletion: return theme.deletionText
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SplitDiffView_Previews: PreviewProvider {
    static var previews: some View {
        let engine = DiffEngine()
        let old = """
        function hello() {
            console.log("Hello, World!");
            return true;
        }
        """
        let new = """
        function hello() {
            console.log("Hello, Swift!");
            console.log("Welcome!");
            return true;
        }
        """
        let diff = engine.diffSync(old: old, new: new)

        SplitDiffView(diff: diff)
            .diffTheme(.githubDark)
            .frame(width: 800, height: 400)
    }
}
#endif
