import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Stack Identifier

struct StackIdentifier: Hashable {
    let worktreeName: String
    let status: SessionStatus
}

// MARK: - Timeline Panel View

struct TimelinePanelView: View {
    let workspaceId: UUID
    @Binding var selection: TerminalSession?
    let onRequestClose: (TerminalSession) -> Void

    @Environment(\.terminalSessionManager) private var sessionManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var panelHeight: CGFloat = 300
    @State private var expandedStack: StackIdentifier?

    private let statusService = SessionStatusService.shared

    private var worktreeGroups: [(name: String, sessions: [TerminalSession])] {
        let dict = sessionManager.sessionsByWorktree(for: workspaceId)
        return dict.sorted { $0.key < $1.key }
            .map { (name: $0.key, sessions: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HorizontalResizableDivider(height: $panelHeight, minHeight: 140, maxHeight: 500)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(worktreeGroups.enumerated()), id: \.element.name) { index, group in
                        WorktreeLaneView(
                            worktreeName: group.name,
                            sessions: group.sessions,
                            selection: $selection,
                            expandedStack: $expandedStack,
                            onRequestClose: onRequestClose
                        )

                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: panelHeight)
            .background(backgroundColor)
        }
        .focusEffectDisabled()
        .modifier(TimelineKeyboardNavigation(
            sessions: allTimelineSessions,
            selection: $selection,
            expandedStack: $expandedStack
        ))
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(hex: "292F30")! : Color.white
    }

    private var allTimelineSessions: [TerminalSession] {
        statusService.orderedByPriority(sessionManager.sessions(for: workspaceId))
    }
}

// MARK: - Worktree Lane View

struct WorktreeLaneView: View {
    let worktreeName: String
    let sessions: [TerminalSession]
    @Binding var selection: TerminalSession?
    @Binding var expandedStack: StackIdentifier?
    let onRequestClose: (TerminalSession) -> Void

    private let statusService = SessionStatusService.shared
    private let laneHeight: CGFloat = 200
    private let cardWidth: CGFloat = 240
    private let cardSpacing: CGFloat = 10

    private var statusGroups: [(status: SessionStatus, sessions: [TerminalSession])] {
        statusService.groupedByStatus(sessions)
    }

    private let yellowTop = Color(red: 0.95, green: 0.85, blue: 0.25)
    private let yellowBottom = Color(red: 0.90, green: 0.75, blue: 0.10)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: cardSpacing) {
                    ForEach(statusGroups, id: \.status) { group in
                        if group.sessions.count == 1 {
                            CompactMiniatureView(
                                session: group.sessions[0],
                                isSelected: selection?.id == group.sessions[0].id
                            )
                            .timelineContextMenu(session: group.sessions[0], onRequestClose: onRequestClose)
                            .onTapGesture {
                                selection = group.sessions[0]
                            }
                        } else {
                            AnimatedTerminalStack(
                                sessions: group.sessions,
                                status: group.status,
                                worktreeName: worktreeName,
                                selection: $selection,
                                expandedStack: $expandedStack,
                                onRequestClose: onRequestClose,
                                cardWidth: cardWidth,
                                cardSpacing: cardSpacing
                            )
                        }
                    }
                }
                .padding(.leading, 8)
            }
            .frame(height: laneHeight)

            Rectangle()
                .fill(yellowBottom.opacity(0.5))
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    HStack(spacing: 5) {
                        Image(.gitBranchIcon)
                            .resizable()
                            .frame(width: 12, height: 12)
                        Text(worktreeName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [yellowTop, yellowBottom],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .padding(.leading, 4)
                }
        }
        .focusEffectDisabled()
    }
}

// MARK: - Animated Terminal Stack

/// Single view that keeps ALL cards in the tree and animates offset/rotation/scale
/// between stacked (fan) and expanded (side-by-side). Container width animates,
/// cards physically slide apart. No view insertion/removal.
struct AnimatedTerminalStack: View {
    let sessions: [TerminalSession]
    let status: SessionStatus
    let worktreeName: String
    @Binding var selection: TerminalSession?
    @Binding var expandedStack: StackIdentifier?
    let onRequestClose: (TerminalSession) -> Void
    let cardWidth: CGFloat
    let cardSpacing: CGFloat

