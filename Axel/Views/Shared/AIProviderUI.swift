import SwiftUI

// MARK: - AIProvider UI Extensions

extension AIProvider {
    /// The primary color associated with this provider
    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return Color(red: 0x23/255.0, green: 0xAC/255.0, blue: 0x86/255.0) // #23AC86
        case .opencode: return .blue
        case .antigravity: return .purple
        case .shell: return .yellow
        case .custom: return .gray
        }
    }

    /// SF Symbol name for this provider (fallback icon)
    var systemImage: String {
        switch self {
        case .claude: return "brain"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        case .antigravity: return "sparkles"
        case .shell: return "terminal.fill"
        case .custom: return "gearshape"
        }
    }
}

// MARK: - Provider Shapes

/// Claude logo shape
struct ClaudeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scaleX = rect.width / 128
        let scaleY = rect.height / 88

        var path = Path()

        // Main shape
        path.move(to: CGPoint(x: 112 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 128 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 128 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 104 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 104 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 80 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 80 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 48 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 48 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 24 * scaleX, y: 88 * scaleY))
        path.addLine(to: CGPoint(x: 24 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 70 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 53 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 16 * scaleX, y: 0 * scaleY))
        path.addLine(to: CGPoint(x: 112 * scaleX, y: 0 * scaleY))
        path.closeSubpath()

        // Left eye (cutout)
        path.move(to: CGPoint(x: 32 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 40 * scaleX, y: 17 * scaleY))
        path.addLine(to: CGPoint(x: 32 * scaleX, y: 17 * scaleY))
        path.closeSubpath()

        // Right eye (cutout)
        path.move(to: CGPoint(x: 88 * scaleX, y: 17 * scaleY))
        path.addLine(to: CGPoint(x: 88 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 35 * scaleY))
        path.addLine(to: CGPoint(x: 96 * scaleX, y: 17 * scaleY))
        path.closeSubpath()

        return path
    }
}

