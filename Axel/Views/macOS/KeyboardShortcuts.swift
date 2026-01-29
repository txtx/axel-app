import SwiftUI

#if os(macOS)
// MARK: - Keyboard Shortcuts

enum AppKeyboardShortcut {
    case runTerminal
    case newTerminal
    case closePane
    case showTasks
    case showAgents
    case showInbox
    case showSkills
    case undo
    case redo
    case inspectTerminal

    var key: KeyEquivalent {
        switch self {
        case .runTerminal: return "r"
        case .newTerminal: return "t"
        case .closePane: return "w"
        case .showTasks: return "1"
        case .showAgents: return "2"
        case .showInbox: return "3"
        case .showSkills: return "4"
        case .undo: return "z"
        case .redo: return "z"
        case .inspectTerminal: return "i"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .runTerminal: return .command
        case .newTerminal: return .command
        case .closePane: return .command
        case .showTasks: return .command
        case .showAgents: return .command
        case .showInbox: return .command
        case .showSkills: return .command
        case .undo: return .command
        case .redo: return [.command, .shift]
        case .inspectTerminal: return .command
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
