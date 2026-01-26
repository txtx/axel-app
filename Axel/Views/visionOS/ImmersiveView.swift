import SwiftUI
import RealityKit

#if os(visionOS)

// MARK: - Curved Display Generator

/// Creates a curved cylindrical arc mesh and renders SwiftUI content to it
@MainActor
class CurvedDisplayGenerator {

    /// Generate a curved screen mesh (arc of a cylinder, facing inward)
    static func generateMesh(
        radius: Float,
        height: Float,
        arcAngle: Float,
        segments: Int = 64
    ) -> MeshResource? {

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let halfArc = arcAngle / 2
        let halfHeight = height / 2
        let cols = segments + 1

        for row in 0..<2 {
            let y = row == 0 ? -halfHeight : halfHeight
            let v = Float(row)

            for col in 0...segments {
                let t = Float(col) / Float(segments)
                let angle = -halfArc + t * arcAngle

                let x = radius * sin(angle)
                let z = -radius * cos(angle)

                positions.append(SIMD3<Float>(x, y, z))
                normals.append(normalize(SIMD3<Float>(-sin(angle), 0, cos(angle))))
                uvs.append(SIMD2<Float>(t, v))
            }
        }

        for col in 0..<segments {
            let bl = UInt32(col)
            let br = UInt32(col + 1)
            let tl = UInt32(cols + col)
            let tr = UInt32(cols + col + 1)
            // Reversed winding for inward-facing surface
            indices.append(contentsOf: [bl, br, tl, tl, br, tr])
        }

        var descriptor = MeshDescriptor(name: "CurvedDisplay")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [descriptor])
    }

    /// Render SwiftUI view to a CGImage for texturing
    @MainActor
    static func renderToImage<V: View>(_ view: V, size: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2.0
        return renderer.cgImage
    }

    /// Create a textured curved display entity
    @MainActor
    static func createCurvedDisplay<V: View>(
        content: V,
        radius: Float,
        height: Float,
        arcAngle: Float,
        textureSize: CGSize = CGSize(width: 4096, height: 1024)
    ) async -> Entity? {

        guard let mesh = generateMesh(radius: radius, height: height, arcAngle: arcAngle) else {
            return nil
        }

        guard let cgImage = renderToImage(content, size: textureSize) else {
            return nil
        }

        guard let textureResource = try? await TextureResource(image: cgImage, options: .init(semantic: .color)) else {
            return nil
        }

        var material = UnlitMaterial()
        material.color = .init(texture: .init(textureResource))

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "CurvedDisplay"

        return entity
    }
}

/// The command center content to be rendered onto the curved display
struct CommandCenterContent: View {
    var body: some View {
        HStack(spacing: 0) {
            // Tasks
            VStack(spacing: 0) {
                CommandPanelHeader(title: "TASKS", icon: "checklist", accentColor: .cyan, count: 0)
                Spacer()
                Text("Tasks will appear here")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.cyan.opacity(0.05))

            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2)

            // Skills
            VStack(spacing: 0) {
                CommandPanelHeader(title: "SKILLS", icon: "cpu", accentColor: .purple, count: 0)
                Spacer()
                Text("Skills will appear here")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.purple.opacity(0.05))

            Rectangle().fill(Color.white.opacity(0.2)).frame(width: 2)

            // Inbox
            VStack(spacing: 0) {
                CommandPanelHeader(title: "INBOX", icon: "tray.full", accentColor: .orange, count: 0)
                Spacer()
                Text("Inbox will appear here")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.orange.opacity(0.05))
        }
        .background(Color.black.opacity(0.9))
    }
}

// MARK: - Mission Control Immersive Experience

