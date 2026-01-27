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

// MARK: - Notification Names for View Switching

extension Notification.Name {
    static let showTasks = Notification.Name("showTasks")
    static let showAgents = Notification.Name("showAgents")
    static let showInbox = Notification.Name("showInbox")
    static let showSkills = Notification.Name("showSkills")
    static let runTaskTriggered = Notification.Name("runTaskTriggered")
    static let deleteTasksTriggered = Notification.Name("deleteTasksTriggered")
    static let completeTaskTriggered = Notification.Name("completeTaskTriggered")
    static let cancelTaskTriggered = Notification.Name("cancelTaskTriggered")
}

// MARK: - Focused Scene Values for Window-Specific Actions

struct NewTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RunTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct DeleteTasksActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct CompleteTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct CancelTaskActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newTaskAction: (() -> Void)? {
        get { self[NewTaskActionKey.self] }
        set { self[NewTaskActionKey.self] = newValue }
    }

    var runTaskAction: (() -> Void)? {
        get { self[RunTaskActionKey.self] }
        set { self[RunTaskActionKey.self] = newValue }
    }

    var deleteTasksAction: (() -> Void)? {
        get { self[DeleteTasksActionKey.self] }
        set { self[DeleteTasksActionKey.self] = newValue }
    }

    var completeTaskAction: (() -> Void)? {
        get { self[CompleteTaskActionKey.self] }
        set { self[CompleteTaskActionKey.self] = newValue }
    }

    var cancelTaskAction: (() -> Void)? {
        get { self[CancelTaskActionKey.self] }
        set { self[CancelTaskActionKey.self] = newValue }
    }
}

// MARK: - macOS Scene Builder

struct MacScenes: Scene {
    @Binding var appState: AppState
    let sharedContainer: ModelContainer
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newTaskAction) private var newTaskAction
    @FocusedValue(\.runTaskAction) private var runTaskAction
    @FocusedValue(\.deleteTasksAction) private var deleteTasksAction
    @FocusedValue(\.completeTaskAction) private var completeTaskAction
    @FocusedValue(\.cancelTaskAction) private var cancelTaskAction

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

            // Task menu
            CommandMenu("Task") {
                Button("Run") {
                    runTaskAction?()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(runTaskAction == nil)

                Divider()

                Button("Complete") {
                    completeTaskAction?()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(completeTaskAction == nil)

                Button("Cancel") {
                    cancelTaskAction?()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(cancelTaskAction == nil)

                Divider()

                Button("Delete") {
                    deleteTasksAction?()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteTasksAction == nil)
            }

            // Add to existing View menu
            CommandGroup(after: .toolbar) {
                Divider()

                Button {
                    NotificationCenter.default.post(name: .showTasks, object: nil)
                } label: {
                    Label("Show Tasks", systemImage: "rectangle.stack")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .showAgents, object: nil)
                } label: {
                    Label("Show Agents", systemImage: "terminal")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .showInbox, object: nil)
                } label: {
                    Label("Show Inbox", systemImage: "tray.fill")
                }
                .keyboardShortcut("3", modifiers: .command)

                Button {
                    NotificationCenter.default.post(name: .showSkills, object: nil)
                } label: {
                    Label("Show Optimizations", systemImage: "gauge.with.dots.needle.50percent")
                }
                .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
#endif
