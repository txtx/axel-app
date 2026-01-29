// SwiftDiffs - A fast, cross-platform diff library for SwiftUI
// Inspired by @pierre/diffs, rebuilt for Apple platforms
//
// Compatible with macOS, iOS, and visionOS
//
// Features:
// - Fast Myers diff algorithm (same as git)
// - Unified and split diff views
// - Word-level inline highlighting
// - Git diff patch parsing
// - Customizable themes (GitHub light/dark, etc.)
// - High-performance virtualized views for large files
// - SwiftUI native, cross-platform
//
// Usage:
//
//     // Quick diff from strings
//     QuickDiffView(old: oldCode, new: newCode, style: .split)
//         .diffTheme(.githubDark)
//
//     // Parse and display git diff
//     let patch = PatchParser.parse(gitDiffString)
//     PatchView(patch: patch, style: .unified)
//
//     // Low-level access
//     let edits = MyersDiff.diffLines(old: oldText, new: newText)
//     let lines = MyersDiff.toDiffLines(edits: edits)
//     let hunks = MyersDiff.toHunks(lines: lines)

import Foundation
import SwiftUI

// MARK: - Version

public enum SwiftDiffs {
    public static let version = "1.0.0"
}
