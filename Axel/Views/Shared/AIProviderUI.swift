import SwiftUI

// MARK: - AIProvider UI Extensions

extension AIProvider {
    /// The primary color associated with this provider
    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .green
        }
    }

    /// SF Symbol name for this provider (fallback icon)
    var systemImage: String {
        switch self {
        case .claude: return "brain"
        case .codex: return "chevron.left.forwardslash.chevron.right"
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

/// OpenAI Codex logo shape (hexagonal design inspired by OpenAI logo)
struct CodexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let centerX = rect.midX
        let centerY = rect.midY
        let outerRadius = size * 0.5
        let innerRadius = size * 0.25

        var path = Path()

        // Outer hexagon
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let x = centerX + outerRadius * cos(angle)
            let y = centerY + outerRadius * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()

        // Inner hexagon (cutout)
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let x = centerX + innerRadius * cos(angle)
            let y = centerY + innerRadius * sin(angle)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
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