/// The immersive "Launch Control" environment for Axel
/// Developers are commanders launching rockets of productivity
struct ImmersiveView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    // Display transform state
    @State private var displayPosition: SIMD3<Float> = [0, 1.5, 0]
    @State private var displayScale: Float = 1.0
    @State private var displayRadius: Float = 4.0
    @State private var displayHeight: Float = 1.5
    @State private var displayArcAngle: Float = 2.0

    // Gesture state
    @State private var isDragging = false
    @State private var curvedDisplayEntity: Entity?

    var body: some View {
        RealityView { content in
            // Add ambient lighting
            setupLighting(content: content)

            // Create the curved display with Metal mesh
            await setupCurvedDisplay(content: content)

        } update: { content in
            // Update display transform when state changes
            if let display = curvedDisplayEntity {
                display.position = displayPosition
                display.scale = SIMD3<Float>(repeating: displayScale)
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
        HStack(spacing: 20) {
            // Distance control
            VStack(spacing: 4) {
                Text("Distance")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(action: { displayRadius = max(2.0, displayRadius - 0.5) }) {
                        Image(systemName: "minus.circle.fill")
                    }
                    Text(String(format: "%.1fm", displayRadius))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)
                    Button(action: { displayRadius = min(8.0, displayRadius + 0.5) }) {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }

            Divider().frame(height: 40)

            // Height control
            VStack(spacing: 4) {
                Text("Height")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(action: { displayPosition.y = max(0.5, displayPosition.y - 0.2) }) {
                        Image(systemName: "chevron.down.circle.fill")
                    }
                    Text(String(format: "%.1fm", displayPosition.y))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)
                    Button(action: { displayPosition.y = min(3.0, displayPosition.y + 0.2) }) {
                        Image(systemName: "chevron.up.circle.fill")
                    }
                }
            }

            Divider().frame(height: 40)

            // Scale control
            VStack(spacing: 4) {
                Text("Scale")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(action: { displayScale = max(0.5, displayScale - 0.1) }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Text(String(format: "%.0f%%", displayScale * 100))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)
                    Button(action: { displayScale = min(2.0, displayScale + 0.1) }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
            }

            Divider().frame(height: 40)

            // Arc control
            VStack(spacing: 4) {
                Text("Curve")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(action: { displayArcAngle = max(1.0, displayArcAngle - 0.2) }) {
                        Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    }
                    Text(String(format: "%.0f°", displayArcAngle * 180 / .pi))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50)
                    Button(action: { displayArcAngle = min(3.0, displayArcAngle + 0.2) }) {
                        Image(systemName: "arrow.left.and.line.vertical.and.arrow.right")
                    }
                }
            }

            Divider().frame(height: 40)

            // Reset button
            Button(action: resetDisplay) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 40)
    }

    private func resetDisplay() {
        withAnimation {
            displayPosition = [0, 1.5, 0]
            displayScale = 1.0
            displayRadius = 4.0
            displayHeight = 1.5
            displayArcAngle = 2.0
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard value.entity.name == "CurvedDisplay" || value.entity.name == "DisplayContainer" else { return }
                let translation = value.convert(value.translation3D, from: .local, to: .scene)
                displayPosition = [
                    displayPosition.x + Float(translation.x) * 0.01,
                    max(0.5, min(3.0, displayPosition.y + Float(translation.y) * 0.01)),
                    displayPosition.z + Float(translation.z) * 0.01
                ]
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard value.entity.name == "CurvedDisplay" || value.entity.name == "DisplayContainer" else { return }
                displayScale = max(0.5, min(2.0, Float(value.magnification)))
            }
    }

    private func setupCurvedDisplay(content: RealityViewContent) async {
        let radius: Float = displayRadius
        let height: Float = displayHeight
        let arcAngle: Float = displayArcAngle

        // Create container for the entire display
        let container = Entity()
        container.name = "DisplayContainer"
        container.position = displayPosition

        // Generate the curved mesh
        guard let mesh = CurvedDisplayGenerator.generateMesh(
            radius: radius,
            height: height,
            arcAngle: arcAngle,
            segments: 48
        ) else {
            print("Failed to generate curved mesh")
            return
        }

        // Render the command center content to a texture
        let textureSize = CGSize(width: 4096, height: 1024)
        var material = UnlitMaterial()
        material.faceCulling = .none

        if let cgImage = CurvedDisplayGenerator.renderToImage(CommandCenterContent(), size: textureSize),
           let textureResource = try? await TextureResource(image: cgImage, options: .init(semantic: .color)) {
            material.color = .init(texture: .init(textureResource))
        } else {
            // Fallback to dark surface
            material.color = .init(tint: UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0))
        }

        let curvedDisplay = ModelEntity(mesh: mesh, materials: [material])
        curvedDisplay.name = "CurvedDisplay"

        // Enable gestures on the display
        curvedDisplay.components.set(InputTargetComponent())
        if let shape = try? await ShapeResource.generateConvex(from: mesh) {
            curvedDisplay.components.set(CollisionComponent(shapes: [shape]))
        }

        container.addChild(curvedDisplay)

        content.add(container)

        // Store reference for updates
        Task { @MainActor in
            self.curvedDisplayEntity = container
        }
    }

    private func addGlowingFrame(to container: Entity, radius: Float, height: Float, arcAngle: Float) {
        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0))

        let frameThickness: Float = 0.02
        let halfArc = arcAngle / 2
        let halfHeight = height / 2
        let frameRadius = radius - 0.01

        // Create top and bottom edge arcs
        let edgeSegments = 32
        for i in 0..<edgeSegments {
            let t1 = Float(i) / Float(edgeSegments)
            let t2 = Float(i + 1) / Float(edgeSegments)
            let angle1 = -halfArc + t1 * arcAngle
            let angle2 = -halfArc + t2 * arcAngle
            let midAngle = (angle1 + angle2) / 2

            let segmentLength = frameRadius * (angle2 - angle1) * 1.1
            let edgeMesh = MeshResource.generateBox(size: [segmentLength, frameThickness, frameThickness], cornerRadius: frameThickness / 3)

            // Top edge
            let topEdge = ModelEntity(mesh: edgeMesh, materials: [glowMaterial])
            topEdge.position = [
                frameRadius * sin(midAngle),
                halfHeight,
                -frameRadius * cos(midAngle)
            ]
            topEdge.orientation = simd_quatf(angle: midAngle, axis: [0, 1, 0])
            container.addChild(topEdge)

            // Bottom edge
            let bottomEdge = ModelEntity(mesh: edgeMesh, materials: [glowMaterial])
            bottomEdge.position = [
                frameRadius * sin(midAngle),
                -halfHeight,
                -frameRadius * cos(midAngle)
            ]
            bottomEdge.orientation = simd_quatf(angle: midAngle, axis: [0, 1, 0])
            container.addChild(bottomEdge)
        }

        // Vertical edges
        let vertMesh = MeshResource.generateBox(size: [frameThickness, height, frameThickness], cornerRadius: frameThickness / 3)

        let leftEdge = ModelEntity(mesh: vertMesh, materials: [glowMaterial])
        leftEdge.position = [frameRadius * sin(-halfArc), 0, -frameRadius * cos(-halfArc)]
        container.addChild(leftEdge)

        let rightEdge = ModelEntity(mesh: vertMesh, materials: [glowMaterial])
        rightEdge.position = [frameRadius * sin(halfArc), 0, -frameRadius * cos(halfArc)]
        container.addChild(rightEdge)
    }

    // MARK: - Space Environment

    @MainActor
    private func setupSpaceEnvironment(content: RealityViewContent) async {
        // Deep space skybox - dark with slight blue tint
        let skyboxMesh = MeshResource.generateSphere(radius: 500)

        var skyboxMaterial = UnlitMaterial()
        skyboxMaterial.color = .init(
            tint: .init(red: 0.02, green: 0.02, blue: 0.06, alpha: 1.0)
        )

        let skyboxEntity = ModelEntity(mesh: skyboxMesh, materials: [skyboxMaterial])
        skyboxEntity.scale = .init(x: -1, y: 1, z: 1)
        skyboxEntity.position = .zero
        skyboxEntity.name = "Skybox"

        content.add(skyboxEntity)

        // Create starfield
        let starfield = createStarfield()
        content.add(starfield)

        // Create distant nebula glow
        let nebula = createNebula()
        content.add(nebula)
    }

    private func createStarfield() -> Entity {
        let starfieldEntity = Entity()
        starfieldEntity.name = "Starfield"

        var starMaterial = UnlitMaterial()
        starMaterial.color = .init(tint: .white)

        let starMesh = MeshResource.generateSphere(radius: 0.3)

        // Generate stars in a hemisphere in front of and around user
        for _ in 0..<300 {
            let star = ModelEntity(mesh: starMesh, materials: [starMaterial])

            let distance = Float.random(in: 80...300)
            let theta = Float.random(in: 0...(2 * .pi))
            let phi = Float.random(in: 0.3...Float.pi) // Mostly above horizon

            star.position = [
                distance * sin(phi) * cos(theta),
                distance * cos(phi) + 20, // Offset upward
                distance * sin(phi) * sin(theta)
            ]

            // Vary star brightness through size
            let brightness = Float.random(in: 0.3...1.2)
            star.scale = [brightness, brightness, brightness]

            starfieldEntity.addChild(star)
        }

        return starfieldEntity
    }

    private func createNebula() -> Entity {
        let nebulaEntity = Entity()
        nebulaEntity.name = "Nebula"

        // Create soft glowing spheres for nebula effect
        let nebulaColors: [UIColor] = [
            UIColor(red: 0.2, green: 0.1, blue: 0.4, alpha: 0.3),
            UIColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 0.2),
            UIColor(red: 0.3, green: 0.1, blue: 0.3, alpha: 0.2)
        ]

        for (index, color) in nebulaColors.enumerated() {
            let nebulaMesh = MeshResource.generateSphere(radius: Float(60 + index * 20))

            var material = UnlitMaterial()
            material.color = .init(tint: color)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.15))

            let nebulaCloud = ModelEntity(mesh: nebulaMesh, materials: [material])
            nebulaCloud.position = [
                Float(index) * 30 - 30,
                Float(index) * 10 + 40,
                -100 - Float(index) * 20
            ]
            nebulaCloud.scale = .init(x: -1, y: 1, z: 1)

            nebulaEntity.addChild(nebulaCloud)
        }

        return nebulaEntity
    }

    // MARK: - Command Center

    @MainActor
    private func setupCommandCenter(content: RealityViewContent, attachments: RealityViewAttachments) async {
        let commandCenter = Entity()
        commandCenter.name = "CommandCenter"

        // Create the ultra-wide curved screen
        let curvedScreen = createUltraWideCurvedScreen()
        commandCenter.addChild(curvedScreen)

        // Position the 3 panels on the curved screen
        let screenRadius: Float = 4.0  // Distance from user
        let screenHeight: Float = 1.6  // Height of screen center
        let panelSpacing: Float = 0.52 // Radians between panels (~30 degrees)

        // Tasks panel - Left
        if let tasksAttachment = attachments.entity(for: "tasks") {
            let angle: Float = -panelSpacing
            tasksAttachment.position = [
                screenRadius * sin(angle),
                screenHeight,
                -screenRadius * cos(angle)
            ]
            // Face the center
            tasksAttachment.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            // Scale for proper sizing (points to meters)
            tasksAttachment.scale = [0.001, 0.001, 0.001]
            commandCenter.addChild(tasksAttachment)
        }

        // Skills panel - Center
        if let skillsAttachment = attachments.entity(for: "skills") {
            skillsAttachment.position = [0, screenHeight, -screenRadius]
            skillsAttachment.scale = [0.001, 0.001, 0.001]
            commandCenter.addChild(skillsAttachment)
        }

        // Inbox panel - Right
        if let inboxAttachment = attachments.entity(for: "inbox") {
            let angle: Float = panelSpacing
            inboxAttachment.position = [
                screenRadius * sin(angle),
                screenHeight,
                -screenRadius * cos(angle)
            ]
            inboxAttachment.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            inboxAttachment.scale = [0.001, 0.001, 0.001]
            commandCenter.addChild(inboxAttachment)
        }

        // Create floor grid (subtle reference for spatial grounding)
        let floor = createFloorGrid()
        commandCenter.addChild(floor)

        // Create console desk in front of user
        let console = createConsoleDesk()
        commandCenter.addChild(console)

        // Add holographic accent elements
        let accents = createHolographicAccents()
        commandCenter.addChild(accents)

        content.add(commandCenter)
    }

    private func createUltraWideCurvedScreen() -> Entity {
        let screenEntity = Entity()
        screenEntity.name = "CurvedScreen"

        let screenRadius: Float = 4.2  // Slightly behind the panels
        let screenHeight: Float = 0.9  // Total height of screen
        let screenWidth: Float = 5.5   // Arc width
        let arcAngle: Float = .pi * 0.55 // ~100 degree arc

        // Create the curved screen backing (dark glass material)
        let segmentCount = 24
        let startAngle: Float = -arcAngle / 2

        for i in 0..<segmentCount {
            let angle1 = startAngle + (Float(i) / Float(segmentCount)) * arcAngle
            let angle2 = startAngle + (Float(i + 1) / Float(segmentCount)) * arcAngle
            let midAngle = (angle1 + angle2) / 2

            let segmentWidth = screenRadius * (angle2 - angle1)
            let segmentMesh = MeshResource.generateBox(
                size: [segmentWidth * 1.1, screenHeight, 0.02],
                cornerRadius: 0.005
            )

            var screenMaterial = PhysicallyBasedMaterial()
            screenMaterial.baseColor = .init(tint: UIColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 0.95))
            screenMaterial.metallic = .init(floatLiteral: 0.1)
            screenMaterial.roughness = .init(floatLiteral: 0.1)

            let segment = ModelEntity(mesh: segmentMesh, materials: [screenMaterial])
            segment.position = [
                screenRadius * sin(midAngle),
                screenHeight / 2 + 1.2,
                -screenRadius * cos(midAngle)
            ]
            segment.orientation = simd_quatf(angle: midAngle, axis: [0, 1, 0])

            screenEntity.addChild(segment)
        }

        // Add glowing frame around the screen
        let frameEntity = createScreenFrame(radius: screenRadius, height: screenHeight, arcAngle: arcAngle)
        screenEntity.addChild(frameEntity)

        return screenEntity
    }

    private func createScreenFrame(radius: Float, height: Float, arcAngle: Float) -> Entity {
        let frameEntity = Entity()

        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: UIColor(red: 0.15, green: 0.4, blue: 0.9, alpha: 0.9))

        let frameThickness: Float = 0.015
        let startAngle: Float = -arcAngle / 2
        let frameRadius = radius + 0.03

        // Top edge
        let topSegments = 20
        for i in 0..<topSegments {
            let angle1 = startAngle + (Float(i) / Float(topSegments)) * arcAngle
            let angle2 = startAngle + (Float(i + 1) / Float(topSegments)) * arcAngle
            let midAngle = (angle1 + angle2) / 2

            let segmentLength = frameRadius * (angle2 - angle1) * 1.2
            let edgeMesh = MeshResource.generateBox(size: [segmentLength, frameThickness, frameThickness], cornerRadius: frameThickness / 3)
            let edge = ModelEntity(mesh: edgeMesh, materials: [glowMaterial])

            edge.position = [
                frameRadius * sin(midAngle),
                height + 1.2 + height / 2,
                -frameRadius * cos(midAngle)
            ]
            edge.orientation = simd_quatf(angle: midAngle, axis: [0, 1, 0])

            frameEntity.addChild(edge)
        }

        // Bottom edge
        for i in 0..<topSegments {
            let angle1 = startAngle + (Float(i) / Float(topSegments)) * arcAngle
            let angle2 = startAngle + (Float(i + 1) / Float(topSegments)) * arcAngle
            let midAngle = (angle1 + angle2) / 2

            let segmentLength = frameRadius * (angle2 - angle1) * 1.2
            let edgeMesh = MeshResource.generateBox(size: [segmentLength, frameThickness, frameThickness], cornerRadius: frameThickness / 3)
            let edge = ModelEntity(mesh: edgeMesh, materials: [glowMaterial])

            edge.position = [
                frameRadius * sin(midAngle),
                1.2 - height / 2,
                -frameRadius * cos(midAngle)
            ]
            edge.orientation = simd_quatf(angle: midAngle, axis: [0, 1, 0])

            frameEntity.addChild(edge)
        }

        // Vertical edges at ends
        let verticalEdgeMesh = MeshResource.generateBox(size: [frameThickness, height + 0.1, frameThickness], cornerRadius: frameThickness / 3)

        // Left vertical edge
        let leftEdge = ModelEntity(mesh: verticalEdgeMesh, materials: [glowMaterial])
        leftEdge.position = [
            frameRadius * sin(startAngle),
            height / 2 + 1.2,
            -frameRadius * cos(startAngle)
        ]
        frameEntity.addChild(leftEdge)

        // Right vertical edge
        let rightEdge = ModelEntity(mesh: verticalEdgeMesh, materials: [glowMaterial])
        rightEdge.position = [
            frameRadius * sin(-startAngle),
            height / 2 + 1.2,
            -frameRadius * cos(-startAngle)
        ]
        frameEntity.addChild(rightEdge)

        // Add divider lines between panels
        let dividerMesh = MeshResource.generateBox(size: [frameThickness * 0.5, height * 0.8, frameThickness * 0.5], cornerRadius: frameThickness / 4)

        var dividerMaterial = UnlitMaterial()
        dividerMaterial.color = .init(tint: UIColor(red: 0.15, green: 0.4, blue: 0.9, alpha: 0.5))

        let dividerAngle1: Float = -0.26
        let dividerAngle2: Float = 0.26

        let divider1 = ModelEntity(mesh: dividerMesh, materials: [dividerMaterial])
        divider1.position = [
            (radius + 0.01) * sin(dividerAngle1),
            height / 2 + 1.2,
            -(radius + 0.01) * cos(dividerAngle1)
        ]
        frameEntity.addChild(divider1)

        let divider2 = ModelEntity(mesh: dividerMesh, materials: [dividerMaterial])
        divider2.position = [
            (radius + 0.01) * sin(dividerAngle2),
            height / 2 + 1.2,
            -(radius + 0.01) * cos(dividerAngle2)
        ]
        frameEntity.addChild(divider2)

        return frameEntity
    }

    private func createCommandWall() -> Entity {
        let wallEntity = Entity()
        wallEntity.name = "CommandWall"

        // Create a curved wall segment (arc of a cylinder)
        // This sits behind where the SwiftUI windows will appear
        let wallRadius: Float = 6.0
        let wallHeight: Float = 4.0
        let wallThickness: Float = 0.1

        // Create multiple wall panels in an arc
        let panelCount = 7
        let arcAngle: Float = .pi * 0.6 // 108 degrees
        let startAngle: Float = -.pi / 2 - arcAngle / 2

        for i in 0..<panelCount {
            let angle = startAngle + (Float(i) / Float(panelCount - 1)) * arcAngle

            // Panel geometry
            let panelWidth: Float = 1.2
            let panelMesh = MeshResource.generateBox(
                size: [panelWidth, wallHeight, wallThickness],
                cornerRadius: 0.02
            )

            var panelMaterial = PhysicallyBasedMaterial()
            panelMaterial.baseColor = .init(tint: UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0))
            panelMaterial.metallic = .init(floatLiteral: 0.7)
            panelMaterial.roughness = .init(floatLiteral: 0.3)

            let panel = ModelEntity(mesh: panelMesh, materials: [panelMaterial])

            // Position on arc
            panel.position = [
                wallRadius * sin(angle),
                wallHeight / 2 + 0.5, // Raise off floor
                -wallRadius * cos(angle)
            ]

            // Rotate to face center
            panel.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])

            wallEntity.addChild(panel)
        }

        // Add glowing edge strips
        let edgeStrips = createEdgeStrips(radius: wallRadius, height: wallHeight)
        wallEntity.addChild(edgeStrips)

        return wallEntity
    }

    private func createEdgeStrips(radius: Float, height: Float) -> Entity {
        let stripsEntity = Entity()

        var glowMaterial = UnlitMaterial()
        glowMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.8))

        let stripMesh = MeshResource.generateBox(size: [0.02, height + 0.1, 0.02], cornerRadius: 0.01)

        // Vertical edge strips
        let stripCount = 8
        let arcAngle: Float = .pi * 0.6
        let startAngle: Float = -.pi / 2 - arcAngle / 2

        for i in 0..<stripCount {
            let angle = startAngle + (Float(i) / Float(stripCount - 1)) * arcAngle
            let strip = ModelEntity(mesh: stripMesh, materials: [glowMaterial])

            strip.position = [
                (radius + 0.05) * sin(angle),
                height / 2 + 0.5,
                -(radius + 0.05) * cos(angle)
            ]

            stripsEntity.addChild(strip)
        }

        // Horizontal top strip (arc)
        let topStripMesh = MeshResource.generateBox(size: [0.8, 0.02, 0.02], cornerRadius: 0.01)
        for i in 0..<(stripCount - 1) {
            let angle = startAngle + (Float(i) + 0.5) / Float(stripCount - 1) * arcAngle
            let topStrip = ModelEntity(mesh: topStripMesh, materials: [glowMaterial])

            topStrip.position = [
                (radius + 0.05) * sin(angle),
                height + 0.55,
                -(radius + 0.05) * cos(angle)
            ]
            topStrip.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])

            stripsEntity.addChild(topStrip)
        }

        return stripsEntity
    }

    private func createFloorGrid() -> Entity {
        let floorEntity = Entity()
        floorEntity.name = "FloorGrid"

        var gridMaterial = UnlitMaterial()
        gridMaterial.color = .init(tint: UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.3))

        let lineMesh = MeshResource.generateBox(size: [0.01, 0.005, 10], cornerRadius: 0.002)

        // Create grid lines
        let gridSize = 10
        let spacing: Float = 1.0

        for i in -gridSize...gridSize {
            // Lines along Z
            let lineZ = ModelEntity(mesh: lineMesh, materials: [gridMaterial])
            lineZ.position = [Float(i) * spacing, 0, -3]
            floorEntity.addChild(lineZ)

            // Lines along X
            let lineXMesh = MeshResource.generateBox(size: [10, 0.005, 0.01], cornerRadius: 0.002)
            let lineX = ModelEntity(mesh: lineXMesh, materials: [gridMaterial])
            lineX.position = [0, 0, Float(i) * spacing - 3]
            floorEntity.addChild(lineX)
        }

        return floorEntity
    }

    private func createConsoleDesk() -> Entity {
        let consoleEntity = Entity()
        consoleEntity.name = "Console"

        // Main desk surface
        let deskMesh = MeshResource.generateBox(
            size: [2.5, 0.08, 0.8],
            cornerRadius: 0.02
        )

        var deskMaterial = PhysicallyBasedMaterial()
        deskMaterial.baseColor = .init(tint: UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0))
        deskMaterial.metallic = .init(floatLiteral: 0.9)
        deskMaterial.roughness = .init(floatLiteral: 0.2)

        let desk = ModelEntity(mesh: deskMesh, materials: [deskMaterial])
        desk.position = [0, 0.75, -1.2]
        consoleEntity.addChild(desk)

        // Glowing edge on desk
        var edgeMaterial = UnlitMaterial()
        edgeMaterial.color = .init(tint: UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9))

        let edgeMesh = MeshResource.generateBox(size: [2.5, 0.01, 0.02], cornerRadius: 0.005)
        let edge = ModelEntity(mesh: edgeMesh, materials: [edgeMaterial])
        edge.position = [0, 0.79, -0.8]
        consoleEntity.addChild(edge)

        // Small status indicators on desk
        let indicatorMesh = MeshResource.generateSphere(radius: 0.03)
        let indicatorColors: [UIColor] = [
            .systemGreen, .systemBlue, .systemCyan, .systemGreen, .systemBlue
        ]

        for (index, color) in indicatorColors.enumerated() {
            var indicatorMaterial = UnlitMaterial()
            indicatorMaterial.color = .init(tint: color)

            let indicator = ModelEntity(mesh: indicatorMesh, materials: [indicatorMaterial])
            indicator.position = [
                Float(index) * 0.4 - 0.8,
                0.82,
                -1.4
            ]
            consoleEntity.addChild(indicator)
        }

        return consoleEntity
    }

    private func createHolographicAccents() -> Entity {
        let accentsEntity = Entity()
        accentsEntity.name = "HolographicAccents"

        // Floating data visualization rings
        let ringMesh = MeshResource.generateBox(size: [0.6, 0.01, 0.6], cornerRadius: 0.3)

        var ringMaterial = UnlitMaterial()
        ringMaterial.color = .init(tint: UIColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.4))

        // Create orbiting rings at different positions
        let ringPositions: [SIMD3<Float>] = [
            [-3.5, 2.5, -4],
            [3.5, 2.8, -4],
            [-4, 1.5, -3],
            [4, 1.2, -3.5]
        ]

        for position in ringPositions {
            let ring = ModelEntity(mesh: ringMesh, materials: [ringMaterial])
            ring.position = position

            // Random rotation
            ring.orientation = simd_quatf(
                angle: Float.random(in: 0...(.pi * 2)),
                axis: normalize([Float.random(in: -1...1), 1, Float.random(in: -1...1)])
            )

            accentsEntity.addChild(ring)
        }

        return accentsEntity
    }

    // MARK: - Lighting

    private func setupLighting(content: RealityViewContent) {
        let lightingEntity = Entity()
        lightingEntity.name = "Lighting"

        // Main ambient light (soft blue)
        let ambientLight = Entity()
        let ambient = PointLightComponent(
            color: UIColor(red: 0.6, green: 0.7, blue: 1.0, alpha: 1.0),
            intensity: 500,
            attenuationRadius: 20
        )
        ambientLight.components.set(ambient)
        ambientLight.position = [0, 5, 0]
        lightingEntity.addChild(ambientLight)

        // Accent lights for command wall
        let accentPositions: [SIMD3<Float>] = [
            [-2, 3, -5],
            [2, 3, -5],
            [0, 4, -6]
        ]

        for position in accentPositions {
            let accentLight = Entity()
            let accent = PointLightComponent(
                color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0),
                intensity: 300,
                attenuationRadius: 8
            )
            accentLight.components.set(accent)
            accentLight.position = position
            lightingEntity.addChild(accentLight)
        }

        // Warm light from console (simulating screen glow)
        let consoleLight = Entity()
        let console = PointLightComponent(
            color: UIColor(red: 1.0, green: 0.9, blue: 0.8, alpha: 1.0),
            intensity: 200,
            attenuationRadius: 3
        )
        consoleLight.components.set(console)
        consoleLight.position = [0, 1, -1]
        lightingEntity.addChild(consoleLight)

        content.add(lightingEntity)
    }

    // MARK: - Particle Effects

    private func setupParticleEffects(content: RealityViewContent) {
        let particlesEntity = Entity()
        particlesEntity.name = "Particles"

        // Floating dust motes / data particles
        var particleMaterial = UnlitMaterial()
        particleMaterial.color = .init(tint: UIColor(red: 0.5, green: 0.7, blue: 1.0, alpha: 0.6))

        let particleMesh = MeshResource.generateSphere(radius: 0.02)

        for _ in 0..<50 {
            let particle = ModelEntity(mesh: particleMesh, materials: [particleMaterial])

            let xPos = Float.random(in: -5...5)
            let yPos = Float.random(in: 0.5...4)
            let zPos = Float.random(in: -6 ... -1)
            particle.position = [xPos, yPos, zPos]

            // Vary size
            let size = Float.random(in: 0.5...1.5)
            particle.scale = [size, size, size]

            particlesEntity.addChild(particle)
        }

        content.add(particlesEntity)
    }
}

