import SwiftUI

/// A reusable empty state view with consistent styling across the app
struct EmptyStateView: View {
    let image: String
    let title: String
    let description: String
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    var actionIcon: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: image)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(description)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let action = action, let label = actionLabel {
                Button(action: action) {
                    if let icon = actionIcon {
                        Label(label, systemImage: icon)
                    } else {
                        Text(label)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview("Empty State") {
    EmptyStateView(
        image: "tray",
        title: "No Items",
        description: "Items will appear here when available"
    )
}

#Preview("Empty State with Action") {
    EmptyStateView(
        image: "person.2",
        title: "No Team Members",
        description: "Invite collaborators to work together",
        action: {},
        actionLabel: "Invite Member",
        actionIcon: "person.badge.plus"
    )
}
