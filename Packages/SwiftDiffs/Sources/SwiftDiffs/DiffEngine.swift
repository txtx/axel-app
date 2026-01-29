import Foundation

/// High-level diff engine for computing and working with diffs
public actor DiffEngine {
    public init() {}

    /// Compute diff between two strings
    public func diff(old: String, new: String, contextLines: Int = 3) -> FileDiff {
        let edits = MyersDiff.diffLines(old: old, new: new)
        let lines = MyersDiff.toDiffLines(edits: edits)
        let hunks = MyersDiff.toHunks(lines: lines, contextLines: contextLines)

        return FileDiff(
            oldPath: nil,
            newPath: nil,
            hunks: hunks
        )
    }

    /// Compute diff with inline (word-level) highlighting
    public func diffWithInlineHighlighting(
        old: String,
        new: String,
        contextLines: Int = 3
    ) -> (diff: FileDiff, inlineLines: [UUID: InlineDiffLine]) {
        let fileDiff = diff(old: old, new: new, contextLines: contextLines)
        var inlineLines = [UUID: InlineDiffLine]()

        // Process consecutive deletion/addition pairs for inline highlighting
        for hunk in fileDiff.hunks {
            let lines = hunk.lines
            var i = 0

            while i < lines.count {
                // Look for deletion followed by addition
                if lines[i].type == .deletion {
                    var deletions = [DiffLine]()
                    var j = i

                    while j < lines.count && lines[j].type == .deletion {
                        deletions.append(lines[j])
                        j += 1
                    }

                    var additions = [DiffLine]()
                    while j < lines.count && lines[j].type == .addition {
                        additions.append(lines[j])
                        j += 1
                    }

                    // If we have matched deletions and additions, compute inline diff
                    if !deletions.isEmpty && !additions.isEmpty {
                        let pairs = min(deletions.count, additions.count)

                        for k in 0..<pairs {
                            let delLine = deletions[k]
                            let addLine = additions[k]

                            let wordEdits = MyersDiff.diffWords(
                                old: delLine.content,
                                new: addLine.content
                            )

                            // Create inline segments for deletion
                            var delSegments = [InlineSegment]()
                            var addSegments = [InlineSegment]()

                            for edit in wordEdits {
                                switch edit {
                                case .equal(let text):
                                    delSegments.append(InlineSegment(text: text, isChanged: false))
                                    addSegments.append(InlineSegment(text: text, isChanged: false))
                                case .delete(let text):
                                    delSegments.append(InlineSegment(text: text, isChanged: true))
                                case .insert(let text):
                                    addSegments.append(InlineSegment(text: text, isChanged: true))
                                }
                            }

                            inlineLines[delLine.id] = InlineDiffLine(
                                type: .deletion,
                                segments: delSegments,
                                oldLineNumber: delLine.oldLineNumber,
                                newLineNumber: nil
                            )

                            inlineLines[addLine.id] = InlineDiffLine(
                                type: .addition,
                                segments: addSegments,
                                oldLineNumber: nil,
                                newLineNumber: addLine.newLineNumber
                            )
                        }
                    }

                    i = j
                } else {
                    i += 1
                }
            }
        }

        return (fileDiff, inlineLines)
    }

    /// Convert a unified diff to split view rows
    public func toSplitRows(hunk: DiffHunk) -> [SplitDiffRow] {
        var rows = [SplitDiffRow]()
        let lines = hunk.lines
        var i = 0

        while i < lines.count {
            let line = lines[i]

            switch line.type {
            case .context:
                rows.append(SplitDiffRow(leftLine: line, rightLine: line))
                i += 1

            case .deletion:
                // Collect consecutive deletions
                var deletions = [DiffLine]()
                var j = i
                while j < lines.count && lines[j].type == .deletion {
                    deletions.append(lines[j])
                    j += 1
                }

                // Collect consecutive additions
                var additions = [DiffLine]()
                while j < lines.count && lines[j].type == .addition {
                    additions.append(lines[j])
                    j += 1
                }

                // Pair them up
                let maxCount = max(deletions.count, additions.count)
                for k in 0..<maxCount {
                    let del = k < deletions.count ? deletions[k] : nil
                    let add = k < additions.count ? additions[k] : nil
                    rows.append(SplitDiffRow(leftLine: del, rightLine: add))
                }

                i = j

            case .addition:
                // Standalone addition (no preceding deletion)
                rows.append(SplitDiffRow(leftLine: nil, rightLine: line))
                i += 1
            }
        }

        return rows
    }
}

// MARK: - Synchronous convenience methods

public extension DiffEngine {
    /// Synchronous diff computation for simple use cases
    nonisolated func diffSync(old: String, new: String, contextLines: Int = 3) -> FileDiff {
        let edits = MyersDiff.diffLines(old: old, new: new)
        let lines = MyersDiff.toDiffLines(edits: edits)
        let hunks = MyersDiff.toHunks(lines: lines, contextLines: contextLines)

        return FileDiff(
            oldPath: nil,
            newPath: nil,
            hunks: hunks
        )
    }

    /// Synchronous split rows conversion
    nonisolated func toSplitRowsSync(hunk: DiffHunk) -> [SplitDiffRow] {
        var rows = [SplitDiffRow]()
        let lines = hunk.lines
        var i = 0

        while i < lines.count {
            let line = lines[i]

            switch line.type {
            case .context:
                rows.append(SplitDiffRow(leftLine: line, rightLine: line))
                i += 1

            case .deletion:
                var deletions = [DiffLine]()
                var j = i
                while j < lines.count && lines[j].type == .deletion {
                    deletions.append(lines[j])
                    j += 1
                }

                var additions = [DiffLine]()
                while j < lines.count && lines[j].type == .addition {
                    additions.append(lines[j])
                    j += 1
                }

                let maxCount = max(deletions.count, additions.count)
                for k in 0..<maxCount {
                    let del = k < deletions.count ? deletions[k] : nil
                    let add = k < additions.count ? additions[k] : nil
                    rows.append(SplitDiffRow(leftLine: del, rightLine: add))
                }

                i = j

            case .addition:
                rows.append(SplitDiffRow(leftLine: nil, rightLine: line))
                i += 1
            }
        }

        return rows
    }
}
