import SwiftUI
import SwiftData

/// Check if running UI tests
var isUITesting: Bool {
    ProcessInfo.processInfo.arguments.contains("--ui-testing")
}

@Observable
final class AppState {
    var isNewTaskPresented = false
    #if os(visionOS)
    var immersionState: ImmersionState = .closed

    enum ImmersionState: Equatable {
        case closed
        case inTransition
        case open
    }
    #endif
}

@main
struct AxelApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let sharedContainer: ModelContainer
    #else
    let modelContainer: ModelContainer
    #endif
    @State private var appState = AppState()

    init() {
        #if os(macOS)
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
                Context.self,
                TaskSkill.self
            ])

            // Use in-memory database for UI tests
            if isUITesting {
                let config = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
                sharedContainer = try ModelContainer(for: schema, configurations: [config])
            } else {
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
            }

            // Configure AppleScript support
            ScriptingBridge.shared.configure(modelContainer: sharedContainer)
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
                Context.self,
                TaskSkill.self
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
        MacScenes(appState: $appState, sharedContainer: sharedContainer)
        #else
        MobileScene(appState: $appState, modelContainer: modelContainer)
        #endif
    }
}
