import SwiftUI

// MARK: - Diff Models

/// Represents a line in a diff
struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

enum DiffLineType {
    case context    // Unchanged line
    case addition   // Added line
    case deletion   // Removed line
    case header     // File header or hunk header
}

// MARK: - Diff Calculator

struct DiffCalculator {
    /// Calculate diff between two strings
    static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Use a simple LCS-based diff algorithm
        let lcs = longestCommonSubsequence(oldLines, newLines)
        return buildDiffLines(oldLines: oldLines, newLines: newLines, lcs: lcs)
    }

    /// Calculate LCS matrix
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [[Int]] {
        let m = a.count
        let n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        // Handle empty arrays
        guard m > 0 && n > 0 else { return dp }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        return dp
    }

    /// Build diff lines from LCS
    private static func buildDiffLines(oldLines: [String], newLines: [String], lcs: [[Int]]) -> [DiffLine] {
        var i = oldLines.count
        var j = newLines.count
        var oldLineNum = oldLines.count
        var newLineNum = newLines.count

        var tempLines: [DiffLine] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                // Context line (same in both)
                tempLines.append(DiffLine(
                    type: .context,
                    content: oldLines[i - 1],
                    oldLineNumber: oldLineNum,
                    newLineNumber: newLineNum
                ))
                i -= 1
                j -= 1
                oldLineNum -= 1
                newLineNum -= 1
            } else if j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                // Addition
                tempLines.append(DiffLine(
                    type: .addition,
                    content: newLines[j - 1],
                    oldLineNumber: nil,
                    newLineNumber: newLineNum
                ))
                j -= 1
                newLineNum -= 1
            } else if i > 0 {
                // Deletion
                tempLines.append(DiffLine(
                    type: .deletion,
                    content: oldLines[i - 1],
                    oldLineNumber: oldLineNum,
                    newLineNumber: nil
                ))
                i -= 1
                oldLineNum -= 1
            }
        }

        return tempLines.reversed()
    }
}

// MARK: - Diff View

struct DiffView: View {
    let filePath: String
    let oldContent: String
    let newContent: String
    let isNewFile: Bool

    @State private var diffLines: [DiffLine] = []
    @State private var showUnified: Bool = true

    /// Check if there are actual changes (not just context lines)
    private var hasChanges: Bool {
        diffLines.contains { $0.type == .addition || $0.type == .deletion }
    }

    init(filePath: String, oldContent: String, newContent: String) {
        self.filePath = filePath
        self.oldContent = oldContent
        self.newContent = newContent
        self.isNewFile = oldContent.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()

            // Diff content
            if !hasChanges && oldContent == newContent {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical]) {
                    if showUnified {
                        unifiedDiffView
                    } else {
                        sideBySideDiffView
                    }
                }
            }
        }
        .onAppear {
            calculateDiff()
        }
        .onChange(of: oldContent) {
            calculateDiff()
        }
        .onChange(of: newContent) {
            calculateDiff()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: isNewFile ? "doc.badge.plus" : "doc.text")
                .foregroundStyle(isNewFile ? .green : .blue)

            Text(URL(fileURLWithPath: filePath).lastPathComponent)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            // Stats
            HStack(spacing: 12) {
                let additions = diffLines.filter { $0.type == .addition }.count
                let deletions = diffLines.filter { $0.type == .deletion }.count

                if additions > 0 {
                    Text("+\(additions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                }

                if deletions > 0 {
                    Text("-\(deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }

            // Toggle view mode
            Picker(selection: $showUnified) {
                Image(systemName: "list.bullet")
                    .tag(true)
                Image(systemName: "rectangle.split.2x1")
                    .tag(false)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("No changes")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Unified Diff View

    private var unifiedDiffView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
                unifiedDiffLine(line)
            }
        }
        .padding(8)
    }

    private func unifiedDiffLine(_ line: DiffLine) -> some View {
        HStack(spacing: 0) {
            // Line numbers
            HStack(spacing: 4) {
                Text(line.oldLineNumber.map { String($0) } ?? "")
                    .frame(width: 40, alignment: .trailing)
                Text(line.newLineNumber.map { String($0) } ?? "")
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.trailing, 8)

            // Prefix
            Text(linePrefix(for: line.type))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(lineColor(for: line.type))
                .frame(width: 16)

            // Content
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(lineColor(for: line.type))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(lineBackground(for: line.type))
    }

    // MARK: - Side-by-Side Diff View

    private var sideBySideDiffView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left side (old)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines) { line in
                    if line.type == .deletion || line.type == .context {
                        sideBySideLine(line, isOld: true)
                    } else {
                        // Placeholder for additions
                        Color.clear
                            .frame(height: 22)
                    }
                }
            }
            .frame(minWidth: 300)

            Divider()

            // Right side (new)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(diffLines) { line in
                    if line.type == .addition || line.type == .context {
                        sideBySideLine(line, isOld: false)
                    } else {
                        // Placeholder for deletions
                        Color.clear
                            .frame(height: 22)
                    }
                }
            }
            .frame(minWidth: 300)
        }
        .padding(8)
    }

    private func sideBySideLine(_ line: DiffLine, isOld: Bool) -> some View {
        HStack(spacing: 0) {
            // Line number
            Text(isOld ? (line.oldLineNumber.map { String($0) } ?? "") : (line.newLineNumber.map { String($0) } ?? ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)

            // Content
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(lineColor(for: line.type))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(lineBackground(for: line.type))
    }

    // MARK: - Helpers

    private func calculateDiff() {
        diffLines = DiffCalculator.diff(old: oldContent, new: newContent)
    }

    private func linePrefix(for type: DiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        case .header: return ""
        }
    }

    private func lineColor(for type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        case .header: return .secondary
        }
    }

    private func lineBackground(for type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green.opacity(0.1)
        case .deletion: return .red.opacity(0.1)
        case .context, .header: return .clear
        }
    }
}

// MARK: - Edit Tool Diff View

/// A view that shows the diff for an Edit tool permission request
struct EditToolDiffView: View {
    let filePath: String
    let oldString: String
    let newString: String

    var body: some View {
        DiffView(
            filePath: filePath,
            oldContent: oldString,
            newContent: newString
        )
    }
}

// MARK: - Write Tool Diff View

/// A view that shows the diff for a Write tool permission request
struct WriteToolDiffView: View {
    let filePath: String
    let content: String

    @State private var currentFileContent: String = ""
    @State private var isLoading = true
    @State private var isNewFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiffView(
                    filePath: filePath,
                    oldContent: currentFileContent,
                    newContent: content
                )
            }
        }
        .onAppear {
            loadFileContent()
        }
        .onChange(of: filePath) {
            loadFileContent()
        }
        .onChange(of: content) {
            loadFileContent()
        }
    }

    private func loadFileContent() {
        isLoading = true

        let fileURL = URL(fileURLWithPath: filePath)
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                currentFileContent = try String(contentsOf: fileURL, encoding: .utf8)
                isNewFile = false
            } catch {
                currentFileContent = ""
                isNewFile = true
            }
        } else {
            currentFileContent = ""
            isNewFile = true
        }

        isLoading = false
    }
}

// MARK: - Preview

#Preview("Diff View") {
    DiffView(
        filePath: "/path/to/file.swift",
        oldContent: """
            func hello() {
                print("Hello")
            }
            """,
        newContent: """
            func hello() {
                print("Hello, World!")
            }

            func goodbye() {
                print("Goodbye")
            }
            """
    )
    .frame(width: 600, height: 400)
}
