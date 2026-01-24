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

#endif

@Observable
final class AppState {
    var isNewTaskPresented = false
}

@main
struct AxelApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.newTaskAction) private var newTaskAction
    let sharedContainer: ModelContainer
    #else
    // iOS/visionOS: Single database for all data
    let modelContainer: ModelContainer
    #endif
    @State private var appState = AppState()

    init() {
        #if os(macOS)
        // Initialize shared container for macOS
        do {
            let schema = Schema([
                Profile.self,
                Organization.self,
                OrganizationMember.self,
                OrganizationInvitation.self,
                Workspace.self,
                WorkTask.self,
                TaskAssignee.self,
                TaskComment.self,
                TaskAttachment.self,
                Terminal.self,
                TaskDispatch.self,
                Hint.self,
                Skill.self,
                Context.self
            ])

            let baseDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config")
                .appendingPathComponent("axel")

            // Create directory if needed
            try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

            let sharedDbUrl = baseDir.appendingPathComponent("shared.sqlite")
            let config = ModelConfiguration(
                schema: schema,
                url: sharedDbUrl,
                allowsSave: true
            )

            sharedContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to initialize shared ModelContainer: \(error)")
        }
        #else
        do {
            let schema = Schema([
                Profile.self,
                Organization.self,
                OrganizationMember.self,
                Workspace.self,
                WorkTask.self,
                TaskAssignee.self,
                TaskComment.self,
                TaskAttachment.self,
                Terminal.self,
                TaskDispatch.self,
                Hint.self,
                Skill.self,
                Context.self
            ])

            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )

            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
        #endif
    }

    var body: some Scene {
        #if os(macOS)
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
        #else
        // iOS/visionOS: Keep existing single window behavior
        WindowGroup {
            ContentView(appState: appState)
                .onOpenURL { url in
                    Task {
                        await AuthService.shared.handleOAuthCallback(url: url)
                    }
                }
        }
        .modelContainer(modelContainer)
        #endif
    }
}
