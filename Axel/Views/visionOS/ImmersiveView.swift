import SwiftUI
import RealityKit
import SwiftData

#if os(visionOS)

// MARK: - Mission Control Immersive Experience

/// The immersive "Command Center" environment for Axel
/// A curved ultrawide display floating in space for ultimate productivity
struct ImmersiveView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.modelContext) private var modelContext

    // Query live data
    @Query(sort: \WorkTask.priority) private var tasks: [WorkTask]
    @Query(sort: \Skill.updatedAt, order: .reverse) private var skills: [Skill]
    @Query(sort: \InboxEvent.timestamp, order: .reverse) private var events: [InboxEvent]

    // Display transform state
    @State private var displayPosition: SIMD3<Float> = [0, 1.5, -3]
    @State private var displayScale: Float = 1.0

    var body: some View {
        RealityView { content, attachments in
            // Setup ambient lighting
            setupLighting(content: content)

            // Add starfield background
            let starfield = createStarfield()
            content.add(starfield)

            // Create main container
            let container = Entity()
            container.name = "CommandCenter"
            container.position = displayPosition

            // Add the main panel attachment
            if let mainPanel = attachments.entity(for: "mainPanel") {
                mainPanel.position = [0, 0, 0]
                mainPanel.scale = SIMD3<Float>(repeating: 0.001) // Convert points to meters
                container.addChild(mainPanel)
            }

            content.add(container)
        } update: { content, _ in
            // Update container position when state changes
            if let container = content.entities.first(where: { $0.name == "CommandCenter" }) {
                container.position = displayPosition
                container.scale = SIMD3<Float>(repeating: displayScale)
            }
        } attachments: {
            // Main curved panel with live data
            Attachment(id: "mainPanel") {
                CommandCenterPanel(
                    tasks: tasks,
                    skills: skills,
                    events: events
                )
                .frame(width: 2400, height: 800)
                .glassBackgroundEffect()
            }
        }
        .gesture(dragGesture)
        .gesture(magnifyGesture)
        .overlay(alignment: .bottom) {
            displayControls
        }
    }

    // MARK: - Control Panel

    private var displayControls: some View {
        HStack(spacing: 24) {
            // Distance control
            VStack(spacing: 6) {
                Text("Distance")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        withAnimation { displayPosition.z = min(-1.5, displayPosition.z + 0.5) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                    }
                    Text(String(format: "%.1fm", abs(displayPosition.z)))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50)
                    Button {
                        withAnimation { displayPosition.z = max(-6, displayPosition.z - 0.5) }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }

            Divider().frame(height: 50)

            // Height control
            VStack(spacing: 6) {
                Text("Height")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        withAnimation { displayPosition.y = max(0.5, displayPosition.y - 0.2) }
                    } label: {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.title3)
                    }
                    Text(String(format: "%.1fm", displayPosition.y))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50)
                    Button {
                        withAnimation { displayPosition.y = min(3.0, displayPosition.y + 0.2) }
                    } label: {
                        Image(systemName: "chevron.up.circle.fill")
                            .font(.title3)
                    }
                }
            }

            Divider().frame(height: 50)

            // Scale control
            VStack(spacing: 6) {
                Text("Scale")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        withAnimation { displayScale = max(0.5, displayScale - 0.1) }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.title3)
                    }
                    Text(String(format: "%.0f%%", displayScale * 100))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50)
                    Button {
                        withAnimation { displayScale = min(2.0, displayScale + 0.1) }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.title3)
                    }
                }
            }

            Divider().frame(height: 50)

            // Reset button
            Button {
                withAnimation {
                    displayPosition = [0, 1.5, -3]
                    displayScale = 1.0
                }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.body)
            }
            .buttonStyle(.bordered)

            // Exit button
            Button(role: .destructive) {
                Task {
                    await dismissImmersiveSpace()
                }
            } label: {
                Label("Exit", systemImage: "xmark.circle")
                    .font(.body)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .glassBackgroundEffect()
        .padding(.bottom, 60)
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                let translation = value.convert(value.translation3D, from: .local, to: .scene)
                displayPosition = [
                    displayPosition.x + Float(translation.x) * 0.002,
                    max(0.5, min(3.0, displayPosition.y + Float(translation.y) * 0.002)),
                    displayPosition.z + Float(translation.z) * 0.002
                ]
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                displayScale = max(0.5, min(2.0, Float(value.magnification)))
            }
    }

    // MARK: - Environment Setup

    private func setupLighting(content: RealityViewContent) {
        let lightingEntity = Entity()
        lightingEntity.name = "Lighting"

        // Main ambient light
        let ambientLight = Entity()
        let ambient = PointLightComponent(
            color: UIColor(red: 0.6, green: 0.7, blue: 1.0, alpha: 1.0),
            intensity: 500,
            attenuationRadius: 20
        )
        ambientLight.components.set(ambient)
        ambientLight.position = [0, 5, 0]
        lightingEntity.addChild(ambientLight)

        // Accent lights
        let accentPositions: [SIMD3<Float>] = [
            [-2, 3, -5],
            [2, 3, -5],
            [0, 2, -2]
        ]

        for position in accentPositions {
            let accentLight = Entity()
            let accent = PointLightComponent(
                color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0),
                intensity: 200,
                attenuationRadius: 6
            )
            accentLight.components.set(accent)
            accentLight.position = position
            lightingEntity.addChild(accentLight)
        }

        content.add(lightingEntity)
    }

    private func createStarfield() -> Entity {
        let starfieldEntity = Entity()
        starfieldEntity.name = "Starfield"

        var starMaterial = UnlitMaterial()
        starMaterial.color = .init(tint: .white)

        let starMesh = MeshResource.generateSphere(radius: 0.2)

        // Generate stars in a hemisphere
        for _ in 0..<200 {
            let star = ModelEntity(mesh: starMesh, materials: [starMaterial])

            let distance = Float.random(in: 50...200)
            let theta = Float.random(in: 0...(2 * .pi))
            let phi = Float.random(in: 0.2...Float.pi)

            star.position = [
                distance * sin(phi) * cos(theta),
                distance * cos(phi) + 10,
                distance * sin(phi) * sin(theta)
            ]

            let brightness = Float.random(in: 0.3...1.2)
            star.scale = [brightness, brightness, brightness]

            starfieldEntity.addChild(star)
        }

        return starfieldEntity
    }
}

