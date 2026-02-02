import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Public SwiftUI Views

struct SimpleTerminalView: View {
    let workspace: Workspace

    var body: some View {
        TerminalPanelView(workingDirectory: workspace.path)
    }
}

struct StandaloneTerminalView: View {
    let paneId: String
    let workspaceId: UUID

    @State private var session: TerminalSession?

    init(paneId: String = UUID().uuidString, workspaceId: UUID) {
        self.paneId = paneId
        self.workspaceId = workspaceId
    }

    var body: some View {
        Group {
            if let surface = session?.surfaceView, session?.isReady == true {
                TerminalFullViewSimple(surfaceView: surface)
            } else {
                ProgressView("Starting terminal...")
            }
        }
        .onAppear {
            if session == nil {
                session = TerminalSessionManager.shared.session(forPaneId: paneId, workingDirectory: nil, workspaceId: workspaceId)
            }
        }
    }
}

// MARK: - Terminal Display View

struct TerminalFullViewSimple: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView

    var body: some View {
        TerminalSurfaceRepresentable(view: surfaceView, size: CGSize(width: 800, height: 600))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#else

struct SimpleTerminalView: View {
    let workspace: Workspace
    var body: some View {
        Text("Terminal is only available on macOS")
    }
}

struct StandaloneTerminalView: View {
    var body: some View {
        Text("Terminal is only available on macOS")
    }
}

#endif