/// OpenAI logo shape (the distinctive knot/swirl pattern)
struct CodexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24.0
        let offsetX = rect.midX - 12 * scale
        let offsetY = rect.midY - 12 * scale

        var path = Path()

        // OpenAI logo path - scaled and centered
        // Based on the OpenAI logo SVG path
        path.move(to: CGPoint(x: offsetX + 22.2819 * scale, y: offsetY + 9.8211 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 19.9526 * scale, y: offsetY + 3.9478 * scale),
            control1: CGPoint(x: offsetX + 23.5349 * scale, y: offsetY + 7.4553 * scale),
            control2: CGPoint(x: offsetX + 22.5765 * scale, y: offsetY + 4.9484 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 14.0027 * scale, y: offsetY + 2.8286 * scale),
            control1: CGPoint(x: offsetX + 17.3288 * scale, y: offsetY + 2.9471 * scale),
            control2: CGPoint(x: offsetX + 14.586 * scale, y: offsetY + 2.4754 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 10.0794 * scale, y: offsetY + 4.4137 * scale),
            control1: CGPoint(x: offsetX + 12.5037 * scale, y: offsetY + 2.2453 * scale),
            control2: CGPoint(x: offsetX + 10.8549 * scale, y: offsetY + 2.9237 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 9.5313 * scale, y: offsetY + 6.2226 * scale),
            control1: CGPoint(x: offsetX + 9.7639 * scale, y: offsetY + 5.0204 * scale),
            control2: CGPoint(x: offsetX + 9.5664 * scale, y: offsetY + 5.6276 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 5.1741 * scale, y: offsetY + 8.2857 * scale),
            control1: CGPoint(x: offsetX + 7.8067 * scale, y: offsetY + 5.8928 * scale),
            control2: CGPoint(x: offsetX + 6.1981 * scale, y: offsetY + 6.6539 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 4.5208 * scale, y: offsetY + 14.4539 * scale),
            control1: CGPoint(x: offsetX + 3.3953 * scale, y: offsetY + 11.1117 * scale),
            control2: CGPoint(x: offsetX + 3.2912 * scale, y: offsetY + 13.2242 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 5.4746 * scale, y: offsetY + 15.1891 * scale),
            control1: CGPoint(x: offsetX + 4.7895 * scale, y: offsetY + 14.7524 * scale),
            control2: CGPoint(x: offsetX + 5.1175 * scale, y: offsetY + 14.9972 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 4.0474 * scale, y: offsetY + 20.0523 * scale),
            control1: CGPoint(x: offsetX + 4.2216 * scale, y: offsetY + 17.5549 * scale),
            control2: CGPoint(x: offsetX + 3.0468 * scale, y: offsetY + 17.4285 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 9.9973 * scale, y: offsetY + 21.1714 * scale),
            control1: CGPoint(x: offsetX + 5.0481 * scale, y: offsetY + 22.6762 * scale),
            control2: CGPoint(x: offsetX + 7.5849 * scale, y: offsetY + 23.1287 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 13.9206 * scale, y: offsetY + 19.5863 * scale),
            control1: CGPoint(x: offsetX + 11.4963 * scale, y: offsetY + 21.7548 * scale),
            control2: CGPoint(x: offsetX + 13.1451 * scale, y: offsetY + 21.0763 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 14.4687 * scale, y: offsetY + 17.7774 * scale),
            control1: CGPoint(x: offsetX + 14.2361 * scale, y: offsetY + 18.9797 * scale),
            control2: CGPoint(x: offsetX + 14.4336 * scale, y: offsetY + 18.3724 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 18.8259 * scale, y: offsetY + 15.7143 * scale),
            control1: CGPoint(x: offsetX + 16.1933 * scale, y: offsetY + 18.1072 * scale),
            control2: CGPoint(x: offsetX + 17.8019 * scale, y: offsetY + 17.3461 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 19.4792 * scale, y: offsetY + 9.5461 * scale),
            control1: CGPoint(x: offsetX + 20.6047 * scale, y: offsetY + 12.8883 * scale),
            control2: CGPoint(x: offsetX + 20.7088 * scale, y: offsetY + 10.7758 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 18.5254 * scale, y: offsetY + 8.8109 * scale),
            control1: CGPoint(x: offsetX + 19.2105 * scale, y: offsetY + 9.2476 * scale),
            control2: CGPoint(x: offsetX + 18.8825 * scale, y: offsetY + 9.0028 * scale)
        )
        path.addCurve(
            to: CGPoint(x: offsetX + 22.2819 * scale, y: offsetY + 9.8211 * scale),
            control1: CGPoint(x: offsetX + 20.1266 * scale, y: offsetY + 7.5254 * scale),
            control2: CGPoint(x: offsetX + 21.7922 * scale, y: offsetY + 8.2673 * scale)
        )
        path.closeSubpath()

        // Inner details - the connecting lines
        path.move(to: CGPoint(x: offsetX + 14.9466 * scale, y: offsetY + 13.6018 * scale))
        path.addLine(to: CGPoint(x: offsetX + 8.3448 * scale, y: offsetY + 17.4125 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 7.0218 * scale, y: offsetY + 15.8274 * scale),
            control1: CGPoint(x: offsetX + 7.8317 * scale, y: offsetY + 16.9928 * scale),
            control2: CGPoint(x: offsetX + 7.3789 * scale, y: offsetY + 16.4458 * scale)
        )
        path.addLine(to: CGPoint(x: offsetX + 13.6237 * scale, y: offsetY + 12.0167 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 14.9466 * scale, y: offsetY + 13.6018 * scale),
            control1: CGPoint(x: offsetX + 14.1368 * scale, y: offsetY + 12.4364 * scale),
            control2: CGPoint(x: offsetX + 14.5895 * scale, y: offsetY + 12.9834 * scale)
        )
        path.closeSubpath()

        path.move(to: CGPoint(x: offsetX + 16.9763 * scale, y: offsetY + 15.8274 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 15.6534 * scale, y: offsetY + 17.4125 * scale),
            control1: CGPoint(x: offsetX + 16.6192 * scale, y: offsetY + 16.4458 * scale),
            control2: CGPoint(x: offsetX + 16.1664 * scale, y: offsetY + 16.9928 * scale)
        )
        path.addLine(to: CGPoint(x: offsetX + 9.0516 * scale, y: offsetY + 13.6018 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 10.3745 * scale, y: offsetY + 12.0167 * scale),
            control1: CGPoint(x: offsetX + 9.4087 * scale, y: offsetY + 12.9834 * scale),
            control2: CGPoint(x: offsetX + 9.8614 * scale, y: offsetY + 12.4364 * scale)
        )
        path.addLine(to: CGPoint(x: offsetX + 16.9763 * scale, y: offsetY + 15.8274 * scale))
        path.closeSubpath()

        path.move(to: CGPoint(x: offsetX + 12 * scale, y: offsetY + 10.4161 * scale))
        path.addLine(to: CGPoint(x: offsetX + 12 * scale, y: offsetY + 3.3411 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 13.9206 * scale, y: offsetY + 3.4113 * scale),
            control1: CGPoint(x: offsetX + 12.6534 * scale, y: offsetY + 3.2943 * scale),
            control2: CGPoint(x: offsetX + 13.3022 * scale, y: offsetY + 3.3177 * scale)
        )
        path.addLine(to: CGPoint(x: offsetX + 13.9206 * scale, y: offsetY + 10.4863 * scale))
        path.addCurve(
            to: CGPoint(x: offsetX + 12 * scale, y: offsetY + 10.4161 * scale),
            control1: CGPoint(x: offsetX + 13.3022 * scale, y: offsetY + 10.5799 * scale),
            control2: CGPoint(x: offsetX + 12.6534 * scale, y: offsetY + 10.5565 * scale)
        )
        path.closeSubpath()

        return path
    }
}

// MARK: - Provider Icon View

/// A view that displays the appropriate icon for an AI provider
struct AIProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch provider {
            case .claude:
                ClaudeShape()
                    .fill(provider.color)
                    .frame(width: size, height: size * 88 / 128)
            case .codex:
                CodexShape()
                    .fill(provider.color)
                    .frame(width: size, height: size)
            case .opencode, .antigravity, .shell, .custom:
                Image(systemName: provider.systemImage)
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(provider.color)
                    .frame(width: size, height: size)
            }
        }
    }
}

/// A view that displays the provider shape with custom fill
struct AIProviderShape: View {
    let provider: AIProvider

    var body: some View {
        switch provider {
        case .claude:
            ClaudeShape()
        case .codex:
            CodexShape()
        case .opencode, .antigravity, .shell, .custom:
            Image(systemName: provider.systemImage)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ForEach(AIProvider.allCases, id: \.self) { provider in
            HStack(spacing: 12) {
                AIProviderIcon(provider: provider, size: 24)
                Text(provider.displayName)
                    .foregroundStyle(provider.color)
            }
        }
    }
    .padding()
}