// MARK: - Command Center Panel

struct CommandCenterPanel: View {
    let tasks: [WorkTask]
    let skills: [Skill]
    let events: [InboxEvent]

    private var runningTasks: [WorkTask] {
        tasks.filter { $0.taskStatus == .running }
    }

    private var queuedTasks: [WorkTask] {
        tasks.filter { $0.taskStatus.isPending }.sorted { $0.priority < $1.priority }
    }

    private var pendingEvents: [InboxEvent] {
        events.filter { !$0.isResolved }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Tasks Panel
            TasksPanelContent(
                runningTasks: runningTasks,
                queuedTasks: queuedTasks
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.3))

            // Skills Panel
            SkillsPanelContent(skills: skills)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .background(Color.white.opacity(0.3))

            // Inbox Panel
            InboxPanelContent(events: pendingEvents)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tasks Panel

struct TasksPanelContent: View {
    let runningTasks: [WorkTask]
    let queuedTasks: [WorkTask]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            CommandPanelHeader(
                title: "TASKS",
                icon: "rectangle.stack",
                accentColor: .blue,
                count: runningTasks.count + queuedTasks.count
            )

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !runningTasks.isEmpty {
                        Text("Running")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)

                        ForEach(runningTasks) { task in
                            ImmersiveTaskRow(task: task, isRunning: true)
                        }
                    }

