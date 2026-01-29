import SwiftUI

/// A unified diff view (traditional single-column diff display)
public struct UnifiedDiffView: View {
    private let diff: FileDiff
    private let inlineHighlighting: [UUID: InlineDiffLine]
    private let showLineNumbers: Bool
    private let showHunkHeaders: Bool

    @Environment(\.diffTheme) private var theme

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

                    ForEach(hunk.lines) { line in
                        UnifiedLineView(
                            line: line,
                            inlineLine: inlineHighlighting[line.id],
                            showLineNumbers: showLineNumbers
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Hunk Header

struct HunkHeaderView: View {
    let hunk: DiffHunk
    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text(hunk.headerString)
                .font(theme.font)
                .foregroundColor(theme.hunkSeparatorText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Spacer()
        }
        .background(theme.hunkSeparatorBackground)
    }
}

// MARK: - Unified Line View

struct UnifiedLineView: View {
    let line: DiffLine
    let inlineLine: InlineDiffLine?
    let showLineNumbers: Bool

    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if showLineNumbers {
                // Old line number
                Text(line.oldLineNumber.map { String($0) } ?? "")
                    .font(theme.lineNumberFont)
                    .foregroundColor(theme.lineNumberText)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 4)
                    .background(theme.gutterBackground)

                // New line number
                Text(line.newLineNumber.map { String($0) } ?? "")
                    .font(theme.lineNumberFont)
                    .foregroundColor(theme.lineNumberText)
                    .frame(width: 40, alignment: .trailing)
                    .padding(.trailing, 4)
                    .background(theme.gutterBackground)

                // Separator
                Rectangle()
                    .fill(theme.gutterBorder)
                    .frame(width: 1)
            }

            // Change indicator
            Text(indicator)
                .font(theme.font)
                .foregroundColor(textColor)
                .frame(width: 16, alignment: .center)

            // Content
            if let inlineLine = inlineLine {
                InlineHighlightedText(segments: inlineLine.segments, lineType: line.type)
                    .font(theme.font)
            } else {
                Text(line.content)
                    .font(theme.font)
                    .foregroundColor(textColor)
            }

            Spacer(minLength: 0)
        }
        .background(backgroundColor)
        .frame(minHeight: 20)
    }

    private var indicator: String {
        switch line.type {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .context: return theme.contextBackground
        case .addition: return theme.additionBackground
        case .deletion: return theme.deletionBackground
        }
    }

    private var textColor: Color {
        switch line.type {
        case .context: return theme.contextText
        case .addition: return theme.additionText
        case .deletion: return theme.deletionText
        }
    }
}

// MARK: - Inline Highlighted Text

struct InlineHighlightedText: View {
    let segments: [InlineSegment]
    let lineType: DiffLineType

    @Environment(\.diffTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                Text(segment.text)
                    .foregroundColor(textColor)
                    .background(segment.isChanged ? highlightColor : .clear)
            }
        }
    }

    private var textColor: Color {
        switch lineType {
        case .context: return theme.contextText
        case .addition: return theme.additionText
        case .deletion: return theme.deletionText
        }
    }

    private var highlightColor: Color {
        switch lineType {
        case .context: return .clear
        case .addition: return theme.additionHighlight
        case .deletion: return theme.deletionHighlight
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UnifiedDiffView_Previews: PreviewProvider {
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

        UnifiedDiffView(diff: diff)
            .diffTheme(.github)
            .frame(width: 600, height: 400)
    }
}
#endif
