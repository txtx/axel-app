import SwiftUI

/// Direction of swipe
enum SwipeDirection {
    case left
    case right
}

/// A reusable swipeable card component with rotation, color overlay, and threshold detection
struct SwipeableCardView<Content: View>: View {
    let content: Content
    let onSwiped: (SwipeDirection) -> Void

    @GestureState private var dragOffset: CGSize = .zero
    @State private var offset: CGSize = .zero
    @State private var isRemoved = false

    /// Maximum rotation angle in degrees
    private let maxRotation: Double = 15

    /// Swipe threshold to commit (in points)
    private let swipeThreshold: CGFloat = 150

    /// Off-screen distance for swipe-away animation
    private let screenWidth: CGFloat = 1000

    init(@ViewBuilder content: () -> Content, onSwiped: @escaping (SwipeDirection) -> Void) {
        self.content = content()
        self.onSwiped = onSwiped
    }

    /// Calculate rotation based on drag offset
    private var rotation: Angle {
        let progress = dragOffset.width / swipeThreshold
        let clampedProgress = max(-1, min(1, progress))
        return .degrees(clampedProgress * maxRotation)
    }

    /// Calculate green overlay opacity (for right swipe)
    private var greenOverlayOpacity: Double {
        let progress = dragOffset.width / swipeThreshold
        return max(0, min(0.3, progress * 0.3))
    }

    /// Calculate red overlay opacity (for left swipe)
    private var redOverlayOpacity: Double {
        let progress = -dragOffset.width / swipeThreshold
        return max(0, min(0.3, progress * 0.3))
    }

    var body: some View {
        content
            .overlay(
                ZStack {
                    // Green overlay for right swipe (approve)
                    Color.green.opacity(greenOverlayOpacity)

                    // Red overlay for left swipe (deny)
                    Color.red.opacity(redOverlayOpacity)

                    // Swipe indicator icons
                    HStack {
                        // Deny indicator (left side)
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.red)
                            .opacity(redOverlayOpacity * 3)
                            .padding(.leading, 30)

                        Spacer()

                        // Approve indicator (right side)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                            .opacity(greenOverlayOpacity * 3)
                            .padding(.trailing, 30)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            .rotationEffect(rotation)
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        handleDragEnd(value)
                    }
            )
            .opacity(isRemoved ? 0 : 1)
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        let horizontalAmount = value.translation.width

        if horizontalAmount > swipeThreshold {
            // Swiped right - approve
            withAnimation(.easeOut(duration: 0.3)) {
                offset = CGSize(width: screenWidth, height: value.translation.height)
                isRemoved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onSwiped(.right)
            }
        } else if horizontalAmount < -swipeThreshold {
            // Swiped left - deny
            withAnimation(.easeOut(duration: 0.3)) {
                offset = CGSize(width: -screenWidth, height: value.translation.height)
                isRemoved = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onSwiped(.left)
            }
        } else {
            // Snap back
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                offset = .zero
            }
        }
    }

    /// Programmatically trigger a swipe animation
    func triggerSwipe(_ direction: SwipeDirection) {
        let targetX: CGFloat = direction == .right ? screenWidth : -screenWidth

        withAnimation(.easeOut(duration: 0.3)) {
            offset = CGSize(width: targetX, height: 0)
            isRemoved = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSwiped(direction)
        }
    }
}

/// A wrapper that exposes programmatic swipe control
struct SwipeableCardContainer<Content: View>: View {
    let content: Content
    let onSwiped: (SwipeDirection) -> Void

    @State private var swipeController = SwipeController()

    init(@ViewBuilder content: () -> Content, onSwiped: @escaping (SwipeDirection) -> Void) {
        self.content = content()
        self.onSwiped = onSwiped
    }

    var body: some View {
        SwipeableCardViewControlled(
            controller: $swipeController,
            onSwiped: onSwiped
        ) {
            content
        }
    }

    func swipe(_ direction: SwipeDirection) {
        swipeController.pendingSwipe = direction
    }
}

/// Controller for programmatic swipe actions
class SwipeController: ObservableObject {
    @Published var pendingSwipe: SwipeDirection?
}

/// A swipeable card that can be controlled programmatically
struct SwipeableCardViewControlled<Content: View>: View {
    let content: Content
    let onSwiped: (SwipeDirection) -> Void
    @Binding var controller: SwipeController

    @GestureState private var dragOffset: CGSize = .zero
    @State private var offset: CGSize = .zero
    @State private var isRemoved = false

    private let maxRotation: Double = 15
    private let swipeThreshold: CGFloat = 150
    /// Off-screen distance for swipe-away animation
    private let screenWidth: CGFloat = 1000

    init(
        controller: Binding<SwipeController>,
        onSwiped: @escaping (SwipeDirection) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self._controller = controller
        self.onSwiped = onSwiped
        self.content = content()
    }

    private var rotation: Angle {
        let progress = (offset.width + dragOffset.width) / swipeThreshold
        let clampedProgress = max(-1, min(1, progress))
        return .degrees(clampedProgress * maxRotation)
    }

    private var greenOverlayOpacity: Double {
        let progress = (offset.width + dragOffset.width) / swipeThreshold
        return max(0, min(0.3, progress * 0.3))
    }

    private var redOverlayOpacity: Double {
        let progress = -(offset.width + dragOffset.width) / swipeThreshold
        return max(0, min(0.3, progress * 0.3))
    }

    var body: some View {
        content
            .overlay(
                ZStack {
                    Color.green.opacity(greenOverlayOpacity)
                    Color.red.opacity(redOverlayOpacity)

                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.red)
                            .opacity(redOverlayOpacity * 3)
                            .padding(.leading, 30)

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.green)
                            .opacity(greenOverlayOpacity * 3)
                            .padding(.trailing, 30)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            .rotationEffect(rotation)
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        handleDragEnd(value)
                    }
            )
            .opacity(isRemoved ? 0 : 1)
            .onChange(of: controller.pendingSwipe) { _, newValue in
                if let direction = newValue {
                    performSwipe(direction)
                    controller.pendingSwipe = nil
                }
            }
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        let horizontalAmount = value.translation.width

        if horizontalAmount > swipeThreshold {
            performSwipe(.right)
        } else if horizontalAmount < -swipeThreshold {
            performSwipe(.left)
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                offset = .zero
            }
        }
    }

    private func performSwipe(_ direction: SwipeDirection) {
        let targetX: CGFloat = direction == .right ? screenWidth : -screenWidth

        withAnimation(.easeOut(duration: 0.3)) {
            offset = CGSize(width: targetX, height: 0)
            isRemoved = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSwiped(direction)
        }
    }
}

// MARK: - Preview

#Preview("Swipeable Card") {
    SwipeableCardView {
        VStack {
            Text("Swipe me!")
                .font(.title)
            Text("← Deny | Approve →")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 300, height: 400)
        .background(.background)
        .shadow(radius: 8)
    } onSwiped: { direction in
        print("Swiped \(direction)")
    }
    .padding(50)
}
