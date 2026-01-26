import SwiftUI
import SwiftData

#if os(iOS) || os(visionOS)
struct MobileScene: Scene {
    @Binding var appState: AppState
    let modelContainer: ModelContainer

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .onOpenURL { url in
                    Task {
                        await AuthService.shared.handleOAuthCallback(url: url)
                    }
                }
        }
        .modelContainer(modelContainer)

        #if os(visionOS)
        // Immersive command center with curved ultrawide display
        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.full), in: .mixed, .full)
        .modelContainer(modelContainer)
        #endif
    }
}
#endif
