import SwiftUI

/// Theme configuration for diff views
public struct DiffTheme: Sendable {
    // Background colors
    public let additionBackground: Color
    public let deletionBackground: Color
    public let contextBackground: Color

    // Inline highlight colors (for word-level diffs)
    public let additionHighlight: Color
    public let deletionHighlight: Color

    // Text colors
    public let additionText: Color
    public let deletionText: Color
    public let contextText: Color
    public let lineNumberText: Color

    // Gutter colors
    public let gutterBackground: Color
    public let gutterBorder: Color

    // Hunk separator
    public let hunkSeparatorBackground: Color
    public let hunkSeparatorText: Color

    // Font settings
    public let font: Font
    public let lineNumberFont: Font

    public init(
        additionBackground: Color = Color.green.opacity(0.15),
        deletionBackground: Color = Color.red.opacity(0.15),
        contextBackground: Color = .clear,
        additionHighlight: Color = Color.green.opacity(0.35),
        deletionHighlight: Color = Color.red.opacity(0.35),
        additionText: Color = .primary,
        deletionText: Color = .primary,
        contextText: Color = .primary,
        lineNumberText: Color = .secondary,
        gutterBackground: Color = Color.gray.opacity(0.1),
        gutterBorder: Color = Color.gray.opacity(0.3),
        hunkSeparatorBackground: Color = Color.blue.opacity(0.1),
        hunkSeparatorText: Color = .blue,
        font: Font = .system(.body, design: .monospaced),
        lineNumberFont: Font = .system(.caption, design: .monospaced)
    ) {
        self.additionBackground = additionBackground
        self.deletionBackground = deletionBackground
        self.contextBackground = contextBackground
        self.additionHighlight = additionHighlight
        self.deletionHighlight = deletionHighlight
        self.additionText = additionText
        self.deletionText = deletionText
        self.contextText = contextText
        self.lineNumberText = lineNumberText
        self.gutterBackground = gutterBackground
        self.gutterBorder = gutterBorder
        self.hunkSeparatorBackground = hunkSeparatorBackground
        self.hunkSeparatorText = hunkSeparatorText
        self.font = font
        self.lineNumberFont = lineNumberFont
    }

    // MARK: - Preset Themes

    /// Default light theme
    public static let light = DiffTheme()

    /// Default dark theme
    public static let dark = DiffTheme(
        additionBackground: Color.green.opacity(0.2),
        deletionBackground: Color.red.opacity(0.2),
        additionHighlight: Color.green.opacity(0.4),
        deletionHighlight: Color.red.opacity(0.4),
        gutterBackground: Color.white.opacity(0.05),
        gutterBorder: Color.white.opacity(0.1)
    )

    /// GitHub-style theme
    public static let github = DiffTheme(
        additionBackground: Color(red: 0.87, green: 0.96, blue: 0.87),
        deletionBackground: Color(red: 1.0, green: 0.93, blue: 0.93),
        additionHighlight: Color(red: 0.67, green: 0.90, blue: 0.67),
        deletionHighlight: Color(red: 1.0, green: 0.80, blue: 0.80),
        additionText: Color(red: 0.13, green: 0.33, blue: 0.13),
        deletionText: Color(red: 0.53, green: 0.13, blue: 0.13),
        lineNumberText: Color(red: 0.6, green: 0.6, blue: 0.6),
        gutterBackground: Color(red: 0.97, green: 0.98, blue: 0.99),
        hunkSeparatorBackground: Color(red: 0.92, green: 0.96, blue: 1.0),
        hunkSeparatorText: Color(red: 0.2, green: 0.4, blue: 0.8)
    )

    /// GitHub dark theme
    public static let githubDark = DiffTheme(
        additionBackground: Color(red: 0.16, green: 0.24, blue: 0.17),
        deletionBackground: Color(red: 0.30, green: 0.17, blue: 0.17),
        additionHighlight: Color(red: 0.20, green: 0.35, blue: 0.22),
        deletionHighlight: Color(red: 0.45, green: 0.20, blue: 0.20),
        additionText: Color(red: 0.46, green: 0.87, blue: 0.46),
        deletionText: Color(red: 1.0, green: 0.53, blue: 0.53),
        lineNumberText: Color(red: 0.47, green: 0.53, blue: 0.60),
        gutterBackground: Color(red: 0.08, green: 0.09, blue: 0.11),
        gutterBorder: Color(red: 0.19, green: 0.22, blue: 0.25),
        hunkSeparatorBackground: Color(red: 0.13, green: 0.17, blue: 0.23),
        hunkSeparatorText: Color(red: 0.54, green: 0.73, blue: 0.99)
    )
}

// MARK: - Environment Key

private struct DiffThemeKey: EnvironmentKey {
    static let defaultValue = DiffTheme.light
}

public extension EnvironmentValues {
    var diffTheme: DiffTheme {
        get { self[DiffThemeKey.self] }
        set { self[DiffThemeKey.self] = newValue }
    }
}

public extension View {
    func diffTheme(_ theme: DiffTheme) -> some View {
        environment(\.diffTheme, theme)
    }
}
