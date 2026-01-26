import SwiftUI

/// Events we care about for the card stack
private let relevantEventTypes = ["PermissionRequest"]

/// A Tinder-like card stack view for inbox permission requests
struct InboxCardStackView: View {
    @Binding var selection: InboxEvent?
    @State private var inboxService = InboxService.shared

    /// Cards removed during animation (to prevent re-rendering during animation)
    @State private var removedIds: Set<UUID> = []

    /// Track the currently animating card
    @State private var animatingCardId: UUID?

    /// Pending permission requests (not yet resolved)
    private var pendingEvents: [InboxEvent] {
        inboxService.events.filter { event in
            guard let hookName = event.event.hookEventName else { return false }
            return relevantEventTypes.contains(hookName) &&
                   !inboxService.isResolved(event.id) &&
                   !removedIds.contains(event.id)
        }
    }

    /// Visible cards (top 3)
    private var visibleCards: [InboxEvent] {
        Array(pendingEvents.prefix(3))
    }

    /// The top card that's interactive
    private var topCard: InboxEvent? {
        visibleCards.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Card stack or empty state
            if pendingEvents.isEmpty {
                emptyState
            } else {
                cardStack
            }
        }
        .onAppear {
            inboxService.connect()
        }
        .focusable()
        .onKeyPress(.leftArrow) {
            handleKeyboardDeny()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            handleKeyboardAllow()
            return .handled
        }
        .onKeyPress("n") {
            handleKeyboardDeny()
            return .handled
        }
        .onKeyPress("y") {
            handleKeyboardAllow()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Permissions")
                .font(.headline)

            Spacer()

            // Count badge
            if !pendingEvents.isEmpty {
                Text("\(pendingEvents.count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }

            // Connection indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(inboxService.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(inboxService.isConnected ? "Live" : "Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle")
                .font(.system(size: 64))
                .foregroundStyle(.green.opacity(0.6))

            Text("All Clear")
                .font(.title2.weight(.medium))
                .foregroundStyle(.primary)

            Text("No pending permission requests")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !inboxService.isConnected {
                if let error = inboxService.connectionError {
                    Text("Connection error: \(error.localizedDescription)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Reconnect") {
                        inboxService.reconnect()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                } else {
                    Text("Connecting to axel server...")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Keyboard shortcut hints
            keyboardHints
                .opacity(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card Stack

    private var cardStack: some View {
        GeometryReader { geometry in
            ZStack {
                // Background cards (stacked behind)
                ForEach(Array(visibleCards.dropFirst().reversed().enumerated()), id: \.element.id) { index, event in
                    let stackIndex = visibleCards.count - 2 - index // 0 for second card, 1 for third
                    backgroundCard(event: event, index: stackIndex, geometry: geometry)
                }

                // Top card (interactive)
                if let event = topCard, animatingCardId != event.id {
                    SwipeableCardView {
                        PermissionCardContent(
                            event: event,
                            onDeny: { handleDeny(event) },
                            onAllow: { handleAllow(event) }
                        )
                    } onSwiped: { direction in
                        handleSwipe(event: event, direction: direction)
                    }
                    .frame(
                        width: geometry.size.width - 40,
                        height: geometry.size.height - 80
                    )
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .identity
                    ))
                    .id(event.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) {
            keyboardHints
                .padding(.bottom, 8)
        }
    }

    /// Background card with scale and offset
    private func backgroundCard(event: InboxEvent, index: Int, geometry: GeometryProxy) -> some View {
        let scale = 1.0 - (Double(index + 1) * 0.05)
        let yOffset = CGFloat(index + 1) * 8

        return PermissionCardContentCompact(event: event)
            .frame(
                width: geometry.size.width - 40,
                height: geometry.size.height - 80
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .scaleEffect(scale)
            .offset(y: yOffset)
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }

    // MARK: - Keyboard Hints

    private var keyboardHints: some View {
        HStack(spacing: 24) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left")
                    .font(.caption)
                Text("or")
                    .font(.caption2)
                Text("N")
                    .font(.caption.monospaced())
                Text("Deny")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.caption)
                Text("or")
                    .font(.caption2)
                Text("Y")
                    .font(.caption.monospaced())
                Text("Allow")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func handleSwipe(event: InboxEvent, direction: SwipeDirection) {
        switch direction {
        case .left:
            handleDeny(event)
        case .right:
            handleAllow(event)
        }
    }

    private func handleDeny(_ event: InboxEvent) {
        sendPermissionResponse(event: event, allow: false)
    }

    private func handleAllow(_ event: InboxEvent) {
        sendPermissionResponse(event: event, allow: true)
    }

    private func handleKeyboardDeny() {
        guard let event = topCard else { return }
        // Mark as animating to trigger removal
        withAnimation(.easeOut(duration: 0.3)) {
            removedIds.insert(event.id)
        }
        handleDeny(event)
    }

    private func handleKeyboardAllow() {
        guard let event = topCard else { return }
        // Mark as animating to trigger removal
        withAnimation(.easeOut(duration: 0.3)) {
            removedIds.insert(event.id)
        }
        handleAllow(event)
    }

    private func sendPermissionResponse(event: InboxEvent, allow: Bool) {
        guard let sessionId = event.event.claudeSessionId else {
            print("[InboxCardStack] No session ID for permission response")
            return
        }

        // Immediately mark as removed for UI
        removedIds.insert(event.id)

        Task {
            do {
                try await inboxService.sendPermissionResponse(sessionId: sessionId, allow: allow)
                await MainActor.run {
                    inboxService.resolveEvent(event.id)
                    selection = nil
                }
            } catch {
                print("[InboxCardStack] Failed to send permission response: \(error)")
                // Remove from removedIds so it reappears
                await MainActor.run {
                    removedIds.remove(event.id)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Card Stack - With Events") {
    @Previewable @State var selection: InboxEvent? = nil

    InboxCardStackView(selection: $selection)
        .frame(width: 450, height: 600)
}

#Preview("Card Stack - Empty") {
    @Previewable @State var selection: InboxEvent? = nil

    InboxCardStackView(selection: $selection)
        .frame(width: 450, height: 600)
}
