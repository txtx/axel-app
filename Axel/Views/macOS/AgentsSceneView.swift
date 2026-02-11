import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Agents Scene Layout (Right Panel Container)

/// Container view that shows AgentsScene when a session is selected,
/// or EmptyRunningSelectionView when nothing is selected.
struct AgentsSceneLayout: View {
    let workspaceId: UUID
    @Binding var selection: TerminalSession?
    let onRequestClose: (TerminalSession) -> Void

    var body: some View {
        if let session = selection {
            AgentsScene(
                session: session,
                selection: $selection,
                onRequestClose: onRequestClose
            )
        } else {
            EmptyRunningSelectionView()
        }
    }
}

// MARK: - Agents Scene (Right Panel)

struct AgentsScene: View {
    let session: TerminalSession
    @Binding var selection: TerminalSession?
    let onRequestClose: (TerminalSession) -> Void
    @State private var installedTerminals: [TerminalApp] = []
    @State private var isHoveringPill = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                // Full terminal view
                terminalSurface
                    .id(session.id)

                // Floating glass pill toolbar
                TerminalGlassPill(
                    session: session,
                    installedTerminals: installedTerminals,
                    isHovering: $isHoveringPill,
                    onStop: { onRequestClose(session) }
                )
                .frame(maxWidth: geometry.size.width / 3)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        .background(.clear)
        .onAppear {
            installedTerminals = TerminalApp.installedApps
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(hex: "292F30")! : Color.white
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let surfaceView = session.surfaceView {
            TerminalFullView(surfaceView: surfaceView)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.top, 8)
                .padding(.bottom, 8)
                .padding(.trailing, 8)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 0)
        } else {
            ZStack {
                backgroundColor
                Text("Terminal not available")
                    .foregroundStyle(.secondary)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 8)
            .padding(.bottom, 8)
            .padding(.trailing, 8)
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 0)
        }
    }

}

// MARK: - Floating Glass Pill Toolbar

struct TerminalGlassPill: View {
    let session: TerminalSession
    let installedTerminals: [TerminalApp]
    @Binding var isHovering: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left section: Task info
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: .green.opacity(0.5), radius: 4)

                Text(session.taskTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)

            // Divider
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1, height: 20)

            // Right section: Actions
            HStack(spacing: 0) {
                // Open in external terminal
                if !installedTerminals.isEmpty, let paneId = session.paneId {
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
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Stop button
                Button {
                    onStop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 4)
        }
        .padding(.vertical, 6)
        .frame(height: 32)
        .background(
            GlassPillBackground()
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.1), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Glass Pill Background

struct GlassPillBackground: View {
    var body: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: NSViewRepresentableContext<Self>) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: NSViewRepresentableContext<Self>) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Terminal Full View

struct TerminalFullView: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView

    var body: some View {
        GeometryReader { geo in
            TerminalEmulator.SurfaceRepresentable(view: surfaceView, size: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .onTapGesture {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
        }
        .onAppear {
            // Auto-focus the terminal when it appears (e.g., when selected via keyboard)
            focusTerminal(surfaceView: surfaceView, retryCount: 0)
        }
    }

    /// Attempts to focus the terminal, retrying if the window isn't ready yet
    private func focusTerminal(surfaceView: TerminalEmulator.SurfaceView, retryCount: Int) {
        let maxRetries = 5
        let delay = 0.05 // 50ms between retries

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = surfaceView.window {
                window.makeFirstResponder(surfaceView)
                surfaceView.focus()
            } else if retryCount < maxRetries {
                // Window not ready yet, retry
                focusTerminal(surfaceView: surfaceView, retryCount: retryCount + 1)
            }
        }
    }
}

// MARK: - Empty Running Selection

struct EmptyRunningSelectionView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Terminal Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a running task to view its terminal")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            (colorScheme == .dark ? Color(hex: "292F30")! : Color.white)
                .ignoresSafeArea()
        }
    }
}

#endif

// MARK: - Token Histogram Overlay (Cross-platform)

struct TokenHistogramOverlay: View {
    let paneId: String?
    var foregroundColor: Color = .secondary
    @State private var costTracker = CostTracker.shared

    private var provider: AIProvider {
        guard let paneId = paneId else { return .claude }
        return costTracker.provider(forPaneId: paneId)
    }

    private var histogramValues: [Double] {
        guard let paneId = paneId else {
            return Array(repeating: 0.1, count: 12)
        }
        return costTracker.histogramValues(forTerminal: paneId)
    }

    private var totalTokens: Int {
        guard let paneId = paneId else { return 0 }
        return costTracker.currentSessionTokens(forTerminal: paneId)
    }

    var body: some View {
        HStack(spacing: 6) {
            AIProviderIcon(provider: provider, size: 14)
                .opacity(foregroundColor == .secondary ? 0.7 : 1.0)

            // Histogram bars
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    UnevenRoundedRectangle(topLeadingRadius: 1, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 1)
                        .fill(foregroundColor == .secondary ? provider.color : foregroundColor)
                        .frame(width: 5, height: max(2, value * 10))
                }
            }
            .frame(height: 10)

            Text(formatTokenCount(totalTokens))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0)
        .foregroundStyle(foregroundColor)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}
