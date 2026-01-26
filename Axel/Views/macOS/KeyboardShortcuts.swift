import SwiftUI

#if os(macOS)
// MARK: - Keyboard Shortcuts

enum AppKeyboardShortcut {
    case runTerminal
    case newTerminal
    case closeTerminal

    var key: KeyEquivalent {
        switch self {
        case .runTerminal: return "r"
        case .newTerminal: return "t"
        case .closeTerminal: return "w"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .runTerminal: return .command
        case .newTerminal: return .command
        case .closeTerminal: return .command
        }
    }
}

extension View {
    func keyboardShortcut(for shortcut: AppKeyboardShortcut, action: @escaping () -> Void) -> some View {
        self.background(
            Button("") { action() }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                .hidden()
        )
    }
}
#endif
