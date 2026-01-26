//
//  SwipeCardsKit.swift
//  Axel
//
//  Adapted from SwipeCardsKit by Beka Demuradze (tobi404)
//  https://github.com/tobi404/SwipeCardsKit
//
//  iOS only - macOS uses the original SwipeableCardView implementation
//

#if os(iOS)
import SwiftUI

// MARK: - CardSwipeDirection

public enum CardSwipeDirection: Sendable {
    case left, right, idle

    init(offset: CGFloat) {
        if offset > 0 {
            self = .right
        } else if offset == 0 {
            self = .idle
        } else {
            self = .left
        }
    }
}

// MARK: - Screen Helper

#if os(iOS)
extension UIWindow {
    static var current: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if window.isKeyWindow { return window }
            }
        }
        return nil
    }
}

extension UIScreen {
    static var current: UIScreen? {
        UIWindow.current?.screen
    }
}
#endif

// MARK: - Configuration

@MainActor
final class SwipeCardsConfiguration<Item: Identifiable> {
    var triggerThreshold: CGFloat = 150
    var minimumDistance: CGFloat = 20
    var animateOnYAxes: Bool = false
    var onSwipeEnd: ((Item, CardSwipeDirection) -> Void)?
    var onThresholdPassed: (() -> Void)?
    var onNoMoreCardsLeft: (() -> Void)?
    let visibleCount = 4

    var screenWidth: CGFloat {
        #if os(iOS)
        return UIScreen.current?.bounds.width ?? 400
        #else
        return NSScreen.main?.frame.width ?? 800
        #endif
    }
}

// MARK: - CardSwipeEffect

struct CardSwipeEffect: ViewModifier {
    let index: Int
    let offset: CGPoint
    let triggerThreshold: CGFloat

    func body(content: Content) -> some View {
        switch index {
        case 0:
            let angle = Angle(degrees: Double(offset.x) / 20)
            content
                .offset(x: offset.x, y: offset.y)
                .rotationEffect(angle, anchor: .bottom)
                .zIndex(4)
        case 1:
            let progress = min(abs(offset.x) / triggerThreshold, 1)
            content
                .offset(y: CGFloat((1 - progress) * -24))
                .scaleEffect(CGFloat(0.94 + progress * 0.06))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .zIndex(3)
        case 2:
            let progress = min(abs(offset.x) / triggerThreshold, 1)
            content
                .offset(y: CGFloat(-48 + progress * 24))
                .scaleEffect(CGFloat(0.88 + progress * 0.06))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .zIndex(2)
        case 3:
            let progress = min(abs(offset.x) / triggerThreshold, 1)
            content
                .opacity(progress)
                .offset(y: CGFloat(-72 + progress * 24))
                .scaleEffect(CGFloat(0.82 + progress * 0.06))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .zIndex(1)
        default:
            content
                .opacity(0)
        }
    }
}

// MARK: - CardSwipeView

public struct CardSwipeView<Item: Identifiable & Hashable, Content: View>: View {
    @State private var configuration = SwipeCardsConfiguration<Item>()
    @State private var poppedItem: Item?
    @State private var poppedOffset: CGPoint = .zero
    @State private var poppedDirection: CardSwipeDirection = .idle
    @State private var lastDirection: CardSwipeDirection = .idle
    @State private var offset: CGPoint = .zero
    @State private var thresholdPassed = false

    @Binding private var items: [Item]
    @Binding private var selectedItem: Item?
    @Binding private var popTrigger: CardSwipeDirection?
    private let content: (Item, _ progress: CGFloat, _ direction: CardSwipeDirection) -> Content

    private var screenWidth: CGFloat {
        configuration.screenWidth
    }

