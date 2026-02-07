import SwiftUI

// MARK: - AIProvider UI Extensions

extension AIProvider {
    /// The primary color associated with this provider
    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return Color(red: 0x23/255.0, green: 0xAC/255.0, blue: 0x86/255.0) // #23AC86
        case .opencode: return .blue
        case .antigravity: return .accentPurple
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

/// OpenAI logo shape - simplified hexagonal spiral
struct CodexShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = size * 0.48
        let innerRadius = size * 0.18
        let strokeWidth = size * 0.12

        var path = Path()

        // Draw 6 "petals" that form the OpenAI spiral pattern
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2

            // Outer point of the petal
            let outerX = center.x + outerRadius * cos(angle)
            let outerY = center.y + outerRadius * sin(angle)

            // Inner point (rotated 30 degrees)
            let innerAngle = angle + .pi / 6
            let innerX = center.x + innerRadius * cos(innerAngle)
            let innerY = center.y + innerRadius * sin(innerAngle)

            // Draw a rounded rectangle/pill shape for each petal
            let petalPath = Path { p in
                let dx = outerX - innerX
                let dy = outerY - innerY
                let length = sqrt(dx * dx + dy * dy)
                let perpX = -dy / length * strokeWidth / 2
                let perpY = dx / length * strokeWidth / 2

                p.move(to: CGPoint(x: innerX + perpX, y: innerY + perpY))
                p.addLine(to: CGPoint(x: outerX + perpX, y: outerY + perpY))
                p.addArc(
                    center: CGPoint(x: outerX, y: outerY),
                    radius: strokeWidth / 2,
                    startAngle: Angle(radians: atan2(perpY, perpX)),
                    endAngle: Angle(radians: atan2(-perpY, -perpX)),
                    clockwise: false
                )
                p.addLine(to: CGPoint(x: innerX - perpX, y: innerY - perpY))
                p.addArc(
                    center: CGPoint(x: innerX, y: innerY),
                    radius: strokeWidth / 2,
                    startAngle: Angle(radians: atan2(-perpY, -perpX)),
                    endAngle: Angle(radians: atan2(perpY, perpX)),
                    clockwise: false
                )
                p.closeSubpath()
            }

            path.addPath(petalPath)
        }

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
            Image("CodexIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(provider.color)
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
        Image("CodexIcon")
            .renderingMode(.template)
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