// MARK: - Alternative Environments

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

/// High-energy "Launch" environment for shipping features
struct LaunchEnvironmentView: View {
    var body: some View {
        RealityView { content in
            setupLaunchEnvironment(content: content)
        }
    }

    private func setupLaunchEnvironment(content: RealityViewContent) {
        // Dramatic dark sky with energy
        let skyMesh = MeshResource.generateSphere(radius: 500)
        var skyMaterial = UnlitMaterial()
        skyMaterial.color = .init(tint: UIColor(red: 0.03, green: 0.02, blue: 0.08, alpha: 1.0))

        let sky = ModelEntity(mesh: skyMesh, materials: [skyMaterial])
        sky.scale = .init(x: -1, y: 1, z: 1)
        content.add(sky)

        // Intense stars
        let starMesh = MeshResource.generateSphere(radius: 0.4)
        for _ in 0..<500 {
            var starMaterial = UnlitMaterial()
            starMaterial.color = .init(tint: .white)

            let star = ModelEntity(mesh: starMesh, materials: [starMaterial])

            let distance = Float.random(in: 100...400)
            let theta = Float.random(in: 0...(2 * .pi))
            let phi = Float.random(in: 0...Float.pi)

            star.position = [
                distance * sin(phi) * cos(theta),
                distance * cos(phi),
                distance * sin(phi) * sin(theta)
            ]

            let size = Float.random(in: 0.3...1.5)
            star.scale = [size, size, size]

            content.add(star)
        }

        // Launch platform glow
        let platformMesh = MeshResource.generateCylinder(height: 0.05, radius: 3)
        var platformMaterial = UnlitMaterial()
        platformMaterial.color = .init(tint: UIColor(red: 0.4, green: 0.6, blue: 1.0, alpha: 0.3))

        let platform = ModelEntity(mesh: platformMesh, materials: [platformMaterial])
        platform.position = [0, 0, -3]
        content.add(platform)

        // Energy rings around platform
        for i in 0..<3 {
            let ringSize = Float(3 + i)
            let cornerRadius = Float(1.5) + Float(i) * 0.5
            let ringMesh = MeshResource.generateBox(size: [ringSize, 0.02, ringSize], cornerRadius: cornerRadius)

            var ringMaterial = UnlitMaterial()
            let alpha = 0.5 - Float(i) * 0.15
            ringMaterial.color = .init(tint: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: CGFloat(alpha)))

            let ring = ModelEntity(mesh: ringMesh, materials: [ringMaterial])
            ring.position = [0, Float(i) * 0.3 + 0.1, -3]
            content.add(ring)
        }
    }
}

#endif
