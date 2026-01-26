import SwiftUI

#if os(visionOS)

/// Ultra-wide command center surface with Tasks, Skills, and Inbox side by side
struct CommandCenterView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Tasks Panel
            TasksPanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.2))

            // Skills/Agents Panel
            AgentsPanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.2))

            // Inbox Panel
            InboxPanelView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.opacity(0.8))
    }
}

#endif
