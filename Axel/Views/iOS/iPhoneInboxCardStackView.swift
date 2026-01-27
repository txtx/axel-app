#if os(iOS)
import SwiftUI
import SwiftData

// MARK: - Card Item Wrapper

/// Wrapper to make Hint work with CardSwipeView (requires Identifiable & Hashable)
struct HintCardItem: Identifiable, Hashable {
    let id: UUID
    let hint: Hint

    init(_ hint: Hint) {
        self.id = hint.id
        self.hint = hint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HintCardItem, rhs: HintCardItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Dark Theme Colors

private enum InboxColors {
    // Background
    static let screenBackground = Color(hex: 0x0E1216)
    static let screenBackgroundLight = Color(hex: 0x151A1F)

    // Cards
    static let cardBackground = Color(hex: 0x2C3138)
    static let cardBackgroundElevated = Color(hex: 0x363D45)
    static let cardBorder = Color(white: 0.25)
    static let subtleBorder = Color(white: 0.18)

    // Accent colors
    static let accentOrange = Color(hex: 0xFF9933)
    static let accentGreen = Color(hex: 0x4CD964)
    static let accentRed = Color(hex: 0xFF5B5B)

    // Text colors
    static let textPrimary = Color(white: 0.95)
    static let textSecondary = Color(white: 0.6)
    static let textTertiary = Color(white: 0.4)
}

// MARK: - Color Extension

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - iPhone Inbox Card Stack View

/// A Tinder-like card stack view for iPhone inbox (Hint-based) using SwipeCardsKit
struct iPhoneInboxCardStackView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Hint> { $0.status == "pending" },
        sort: \Hint.createdAt,
        order: .reverse
    ) private var pendingHints: [Hint]

    @Binding var selection: Hint?

    /// Card items derived from pending hints
    @State private var cardItems: [HintCardItem] = []

    /// Selected card item
    @State private var selectedItem: HintCardItem?

    /// Trigger for programmatic swipes
    @State private var popTrigger: CardSwipeDirection?

