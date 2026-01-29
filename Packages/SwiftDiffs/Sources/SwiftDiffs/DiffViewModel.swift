import SwiftUI
import Combine

/// Observable view model for managing diff state
@MainActor
@Observable
public final class DiffViewModel {
    public private(set) var diff: FileDiff?
    public private(set) var inlineHighlighting: [UUID: InlineDiffLine] = [:]
    public private(set) var isLoading = false
    public private(set) var error: Error?

    public var style: DiffStyle = .unified
    public var contextLines: Int = 3
    public var showLineNumbers = true
    public var showHunkHeaders = true

    private let engine = DiffEngine()

    public init() {}

    /// Compute diff between two strings
    public func computeDiff(old: String, new: String) async {
        isLoading = true
        error = nil

        let (computedDiff, inlines) = await engine.diffWithInlineHighlighting(
            old: old,
            new: new,
            contextLines: contextLines
        )
        self.diff = computedDiff
        self.inlineHighlighting = inlines
        self.isLoading = false
    }

    /// Parse a unified diff string
    public func parsePatch(_ patchString: String) {
        let patch = PatchParser.parse(patchString)
        if let firstFile = patch.files.first {
            self.diff = firstFile
        }
    }

    /// Clear the current diff
    public func clear() {
        diff = nil
        inlineHighlighting = [:]
        error = nil
    }
}

// MARK: - SwiftUI Bindings

public extension DiffViewModel {
    /// Get the view for the current diff
    @ViewBuilder
    var diffView: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = diff {
            DiffView(
                diff: diff,
                style: style,
                inlineHighlighting: inlineHighlighting,
                showLineNumbers: showLineNumbers,
                showHunkHeaders: showHunkHeaders,
                showFileHeader: false
            )
        } else if let error = error {
            VStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text(error.localizedDescription)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No diff to display")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Convenience Extensions

public extension FileDiff {
    /// Create a diff from comparing two strings
    static func from(old: String, new: String, contextLines: Int = 3) -> FileDiff {
        let engine = DiffEngine()
        return engine.diffSync(old: old, new: new, contextLines: contextLines)
    }

    /// Create a FileDiff from a unified diff string
    static func from(unifiedDiff: String) -> FileDiff? {
        let patch = PatchParser.parse(unifiedDiff)
        return patch.files.first
    }
}

public extension Patch {
    /// Create a Patch from a git diff string
    static func from(gitDiff: String) -> Patch {
        PatchParser.parse(gitDiff)
    }
}

// MARK: - View Modifiers

public extension View {
    /// Apply a diff theme based on the color scheme
    func adaptiveDiffTheme() -> some View {
        modifier(AdaptiveDiffThemeModifier())
    }
}

struct AdaptiveDiffThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.diffTheme(colorScheme == .dark ? .githubDark : .github)
    }
}

// MARK: - Scroll to Change

public struct ScrollToDiffChangeModifier: ViewModifier {
    let diff: FileDiff?
    @State private var hasScrolled = false

    public func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: diff?.id) { _, newValue in
                    if newValue != nil && !hasScrolled {
                        // Scroll to first change
                        if let firstHunk = diff?.hunks.first,
                           let firstChange = firstHunk.lines.first(where: { $0.type != .context }) {
                            withAnimation {
                                proxy.scrollTo(firstChange.id, anchor: .top)
                            }
                            hasScrolled = true
                        }
                    }
                }
        }
    }
}

public extension View {
    /// Automatically scroll to the first change when a diff is loaded
    func scrollToFirstChange(diff: FileDiff?) -> some View {
        modifier(ScrollToDiffChangeModifier(diff: diff))
    }
}
