import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

// MARK: - Local Agent File

/// Represents an agent file loaded from the filesystem
struct LocalAgentFile: Identifiable, Hashable {
    let id: String
    let name: String
    let path: URL
    let content: String

    init(path: URL) {
        self.id = path.absoluteString
        self.path = path
        self.name = path.deletingPathExtension().lastPathComponent
        self.content = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocalAgentFile, rhs: LocalAgentFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Agent Selection

/// Unified selection type for agents from different sources
enum AgentSelection: Hashable {
    case local(LocalAgentFile)
    case skill(Skill)

    var name: String {
        switch self {
        case .local(let file): return file.name
        case .skill(let skill): return skill.name
        }
    }

    var content: String {
        switch self {
        case .local(let file): return file.content
        case .skill(let skill): return skill.content
        }
    }
}

// MARK: - Skills List View (Middle Column)

struct SkillsListView: View {
    let workspace: Workspace?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.updatedAt, order: .reverse) private var skills: [Skill]

    @Binding var selection: AgentSelection?
    @State private var isCreatingSkill = false
    @State private var localAgents: [LocalAgentFile] = []
    @State private var globalAgents: [LocalAgentFile] = []

    /// Total count of all agents
    private var totalCount: Int {
        localAgents.count + globalAgents.count + skills.count
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack {
                Text("Agents")
                    .font(.title2.bold())
                Spacer()
                Text("\(totalCount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #endif

            if totalCount == 0 {
                emptyState
            } else {
                List(selection: $selection) {
                    // Workspace Agents Section
                    if !localAgents.isEmpty {
                        Section {
                            ForEach(localAgents) { agent in
                                LocalAgentRow(agent: agent)
                                    .tag(AgentSelection.local(agent))
                            }
                        } header: {
                            Label("Workspace", systemImage: "folder")
                        }
                    }

                    // Global Agents Section
                    if !globalAgents.isEmpty {
                        Section {
                            ForEach(globalAgents) { agent in
                                LocalAgentRow(agent: agent)
                                    .tag(AgentSelection.local(agent))
                            }
                        } header: {
                            Label("Global", systemImage: "globe")
                        }
                    }

                    // Custom Skills Section
                    if !skills.isEmpty {
                        Section {
                            ForEach(skills) { skill in
                                SkillRowView(skill: skill, isSelected: false)
                                    .tag(AgentSelection.skill(skill))
                            }
                            .onDelete(perform: deleteSkills)
                        } header: {
                            Label("Custom", systemImage: "sparkles")
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // New Skill button
            Button {
                isCreatingSkill = true
            } label: {
                Label("New Agent", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SkillsButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        #if os(iOS)
        .navigationTitle("Agents")
        #endif
        .background(.background)
        .onAppear {
            loadLocalAgents()
            #if os(macOS)
            loadGlobalAgents()
            #endif
        }
        .sheet(isPresented: $isCreatingSkill) {
            CreateSkillView(isPresented: $isCreatingSkill, onCreated: { skill in
                selection = .skill(skill)
            })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("No Agents")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Add agents to ./agents, ~/.config/axel/agents, or create custom ones")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                isCreatingSkill = true
            } label: {
                Label("New Agent", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadLocalAgents() {
        guard let workspacePath = workspace?.path else {
            localAgents = []
            return
        }

        let agentsDir = URL(fileURLWithPath: workspacePath).appendingPathComponent("agents")

        guard FileManager.default.fileExists(atPath: agentsDir.path) else {
            localAgents = []
            return
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: agentsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            localAgents = files
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { LocalAgentFile(path: $0) }
        } catch {
            print("[SkillsView] Failed to load agents: \(error)")
            localAgents = []
        }
    }

    #if os(macOS)
    private func loadGlobalAgents() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let globalAgentsDir = homeDir.appendingPathComponent(".config/axel/agents")

        guard FileManager.default.fileExists(atPath: globalAgentsDir.path) else {
            globalAgents = []
            return
        }

        do {
            // Global agents use directory structure: <name>/AGENT.md
            let contents = try FileManager.default.contentsOfDirectory(
                at: globalAgentsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var agents: [LocalAgentFile] = []

            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // Check for AGENT.md inside the directory
                    let agentFile = item.appendingPathComponent("AGENT.md")
                    if FileManager.default.fileExists(atPath: agentFile.path) {
                        agents.append(LocalAgentFile(path: agentFile))
                    }
                } else if item.pathExtension == "md" {
                    // Also support flat .md files (excluding index.md)
                    if item.lastPathComponent != "index.md" {
                        agents.append(LocalAgentFile(path: item))
                    }
                }
            }

            globalAgents = agents.sorted { $0.name < $1.name }
        } catch {
            print("[SkillsView] Failed to load global agents: \(error)")
            globalAgents = []
        }
    }
    #endif

    private func deleteSkills(at offsets: IndexSet) {
        for index in offsets {
            let skill = skills[index]
            if case .skill(let selected) = selection, selected == skill {
                selection = nil
            }
            modelContext.delete(skill)
        }
    }
}

// MARK: - Local Agent Row

struct LocalAgentRow: View {
    let agent: LocalAgentFile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.body)
                    .lineLimit(1)

                Text(agent.path.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Create Skill View

struct CreateSkillView: View {
    @Binding var isPresented: Bool
    var onCreated: ((Skill) -> Void)?
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var content = ""
    @FocusState private var isNameFocused: Bool
    @FocusState private var isContentFocused: Bool

    private static let skillTemplate = """
---
name: ""
description: ""
triggers:
  - ""
---

## Instructions

Describe what this skill does and how the agent should behave.

## Examples

Provide examples of when this skill should be used.
"""

    var body: some View {
        #if os(iOS) || os(visionOS)
        NavigationStack {
            createSkillContent
                .navigationTitle("New Skill")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            createSkill()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.orange)

                TextField("Skill name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.medium))
                    .focused($isNameFocused)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Markdown editor
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($isContentFocused)
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack(spacing: 16) {
                Spacer()

                Button("Create") {
                    createSkill()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 600, height: 480)
        .background(.background)
        .onAppear {
            isNameFocused = true
            content = Self.skillTemplate
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
    private var createSkillContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)

                TextField("Skill name", text: $name)
                    .font(.title3)
                    .focused($isNameFocused)
            }
            .padding()

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
        }
        .onAppear {
            isNameFocused = true
            content = Self.skillTemplate
        }
    }
    #endif

    private func createSkill() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Update the name in the frontmatter
        var finalContent = content
        if finalContent.contains("name: \"\"") {
            finalContent = finalContent.replacingOccurrences(of: "name: \"\"", with: "name: \"\(trimmedName)\"")
        }

        let skill = Skill(name: trimmedName, content: finalContent)
        modelContext.insert(skill)
        onCreated?(skill)
        isPresented = false
    }
}

struct SkillRowView: View {
    let skill: Skill
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.body)
                    .lineLimit(1)

                Text(skill.updatedAt, style: .relative)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

// MARK: - Agent Detail View (Right Panel)

struct AgentDetailView: View {
    let agent: AgentSelection

    var body: some View {
        switch agent {
        case .local(let file):
            LocalAgentDetailView(agent: file)
        case .skill(let skill):
            SkillDetailView(skill: skill)
        }
    }
}

// MARK: - Local Agent Detail View (Read-only)

struct LocalAgentDetailView: View {
    let agent: LocalAgentFile
    @State private var showPreview: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(agent.path.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // Open in Finder button
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([agent.path])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                // Toggle preview
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPreview.toggle()
                    }
                } label: {
                    Image(systemName: showPreview ? "eye.fill" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(showPreview ? .blue : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(showPreview ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(showPreview ? "Hide Preview" : "Show Preview")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #endif

            // Content + Preview (read-only)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Read-only editor
                    ScrollView {
                        Text(agent.content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .background(.background)
                    .frame(width: showPreview ? geometry.size.width / 2 : geometry.size.width)

                    if showPreview {
                        Divider()

                        // Live Preview
                        MarkdownPreviewView(content: agent.content)
                            .frame(width: geometry.size.width / 2)
                    }
                }
            }
        }
        .background(.background)
    }
}

// MARK: - Skill Detail View (Editable)

struct SkillDetailView: View {
    @Bindable var skill: Skill
    @State private var editedContent: String = ""
    @State private var showPreview: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.orange)

                Text(skill.name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                // Toggle preview
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPreview.toggle()
                    }
                } label: {
                    Image(systemName: showPreview ? "eye.fill" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(showPreview ? .blue : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(showPreview ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(showPreview ? "Hide Preview" : "Show Preview")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            #endif

            // Editor + Preview
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Editor
                    MarkdownEditorView(text: $editedContent)
                        .frame(width: showPreview ? geometry.size.width / 2 : geometry.size.width)

                    if showPreview {
                        Divider()

                        // Live Preview
                        MarkdownPreviewView(content: editedContent)
                            .frame(width: geometry.size.width / 2)
                    }
                }
            }
        }
        .background(.background)
        .onAppear {
            editedContent = skill.content
        }
        .onChange(of: skill) { _, newSkill in
            editedContent = newSkill.content
        }
        .onChange(of: editedContent) { _, newValue in
            skill.updateContent(newValue)
        }
    }
}

// MARK: - Markdown Editor

struct MarkdownEditorView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(macOS)
        ScrollView {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
        .background(.background)
        #else
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .focused($isFocused)
            .padding(16)
        #endif
    }
}

// MARK: - Markdown Preview

struct MarkdownPreviewView: View {
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(attributedContent)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .background(.background)
    }

    private var attributedContent: AttributedString {
        // Use SwiftUI's native markdown support
        do {
            let attributed = try AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return attributed
        } catch {
            return AttributedString(content)
        }
    }
}

// MARK: - Empty Skill Selection

struct EmptySkillSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Skill Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a skill to edit its content")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Button Style

struct SkillsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Previews

#Preview("Skills List") {
    SkillsListView(workspace: nil, selection: .constant(nil))
        .modelContainer(PreviewContainer.shared.container)
}