                    if !queuedTasks.isEmpty {
                        Text("Up Next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)

                        ForEach(Array(queuedTasks.prefix(5).enumerated()), id: \.element.id) { index, task in
                            ImmersiveTaskRow(task: task, position: index + 1)
                        }
                    }

                    if runningTasks.isEmpty && queuedTasks.isEmpty {
                        ImmersiveEmptyState(
                            icon: "checkmark.circle",
                            message: "All tasks complete"
                        )
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

struct ImmersiveTaskRow: View {
    let task: WorkTask
    var isRunning: Bool = false
    var position: Int? = nil

    var body: some View {
        HStack(spacing: 16) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            } else if let position {
                Text("\(position)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            } else {
                Circle()
                    .fill(.blue.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(2)

                if let workspace = task.workspace {
                    Text(workspace.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(isRunning ? Color.green.opacity(0.1) : Color.clear)
    }
}

// MARK: - Skills Panel

struct SkillsPanelContent: View {
    let skills: [Skill]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            CommandPanelHeader(
                title: "SKILLS",
                icon: "hammer.fill",
                accentColor: .orange,
                count: skills.count
            )

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if skills.isEmpty {
                        ImmersiveEmptyState(
                            icon: "sparkles",
                            message: "No skills defined"
                        )
                    } else {
                        ForEach(skills.prefix(8)) { skill in
                            ImmersiveSkillRow(skill: skill)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }
}

struct ImmersiveSkillRow: View {
    let skill: Skill

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                Text(skill.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

// MARK: - Inbox Panel

struct InboxPanelContent: View {
    let events: [InboxEvent]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            CommandPanelHeader(
                title: "INBOX",
                icon: "tray.fill",
                accentColor: .pink,
                count: events.count
            )

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if events.isEmpty {
                        ImmersiveEmptyState(
                            icon: "checkmark.circle",
                            message: "Inbox clear"
                        )
                    } else {
                        ForEach(events.prefix(8)) { event in
                            ImmersiveInboxRow(event: event)
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
    }
}

struct ImmersiveInboxRow: View {
    let event: InboxEvent

    private var typeIcon: String {
        switch event.eventType {
        case .permission: return "lock.shield"
        case .hint: return "questionmark.bubble"
        case .toolUse: return "hammer"
        case .taskStart: return "play.circle"
        case .taskStop: return "stop.circle"
        default: return "bell"
        }
    }

    private var typeColor: Color {
        switch event.eventType {
        case .permission: return .orange
        case .hint: return .accentPurple
        case .toolUse: return .blue
        case .taskStart: return .green
        case .taskStop: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: typeIcon)
                .font(.system(size: 18))
                .foregroundStyle(typeColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title ?? event.eventType.rawValue.capitalized)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)

                Text(event.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if event.eventType == .permission {
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

// MARK: - Shared Components

struct CommandPanelHeader: View {
    let title: String
    let icon: String
    let accentColor: Color
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accentColor)

            Text(title)
                .font(.system(size: 18, weight: .bold))
                .tracking(1)

            Spacer()

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.8))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(accentColor.opacity(0.1))
    }
}

struct ImmersiveEmptyState: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Alternative Environments (preserved for future use)

/// A calmer "Focus" environment for deep work
struct FocusEnvironmentView: View {
    var body: some View {
        RealityView { content in
            // Soft gradient sky
            let skyMesh = MeshResource.generateSphere(radius: 500)
            var skyMaterial = UnlitMaterial()
            skyMaterial.color = .init(tint: UIColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1.0))

            let sky = ModelEntity(mesh: skyMesh, materials: [skyMaterial])
            sky.scale = .init(x: -1, y: 1, z: 1)
            content.add(sky)

            // Soft ambient orbs
            let orbColors: [UIColor] = [
                UIColor(red: 0.3, green: 0.4, blue: 0.6, alpha: 0.2),
                UIColor(red: 0.4, green: 0.3, blue: 0.5, alpha: 0.15),
                UIColor(red: 0.2, green: 0.5, blue: 0.5, alpha: 0.2)
            ]

            for (index, color) in orbColors.enumerated() {
                let orbMesh = MeshResource.generateSphere(radius: 30)
                var orbMaterial = UnlitMaterial()
                orbMaterial.color = .init(tint: color)

                let orb = ModelEntity(mesh: orbMesh, materials: [orbMaterial])
                orb.position = [
                    Float(index - 1) * 40,
                    20 + Float(index) * 10,
                    -60 - Float(index) * 15
                ]
                content.add(orb)
            }

            // Subtle ground reference
            let groundMesh = MeshResource.generatePlane(width: 100, depth: 100)
            var groundMaterial = UnlitMaterial()
            groundMaterial.color = .init(tint: UIColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.3))

            let ground = ModelEntity(mesh: groundMesh, materials: [groundMaterial])
            ground.position = [0, -0.5, 0]
            content.add(ground)
        }
    }
}

#endif
