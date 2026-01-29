import SwiftUI
import SwiftData
import UserNotifications

#if os(macOS)
import AppKit
import Sparkle

// MARK: - Sparkle Updater (Shared)

/// Observable state for tracking update availability
@MainActor
@Observable
final class SparkleUpdateState {
    static let shared = SparkleUpdateState()

    /// Whether an update is available
    var updateAvailable = false

    /// Version string of the available update (e.g., "1.2.0")
    var availableVersion: String?

    private init() {}
}

/// Delegate that receives Sparkle update callbacks and updates the shared state
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdaterDelegate()

    private override init() {
        super.init()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            SparkleUpdateState.shared.updateAvailable = true
            SparkleUpdateState.shared.availableVersion = item.displayVersionString
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            SparkleUpdateState.shared.updateAvailable = false
            SparkleUpdateState.shared.availableVersion = nil
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            // On error, don't show update pill
            SparkleUpdateState.shared.updateAvailable = false
            SparkleUpdateState.shared.availableVersion = nil
        }
    }
}

/// Shared Sparkle updater controller - initialized once at app launch
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: SparkleUpdaterDelegate.shared,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater {
        controller.updater
    }

    /// Trigger the update check/installation
    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        // Set ourselves as the notification delegate
        UNUserNotificationCenter.current().delegate = self

        // Initialize Sparkle updater (access shared instance to trigger initialization)
        _ = SparkleUpdater.shared
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification action responses (Approve/Reject buttons)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Handle approve/reject actions
        if actionIdentifier == "APPROVE_ACTION" || actionIdentifier == "REJECT_ACTION" {
            Task { @MainActor in
                InboxService.shared.handleNotificationAction(
                    actionIdentifier: actionIdentifier,
                    userInfo: userInfo
                )
            }
        }

        completionHandler()
    }

    /// Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound even when app is active
        completionHandler([.banner, .sound])
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
    /// Posted when a task completes on a terminal - used to trigger queue consumption
    static let taskCompletedOnTerminal = Notification.Name("taskCompletedOnTerminal")
    /// Posted when a task's status changes from running - used to trigger session cleanup
    /// userInfo: ["taskId": UUID]
    static let taskNoLongerRunning = Notification.Name("taskNoLongerRunning")
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

// MARK: - Sparkle Update View

/// SwiftUI wrapper for Sparkle's "Check for Updates" functionality
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...", action: checkForUpdatesViewModel.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// View model that observes Sparkle's updater state
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

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

            // Check for Updates in app menu
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: SparkleUpdater.shared.updater)
            }
        }
    }
}
#endif