    private let cardHeight: CGFloat = 180
    @State private var frontSessionId: UUID?

    private var stackId: StackIdentifier {
        StackIdentifier(worktreeName: worktreeName, status: status)
    }

    private var isExpanded: Bool {
        expandedStack == stackId
    }

    private var containerWidth: CGFloat {
        if isExpanded {
            return CGFloat(sessions.count) * cardWidth + CGFloat(sessions.count - 1) * cardSpacing
        } else {
            // Just enough to fit the stacked fan (front card at 0 + slight overhang from rotated back cards)
            return cardWidth + 20
        }
    }

    var body: some View {
        Color.clear
            .frame(width: containerWidth, height: cardHeight + 16)
            .overlay(alignment: .topLeading) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    CompactMiniatureView(
                        session: session,
                        isSelected: selection?.id == session.id
                    )
                    .offset(x: xOffset(for: index), y: 8)
                    .rotationEffect(rotation(for: index), anchor: .bottom)
                    .scaleEffect(scale(for: index))
                    .zIndex(zIndex(for: index))
                    .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isExpanded)
                    .animation(.spring(response: 0.32, dampingFraction: 0.88), value: frontSessionId)
                    .timelineContextMenu(session: session, onRequestClose: onRequestClose)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in }
                            .onEnded { value in
                                guard abs(value.translation.width) < 5, abs(value.translation.height) < 5 else { return }
                                if isExpanded {
                                    selection = session
                                } else {
                                    expandedStack = stackId
                                }
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if isExpanded {
                                selection = session
                                frontSessionId = session.id
                                expandedStack = nil
                            }
                        }
                    )
                }
            }
            .overlay(alignment: .topLeading) {
                if !isExpanded && sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(status.color)
                                .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                        )
                        .overlay(Capsule().stroke(Color.black.opacity(0.3), lineWidth: 1))
                        .offset(x: cardWidth - 16, y: 4)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .focusEffectDisabled()
    }

    // MARK: - Position math

    /// Depth in the collapsed fan: 0 = front card, 1+ = behind.
    /// Only changes when collapsing (frontSessionId updated on collapse).
    private func fanDepth(for index: Int) -> Int {
        if let frontId = frontSessionId, let frontIdx = sessions.firstIndex(where: { $0.id == frontId }) {
            if index == frontIdx { return 0 }
            let offset = index < frontIdx ? index : index - 1
            return offset + 1
        }
        return index
    }

    private func xOffset(for index: Int) -> CGFloat {
        let depth = fanDepth(for: index)
        if isExpanded {
            return CGFloat(depth) * (cardWidth + cardSpacing)
        } else {
            switch depth {
            case 0: return 0
            case 1: return 6
            case 2: return 12
            default: return 4
            }
        }
    }

    private func rotation(for index: Int) -> Angle {
        if isExpanded { return .zero }
        let depth = fanDepth(for: index)
        switch depth {
        case 0: return .zero
        case 1: return .degrees(-5)
        case 2: return .degrees(6)
        default: return .zero
        }
    }

    private func scale(for index: Int) -> CGFloat {
        if isExpanded { return 1.0 }
        let depth = fanDepth(for: index)
        switch depth {
        case 0: return 1.0
        case 1: return 0.95
        case 2: return 0.92
        default: return 0.9
        }
    }

    private func zIndex(for index: Int) -> Double {
        if !isExpanded, let frontId = frontSessionId, sessions[index].id == frontId {
            return Double(sessions.count + 1)
        }
        return Double(sessions.count - index)
    }
}

// MARK: - Compact Miniature View

struct CompactMiniatureView: View {
    let session: TerminalSession
    var isSelected: Bool = false