    var body: some View {
        ZStack {
            // Gradient background
            backgroundGradient

            GeometryReader { geometry in
                if cardItems.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        Spacer()
                            .frame(height: 20)

                        // Card stack
                        CardSwipeView(
                            items: $cardItems,
                            selectedItem: $selectedItem,
                            popTrigger: $popTrigger
                        ) { item, progress, direction in
                            HintSwipeCardContent(
                                hint: item.hint,
                                progress: progress,
                                direction: direction
                            )
                            .frame(
                                width: geometry.size.width - 40,
                                height: min(geometry.size.height - 160, 520)
                            )
                        }
                        .configure(threshold: 120, minimumDistance: 15, animateOnYAxes: true)
                        .onSwipeEnd { item, direction in
                            handleSwipe(item: item, direction: direction)
                        }
                        .padding(.horizontal, 20)

                        Spacer()

                        // Swipe hints at bottom
                        swipeHints
                            .padding(.bottom, 32)
                    }
                }
            }
        }
        .onAppear {
            syncCardItems()
        }
        .onChange(of: pendingHints) { _, _ in
            syncCardItems()
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                InboxColors.screenBackgroundLight,
                InboxColors.screenBackground,
                InboxColors.screenBackground
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Sync Card Items

    private func syncCardItems() {
        let currentIds = Set(cardItems.map { $0.id })
        let newItems = pendingHints
            .filter { !currentIds.contains($0.id) }
            .map { HintCardItem($0) }

        if !newItems.isEmpty {
            cardItems.append(contentsOf: newItems)
        }

        let pendingIds = Set(pendingHints.map { $0.id })
        cardItems.removeAll { !pendingIds.contains($0.id) }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            // Glowing checkmark
            ZStack {
                Circle()
                    .fill(InboxColors.accentGreen.opacity(0.12))
                    .frame(width: 120, height: 120)
                    .blur(radius: 30)

                Circle()
                    .fill(InboxColors.cardBackground)
                    .frame(width: 100, height: 100)
                    .overlay(
                        Circle()
                            .stroke(InboxColors.accentGreen.opacity(0.25), lineWidth: 1)
                    )

                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(InboxColors.accentGreen)
            }

            VStack(spacing: 8) {
                Text("All Clear")
                    .font(.title2.bold())
                    .foregroundStyle(InboxColors.textPrimary)

                Text("No pending requests")
                    .font(.body)
                    .foregroundStyle(InboxColors.textSecondary)
            }

            Text("AI agents will ask for permission here\nwhen they need your approval")
                .font(.subheadline)
                .foregroundStyle(InboxColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Swipe Hints

    private var swipeHints: some View {
        HStack(spacing: 24) {
            // Deny hint
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .font(.caption.bold())
                Text("Deny")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(InboxColors.accentRed)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(InboxColors.accentRed.opacity(0.12))
                    .overlay(
                        Capsule()
                            .stroke(InboxColors.accentRed.opacity(0.2), lineWidth: 1)
                    )
            )

            // Allow hint
            HStack(spacing: 8) {
                Text("Allow")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "arrow.right")
                    .font(.caption.bold())
            }
            .foregroundStyle(InboxColors.accentGreen)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(InboxColors.accentGreen.opacity(0.12))
                    .overlay(
                        Capsule()
                            .stroke(InboxColors.accentGreen.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Actions

    private func handleSwipe(item: HintCardItem, direction: CardSwipeDirection) {
        switch direction {
        case .left:
            submitResponse(hint: item.hint, optionValue: "deny")
        case .right:
            submitResponse(hint: item.hint, optionValue: "allow")
        case .idle:
            break
        }
    }

    private func submitResponse(hint: Hint, optionValue: String) {
        if let data = try? JSONEncoder().encode(AnyCodableValue(optionValue)) {
            hint.responseData = data
        }
        hint.hintStatus = .answered
        hint.answeredAt = Date()

        try? modelContext.save()

        Task {
            await SyncScheduler.shared.scheduleSync()
        }
    }
}

// MARK: - Hint Swipe Card Content

/// Card content that shows swipe feedback overlay
struct HintSwipeCardContent: View {
    let hint: Hint
    let progress: CGFloat
    let direction: CardSwipeDirection

    private var typeIcon: String {
        switch hint.hintType {
        case .exclusiveChoice: "lock.shield.fill"
        case .multipleChoice: "checklist"
        case .textInput: "text.bubble.fill"
        }
    }

    var body: some View {
        ZStack {
            // Card background with glow
            cardBackground

            // Card content
            VStack(spacing: 0) {
                headerSection

                Rectangle()
                    .fill(InboxColors.subtleBorder)
                    .frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(hint.title)
                            .font(.title3.bold())
                            .foregroundStyle(InboxColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let description = hint.hintDescription {
                            Text(description)
                                .font(.body)
                                .foregroundStyle(InboxColors.textSecondary)
                        }

                        if let task = hint.task {
                            taskContextSection(task)
                        }
                    }
                    .padding(20)
                }

                Spacer(minLength: 0)
            }

            // Swipe feedback overlay
            swipeOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var cardBackground: some View {
        ZStack {
            // Main card fill
            RoundedRectangle(cornerRadius: 20)
                .fill(InboxColors.cardBackground)

            // Subtle inner highlight at top
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            // Border
            RoundedRectangle(cornerRadius: 20)
                .stroke(InboxColors.cardBorder, lineWidth: 1)

            // Direction-based glow
            if direction == .right && progress > 0 {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(InboxColors.accentGreen.opacity(0.6 * progress), lineWidth: 2)
                    .blur(radius: 3)
            } else if direction == .left && progress > 0 {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(InboxColors.accentRed.opacity(0.6 * progress), lineWidth: 2)
                    .blur(radius: 3)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)
    }

    private var headerSection: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(InboxColors.accentOrange.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: typeIcon)
                    .font(.title3)
                    .foregroundStyle(InboxColors.accentOrange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Permission Request")
                    .font(.headline)
                    .foregroundStyle(InboxColors.textPrimary)

                Text(hint.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(InboxColors.textTertiary)
            }

            Spacer()
        }
        .padding(20)
    }

    private func taskContextSection(_ task: WorkTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(InboxColors.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .foregroundStyle(InboxColors.textSecondary)
                    .lineLimit(1)

                if let workspace = task.workspace {
                    Text(workspace.name)
                        .font(.caption)
                        .foregroundStyle(InboxColors.textTertiary)
                }
            }

            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(InboxColors.cardBackgroundElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(InboxColors.subtleBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var swipeOverlay: some View {
        ZStack {
            // Green overlay for right swipe (allow)
            if direction == .right {
                InboxColors.accentGreen.opacity(0.12 * progress)
            }

            // Red overlay for left swipe (deny)
            if direction == .left {
                InboxColors.accentRed.opacity(0.12 * progress)
            }

            // Swipe indicator icons
            HStack {
                if direction == .left {
                    VStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(InboxColors.accentRed)

                        Text("DENY")
                            .font(.caption.bold())
                            .foregroundStyle(InboxColors.accentRed)
                    }
                    .opacity(progress)
                    .scaleEffect(0.85 + 0.15 * progress)
                    .padding(.leading, 36)
                }

                Spacer()

                if direction == .right {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(InboxColors.accentGreen)

                        Text("ALLOW")
                            .font(.caption.bold())
                            .foregroundStyle(InboxColors.accentGreen)
                    }
                    .opacity(progress)
                    .scaleEffect(0.85 + 0.15 * progress)
                    .padding(.trailing, 36)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
    }
}

// MARK: - Preview

#Preview("iPhone Inbox Card Stack") {
    @Previewable @State var selection: Hint? = nil

    iPhoneInboxCardStackView(selection: $selection)
        .preferredColorScheme(.dark)
}
#endif
