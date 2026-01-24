import SwiftUI

#if os(macOS)
import AppKit

/// A SwiftUI view that embeds a terminal panel
struct TerminalPanelView: View {
    let workingDirectory: String?

    /// Use the shared terminal app singleton
    @ObservedObject private var terminalApp = TerminalEmulator.App.shared

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }

    var body: some View {
        Group {
            switch terminalApp.readiness {
            case .loading:
                loadingView
            case .error:
                errorView
            case .ready:
                terminalView
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting terminal...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text("Failed to initialize terminal")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
    }

    @ViewBuilder
    private var terminalView: some View {
        if let surfaceView = terminalApp.getOrCreateSurface(config: surfaceConfig) {
            SimpleSurfaceWrapper(surfaceView: surfaceView)
        }
    }

    /// Configuration for the terminal surface
    private var surfaceConfig: TerminalEmulator.SurfaceConfiguration {
        TerminalEmulator.SurfaceConfiguration(workingDirectory: workingDirectory)
    }
}

/// A simplified surface wrapper for embedded use
struct SimpleSurfaceWrapper: View {
    @ObservedObject var surfaceView: TerminalEmulator.SurfaceView

    // Must match TerminalEmulator.TerminalTheme.dark.background
    private let terminalBackground = Color.black
    private let padding: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let innerSize = CGSize(
                width: max(0, geo.size.width - padding * 2),
                height: max(0, geo.size.height - padding * 2)
            )

            TerminalEmulator.SurfaceRepresentable(view: surfaceView, size: innerSize)
                .frame(width: innerSize.width, height: innerSize.height)
                .padding(padding)
        }
        .background(terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
        )
    }
}

#else
// iOS fallback - show a placeholder
struct TerminalPanelView: View {
    let workingDirectory: String?

    init(workingDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Terminal not available on iOS")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

#Preview {
    TerminalPanelView()
        .frame(width: 600, height: 400)
}