    private let cardWidth: CGFloat = 240
    private let cardHeight: CGFloat = 180
    private let cornerRadius: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let current = session.currentThumbnail {
                GeometryReader { geo in
                    Image(nsImage: current)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .clipped()
            } else if let previous = session.previousThumbnail {
                GeometryReader { geo in
                    Image(nsImage: previous)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
                .clipped()
            } else {
                Color(red: 0x18/255.0, green: 0x26/255.0, blue: 0x2F/255.0)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 7, height: 7)
                providerIcon
            }
            .padding(8)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(isSelected ? Color.accentPurple : Color.white.opacity(0.1), lineWidth: isSelected ? 2.5 : 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch session.provider {
        case .claude:
            Image(systemName: "sparkle")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.7))
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.green.opacity(0.7))
        default:
            EmptyView()
        }
    }
}

// MARK: - Context Menu

extension View {
    func timelineContextMenu(session: TerminalSession, onRequestClose: @escaping (TerminalSession) -> Void) -> some View {
        self.contextMenu {
            let installedTerminals = TerminalApp.installedApps
            if let paneId = session.paneId, !installedTerminals.isEmpty {
                Menu {
                    ForEach(installedTerminals) { terminal in
                        Button {
                            let axelPath = AxelSetupService.shared.executablePath
                            terminal.open(withCommand: "\(axelPath) session join \(paneId)")
                        } label: {
                            Label(terminal.name, systemImage: terminal.iconName)
                        }
                    }
                } label: {
                    Label("Open in terminal", systemImage: "arrow.up.forward.app")
                }
            } else {
                Label("Open in terminal", systemImage: "arrow.up.forward.app")
                    .disabled(true)
            }

            Button(role: .destructive) {
                onRequestClose(session)
            } label: {
                Label("Kill session", systemImage: "xmark.circle.fill")
            }
        }
    }
}

// MARK: - Horizontal Resizable Divider

struct HorizontalResizableDivider: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var isDragging = false
    @State private var dragStartHeight: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.1))
                .frame(height: 1)
            Capsule()
                .fill(colorScheme == .dark ? Color.white.opacity(isDragging ? 0.35 : 0.2) : Color.black.opacity(isDragging ? 0.25 : 0.12))
                .frame(width: 36, height: 4)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartHeight = height
                    }
                    let newHeight = dragStartHeight - value.translation.height
                    height = min(maxHeight, max(minHeight, newHeight))
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

// MARK: - Timeline Keyboard Navigation

private struct TimelineKeyboardNavigation: ViewModifier {
    let sessions: [TerminalSession]
    @Binding var selection: TerminalSession?
    @Binding var expandedStack: StackIdentifier?
    @State private var monitor: TimelineKeyboardMonitor?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = TimelineKeyboardMonitor(
                    onNavigate: { navigate($0) },
                    onEscape: {
                        if expandedStack != nil {
                            expandedStack = nil
                            // frontSessionId stays as-is; current selection is already on top
                            return true
                        }
                        return false
                    }
                )
            }
            .onDisappear { monitor = nil }
    }

    private func navigate(_ direction: TimelineNavigationDirection) {
        guard !sessions.isEmpty else { return }
        guard let current = selection,
              let idx = sessions.firstIndex(where: { $0.id == current.id }) else {
            selection = sessions.first
            return
        }
        switch direction {
        case .left: if idx > 0 { selection = sessions[idx - 1] }
        case .right: if idx < sessions.count - 1 { selection = sessions[idx + 1] }
        }
    }
}

private enum TimelineNavigationDirection { case left, right }

private final class TimelineKeyboardMonitor {
    private var eventMonitor: Any?
    private let onNavigate: (TimelineNavigationDirection) -> Void
    private let onEscape: () -> Bool

    init(onNavigate: @escaping (TimelineNavigationDirection) -> Void, onEscape: @escaping () -> Bool) {
        self.onNavigate = onNavigate
        self.onEscape = onEscape
        setupMonitor()
    }

    deinit { removeMonitor() }

    private func setupMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { return self.onEscape() ? nil : event }
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.shift),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control) else { return event }
            switch event.keyCode {
            case 123: self.onNavigate(.left); return nil
            case 124: self.onNavigate(.right); return nil
            default: return event
            }
        }
    }

    private func removeMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

#endif
