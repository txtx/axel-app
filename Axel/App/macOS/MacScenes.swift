import SwiftUI
import SwiftData

#if os(macOS)
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If no windows are visible, open the workspace picker
        if !flag {
            // Will be handled by SwiftUI's window restoration
            return true
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle OAuth callback URLs
        for url in urls {
            if url.scheme == "axel" {
                Task { @MainActor in
                    await AuthService.shared.handleOAuthCallback(url: url)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Multi-window support enabled - no longer closing extra windows
    }
}

// MARK: - Focused Scene Values for Window-Specific Actions

struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }
}

// MARK: - macOS Scene Builder

struct MacScenes: Scene {
    @Binding var appState: AppState
    let sharedContainer: ModelContainer
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newTaskAction) private var newTaskAction

    var body: some Scene {
        // Workspace Picker Window (launcher) - uses shared container for workspace metadata
        Window("Axel", id: "workspace-picker") {
            WorkspacePickerView()
        }
        .modelContainer(sharedContainer)
        .defaultSize(width: 700, height: 480)
        .windowResizability(.contentSize)

        // Workspace Windows (one per workspace) - each gets its own container
        WindowGroup("Workspace", for: UUID.self) { $workspaceId in
            if let workspaceId {
                WorkspaceWindowView(workspaceId: workspaceId)
            }
        }
        .modelContainer(sharedContainer)
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            // Cmd+N creates new task in current workspace
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    // Call the focused window's action
                    newTaskAction?()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newTaskAction == nil)

                Divider()

                Button("New Workspace Window...") {
                    openWindow(id: "workspace-picker")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}
#endif
