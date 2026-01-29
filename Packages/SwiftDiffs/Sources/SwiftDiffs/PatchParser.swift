import Foundation

/// Parser for unified diff format (git diff output)
public enum PatchParser {

    /// Parse a unified diff string into a Patch
    public static func parse(_ diffString: String) -> Patch {
        let lines = diffString.components(separatedBy: "\n")
        var files = [FileDiff]()
        var currentFile: FileBuilder?
        var currentHunk: HunkBuilder?

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // New file diff header
            if line.hasPrefix("diff --git") {
                // Save previous file
                if let file = currentFile?.build(currentHunk: currentHunk) {
                    files.append(file)
                }
                currentFile = FileBuilder()
                currentHunk = nil

                // Parse file paths from diff line
                if let paths = parseGitDiffLine(line) {
                    currentFile?.oldPath = paths.old
                    currentFile?.newPath = paths.new
                }
            }
            // Old file path
            else if line.hasPrefix("---") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentFile?.oldPath = path.hasPrefix("a/") ? String(path.dropFirst(2)) : path
                }
            }
            // New file path
            else if line.hasPrefix("+++") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentFile?.newPath = path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
                } else {
                    currentFile?.changeType = .deleted
                }
            }
            // New file indicator
            else if line.hasPrefix("new file mode") {
                currentFile?.changeType = .added
            }
            // Deleted file indicator
            else if line.hasPrefix("deleted file mode") {
                currentFile?.changeType = .deleted
            }
            // Rename indicator
            else if line.hasPrefix("rename from") || line.hasPrefix("rename to") {
                currentFile?.changeType = .renamed
            }
            // Hunk header
            else if line.hasPrefix("@@") {
                // Save previous hunk
                if let hunk = currentHunk?.build() {
                    currentFile?.hunks.append(hunk)
                }

                if let header = parseHunkHeader(line) {
                    currentHunk = HunkBuilder(
                        oldStart: header.oldStart,
                        oldCount: header.oldCount,
                        newStart: header.newStart,
                        newCount: header.newCount,
                        header: header.function
                    )
                }
            }
            // Content lines
            else if currentHunk != nil {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    currentHunk?.addLine(type: .addition, content: String(line.dropFirst()))
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    currentHunk?.addLine(type: .deletion, content: String(line.dropFirst()))
                } else if line.hasPrefix(" ") || line.isEmpty {
                    let content = line.isEmpty ? "" : String(line.dropFirst())
                    currentHunk?.addLine(type: .context, content: content)
                } else if line.hasPrefix("\\") {
                    // "\ No newline at end of file" - skip
                }
            }

            i += 1
        }

        // Save last file
        if let file = currentFile?.build(currentHunk: currentHunk) {
            files.append(file)
        }

        return Patch(files: files)
    }

    /// Parse a simple two-file diff (not full git format)
    public static func parseSimpleDiff(_ diffString: String) -> FileDiff? {
        let lines = diffString.components(separatedBy: "\n")
        var hunks = [DiffHunk]()
        var currentHunk: HunkBuilder?

        for line in lines {
            if line.hasPrefix("@@") {
                if let hunk = currentHunk?.build() {
                    hunks.append(hunk)
                }

                if let header = parseHunkHeader(line) {
                    currentHunk = HunkBuilder(
                        oldStart: header.oldStart,
                        oldCount: header.oldCount,
                        newStart: header.newStart,
                        newCount: header.newCount,
                        header: header.function
                    )
                }
            } else if currentHunk != nil {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    currentHunk?.addLine(type: .addition, content: String(line.dropFirst()))
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    currentHunk?.addLine(type: .deletion, content: String(line.dropFirst()))
                } else if line.hasPrefix(" ") {
                    currentHunk?.addLine(type: .context, content: String(line.dropFirst()))
                }
            }
        }

        if let hunk = currentHunk?.build() {
            hunks.append(hunk)
        }

        guard !hunks.isEmpty else { return nil }

        return FileDiff(oldPath: nil, newPath: nil, hunks: hunks)
    }

    // MARK: - Private Helpers

    private static func parseGitDiffLine(_ line: String) -> (old: String, new: String)? {
        // Format: diff --git a/path b/path
        let pattern = #"diff --git a/(.+) b/(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..., in: line)
              ) else {
            return nil
        }

        guard let oldRange = Range(match.range(at: 1), in: line),
              let newRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        return (String(line[oldRange]), String(line[newRange]))
    }

    private static func parseHunkHeader(_ line: String) -> HunkHeader? {
        // Format: @@ -oldStart,oldCount +newStart,newCount @@ optional function context
        let pattern = #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..., in: line)
              ) else {
            return nil
        }

        func intValue(at index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return Int(line[range])
        }

        let oldStart = intValue(at: 1) ?? 1
        let oldCount = intValue(at: 2) ?? 1
        let newStart = intValue(at: 3) ?? 1
        let newCount = intValue(at: 4) ?? 1

        var function: String?
        if let range = Range(match.range(at: 5), in: line) {
            let f = line[range].trimmingCharacters(in: .whitespaces)
            if !f.isEmpty {
                function = f
            }
        }

        return HunkHeader(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            function: function
        )
    }
}

// MARK: - Builder Helpers

private struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let function: String?
}

private class FileBuilder {
    var oldPath: String?
    var newPath: String?
    var hunks = [DiffHunk]()
    var changeType: FileChangeType = .modified

    func build(currentHunk: HunkBuilder?) -> FileDiff? {
        if let hunk = currentHunk?.build() {
            hunks.append(hunk)
        }

        guard !hunks.isEmpty || changeType == .added || changeType == .deleted else {
            return nil
        }

        return FileDiff(
            oldPath: oldPath,
            newPath: newPath,
            hunks: hunks,
            changeType: changeType
        )
    }
}

private class HunkBuilder {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let header: String?

    private var lines = [DiffLine]()
    private var currentOldLine: Int
    private var currentNewLine: Int

    init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String?) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.currentOldLine = oldStart
        self.currentNewLine = newStart
    }

    func addLine(type: DiffLineType, content: String) {
        let oldNum: Int?
        let newNum: Int?

        switch type {
        case .context:
            oldNum = currentOldLine
            newNum = currentNewLine
            currentOldLine += 1
            currentNewLine += 1
        case .deletion:
            oldNum = currentOldLine
            newNum = nil
            currentOldLine += 1
        case .addition:
            oldNum = nil
            newNum = currentNewLine
            currentNewLine += 1
        }

        lines.append(DiffLine(
            type: type,
            content: content,
            oldLineNumber: oldNum,
            newLineNumber: newNum
        ))
    }

    func build() -> DiffHunk {
        DiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            lines: lines,
            header: header
        )
    }
}