    public init(
        items: Binding<[Item]>,
        selectedItem: Binding<Item?> = .constant(nil),
        popTrigger: Binding<CardSwipeDirection?> = .constant(nil),
        @ViewBuilder content: @escaping (Item, _ progress: CGFloat, _ direction: CardSwipeDirection) -> Content
    ) {
        self._items = items
        self._selectedItem = selectedItem
        self._popTrigger = popTrigger
        self.content = content
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: configuration.minimumDistance)
            .onChanged { value in
                onDragChanged(value)
            }
            .onEnded { value in
                if abs(value.translation.width) < configuration.triggerThreshold {
                    withAnimation(.bouncy) {
                        offset = .zero
                    }
                } else if !items.isEmpty {
                    popItem()
                }
            }
    }

    public var body: some View {
        ZStack {
            ForEach(Array(items.prefix(configuration.visibleCount).enumerated()), id: \.element.id) { index, item in
                let progress = index == 0 ? min(abs(offset.x) / configuration.triggerThreshold, 1) : 0

                content(item, progress, lastDirection)
                    .modifier(
                        CardSwipeEffect(
                            index: index,
                            offset: offset,
                            triggerThreshold: configuration.triggerThreshold
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { poppedCard }
        .gesture(swipeGesture)
        .onAppear {
            selectedItem = items.first
        }
        .onChange(of: popTrigger ?? .idle) { _, newValue in
            guard newValue != .idle else { return }
            lastDirection = newValue
            popItem(notifyCaller: false)
            popTrigger = nil
        }
    }

    @ViewBuilder
    var poppedCard: some View {
        if let poppedItem {
            content(poppedItem, min(abs(poppedOffset.x) / configuration.triggerThreshold, 1), poppedDirection)
                .modifier(
                    CardSwipeEffect(
                        index: 0,
                        offset: poppedOffset,
                        triggerThreshold: configuration.triggerThreshold
                    )
                )
                .id(poppedItem.id)
                .onAppear {
                    animatePoppedItem()
                }
        }
    }

    func onDragChanged(_ value: DragGesture.Value) {
        let translation = value.translation.width
        let correction = correction(for: translation)
        let offsetX = translation + correction
        let offsetY = configuration.animateOnYAxes
            ? value.translation.height
            : 0
        offset = CGPoint(x: offsetX, y: offsetY)

        let newDirection = CardSwipeDirection(offset: offsetX)
        if lastDirection != newDirection {
            lastDirection = newDirection
        }

        let thresholdReached = abs(offsetX) >= configuration.triggerThreshold
        if thresholdReached != thresholdPassed {
            thresholdPassed = thresholdReached
            if thresholdReached {
                configuration.onThresholdPassed?()
            }
        }
    }

    func correction(for translation: CGFloat) -> CGFloat {
        if translation >= configuration.minimumDistance {
            -configuration.minimumDistance
        } else if translation <= -configuration.minimumDistance {
            configuration.minimumDistance
        } else {
            -translation
        }
    }

    func animatePoppedItem() {
        let multiplier: CGFloat = poppedDirection == .left ? -1 : 1

        withAnimation(.spring(duration: 0.5)) {
            poppedOffset.x += (screenWidth * multiplier)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                self.poppedItem = nil
                self.poppedOffset = .zero

                if items.isEmpty {
                    configuration.onNoMoreCardsLeft?()
                }
            }
        }
    }

    func popItem(notifyCaller: Bool = true) {
        guard !items.isEmpty else { return }
        poppedOffset = offset
        poppedDirection = lastDirection
        poppedItem = items.removeFirst()
        selectedItem = items.first
        if let poppedItem, notifyCaller {
            configuration.onSwipeEnd?(poppedItem, lastDirection)
        }
        offset = .zero
    }
}

// MARK: - CardSwipeView Configuration Extensions

public extension CardSwipeView {
    func configure(
        threshold: CGFloat = 150,
        minimumDistance: CGFloat = 20,
        animateOnYAxes: Bool = false
    ) -> CardSwipeView {
        configuration.triggerThreshold = threshold
        configuration.minimumDistance = minimumDistance
        configuration.animateOnYAxes = animateOnYAxes
        return self
    }

    func onSwipeEnd(_ newValue: @escaping (Item, CardSwipeDirection) -> Void) -> CardSwipeView {
        configuration.onSwipeEnd = newValue
        return self
    }

    func onNoMoreCardsLeft(_ newValue: @escaping () -> Void) -> CardSwipeView {
        configuration.onNoMoreCardsLeft = newValue
        return self
    }

    func onThresholdPassed(_ newValue: @escaping () -> Void) -> CardSwipeView {
        configuration.onThresholdPassed = newValue
        return self
    }
}
#endif
