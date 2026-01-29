import Foundation

/// Represents a single edit operation
public enum DiffEdit<T: Equatable>: Equatable {
    case equal(T)
    case insert(T)
    case delete(T)

    public var isEqual: Bool {
        if case .equal = self { return true }
        return false
    }

    public var isInsert: Bool {
        if case .insert = self { return true }
        return false
    }

    public var isDelete: Bool {
        if case .delete = self { return true }
        return false
    }

    public var value: T {
        switch self {
        case .equal(let v), .insert(let v), .delete(let v):
            return v
        }
    }
}

/// Myers' diff algorithm implementation for O(ND) time complexity
/// This is the same algorithm used by git
public enum MyersDiff {

    /// Compute the diff between two sequences
    public static func diff<T: Equatable>(
        old: [T],
        new: [T]
    ) -> [DiffEdit<T>] {
        let n = old.count
        let m = new.count
        let max = n + m

        guard max > 0 else { return [] }

        // Special cases for empty sequences
        if n == 0 {
            return new.map { .insert($0) }
        }
        if m == 0 {
            return old.map { .delete($0) }
        }

        // V array stores the furthest reaching D-path for each diagonal
        var v = [Int: Int]()
        v[1] = 0

        // Trace stores the V array at each step for backtracking
        var trace = [[Int: Int]]()

        // Find the shortest edit script
        outer: for d in 0...max {
            var newV = v

            for k in stride(from: -d, through: d, by: 2) {
                var x: Int

                // Decide whether to go down or right
                if k == -d || (k != d && v[k - 1, default: 0] < v[k + 1, default: 0]) {
                    x = v[k + 1, default: 0]
                } else {
                    x = v[k - 1, default: 0] + 1
                }

                var y = x - k

                // Follow diagonal (matching elements)
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }

                newV[k] = x

                if x >= n && y >= m {
                    trace.append(newV)
                    break outer
                }
            }

            trace.append(newV)
            v = newV
        }

        // Backtrack to build the edit script
        return backtrack(old: old, new: new, trace: trace)
    }

    private static func backtrack<T: Equatable>(
        old: [T],
        new: [T],
        trace: [[Int: Int]]
    ) -> [DiffEdit<T>] {
        var edits = [DiffEdit<T>]()
        var x = old.count
        var y = new.count

        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y

            var prevK: Int
            if k == -d || (k != d && v[k - 1, default: 0] < v[k + 1, default: 0]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }

            let prevX = v[prevK, default: 0]
            let prevY = prevX - prevK

            // Follow diagonal backwards (matching elements)
            while x > prevX && y > prevY {
                x -= 1
                y -= 1
                edits.append(.equal(old[x]))
            }

            if d > 0 {
                if x == prevX {
                    // Insert
                    y -= 1
                    edits.append(.insert(new[y]))
                } else {
                    // Delete
                    x -= 1
                    edits.append(.delete(old[x]))
                }
            }
        }

        return edits.reversed()
    }
}

// MARK: - String Extensions

public extension MyersDiff {
    /// Diff two strings line by line
    static func diffLines(old: String, new: String) -> [DiffEdit<String>] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return diff(old: oldLines, new: newLines)
    }

    /// Diff two strings word by word (for inline highlighting)
    static func diffWords(old: String, new: String) -> [DiffEdit<String>] {
        let oldWords = tokenize(old)
        let newWords = tokenize(new)
        return diff(old: oldWords, new: newWords)
    }

    /// Diff two strings character by character
    static func diffCharacters(old: String, new: String) -> [DiffEdit<Character>] {
        diff(old: Array(old), new: Array(new))
    }

    /// Tokenize a string into words and whitespace
    private static func tokenize(_ string: String) -> [String] {
        var tokens = [String]()
        var currentToken = ""
        var inWord = false

        for char in string {
            let isWordChar = char.isLetter || char.isNumber || char == "_"

            if isWordChar {
                if !inWord && !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
                inWord = true
                currentToken.append(char)
            } else {
                if inWord && !currentToken.isEmpty {
                    tokens.append(currentToken)
                    currentToken = ""
                }
                inWord = false
                currentToken.append(char)
            }
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        return tokens
    }
}

// MARK: - Conversion to DiffLines

public extension MyersDiff {
    /// Convert edits to DiffLines for display
    static func toDiffLines(edits: [DiffEdit<String>]) -> [DiffLine] {
        var lines = [DiffLine]()
        var oldLineNum = 1
        var newLineNum = 1

        for edit in edits {
            switch edit {
            case .equal(let content):
                lines.append(DiffLine(
                    type: .context,
                    content: content,
                    oldLineNumber: oldLineNum,
                    newLineNumber: newLineNum
                ))
                oldLineNum += 1
                newLineNum += 1

            case .delete(let content):
                lines.append(DiffLine(
                    type: .deletion,
                    content: content,
                    oldLineNumber: oldLineNum,
                    newLineNumber: nil
                ))
                oldLineNum += 1

            case .insert(let content):
                lines.append(DiffLine(
                    type: .addition,
                    content: content,
                    oldLineNumber: nil,
                    newLineNumber: newLineNum
                ))
                newLineNum += 1
            }
        }

        return lines
    }

    /// Group diff lines into hunks with context
    static func toHunks(
        lines: [DiffLine],
        contextLines: Int = 3
    ) -> [DiffHunk] {
        guard !lines.isEmpty else { return [] }

        // Find all change ranges
        var changeRanges = [(start: Int, end: Int)]()
        var inChange = false
        var changeStart = 0

        for (index, line) in lines.enumerated() {
            if line.type != .context {
                if !inChange {
                    changeStart = index
                    inChange = true
                }
            } else if inChange {
                changeRanges.append((changeStart, index))
                inChange = false
            }
        }

        if inChange {
            changeRanges.append((changeStart, lines.count))
        }

        guard !changeRanges.isEmpty else { return [] }

        // Merge overlapping ranges with context
        var mergedRanges = [(start: Int, end: Int)]()
        var currentStart = max(0, changeRanges[0].start - contextLines)
        var currentEnd = min(lines.count, changeRanges[0].end + contextLines)

        for i in 1..<changeRanges.count {
            let rangeStart = max(0, changeRanges[i].start - contextLines)
            let rangeEnd = min(lines.count, changeRanges[i].end + contextLines)

            if rangeStart <= currentEnd {
                currentEnd = rangeEnd
            } else {
                mergedRanges.append((currentStart, currentEnd))
                currentStart = rangeStart
                currentEnd = rangeEnd
            }
        }
        mergedRanges.append((currentStart, currentEnd))

        // Create hunks
        return mergedRanges.map { range in
            let hunkLines = Array(lines[range.start..<range.end])

            let oldStart = hunkLines.first { $0.oldLineNumber != nil }?.oldLineNumber ?? 1
            let newStart = hunkLines.first { $0.newLineNumber != nil }?.newLineNumber ?? 1

            let oldCount = hunkLines.filter { $0.type != .addition }.count
            let newCount = hunkLines.filter { $0.type != .deletion }.count

            return DiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: hunkLines
            )
        }
    }
}
