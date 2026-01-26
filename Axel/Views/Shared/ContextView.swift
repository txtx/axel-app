import SwiftUI
import SwiftData

// MARK: - Context List View (Middle Column)

struct ContextListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Context.updatedAt, order: .reverse) private var contexts: [Context]

    @Binding var selection: Context?
    @State private var isCreatingContext = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack {
                Text("Context")
                    .font(.title2.bold())
                Spacer()
                Text("\(contexts.count)")
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

            if contexts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(contexts) { context in
                            ContextRowView(context: context, isSelected: selection == context)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        selection = context
                                    }
                                )
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteContext(context)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }
            }

            Divider()

            // New Context button
            Button {
                isCreatingContext = true
            } label: {
                Label("New Context", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ContextButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        #if os(iOS)
        .navigationTitle("Context")
        #else
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
        #endif
        .background(.background)
        .sheet(isPresented: $isCreatingContext) {
            CreateContextView(isPresented: $isCreatingContext, selection: $selection)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("No Context")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Context provides background information for your agent")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                isCreatingContext = true
            } label: {
                Label("New Context", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteContext(_ context: Context) {
        if selection == context {
            selection = nil
        }
        modelContext.delete(context)
    }
}

// MARK: - Create Context View

struct CreateContextView: View {
    @Binding var isPresented: Bool
    @Binding var selection: Context?
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""
    @State private var content = ""
    @FocusState private var isNameFocused: Bool
    @FocusState private var isContentFocused: Bool

    private static let contextTemplate = """
---
name: ""
type: "reference"
scope: "project"
---

## Overview

Provide background information that the agent should know.

## Key Information

- Important fact 1
- Important fact 2

## References

Links or references to relevant documentation.
"""

    var body: some View {
        #if os(iOS) || os(visionOS)
        NavigationStack {
            createContextContent
                .navigationTitle("New Context")
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
                            createContext()
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.blue)

                TextField("Context name", text: $name)
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
                    createContext()
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
            content = Self.contextTemplate
        }
        #endif
    }

    #if os(iOS) || os(visionOS)
    private var createContextContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .padding(.top, 4)

                TextField("Context name", text: $name)
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
            content = Self.contextTemplate
        }
    }
    #endif

    private func createContext() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Update the name in the frontmatter
        var finalContent = content
        if finalContent.contains("name: \"\"") {
            finalContent = finalContent.replacingOccurrences(of: "name: \"\"", with: "name: \"\(trimmedName)\"")
        }

        let context = Context(name: trimmedName, content: finalContent)
        modelContext.insert(context)
        selection = context
        isPresented = false
    }
}

struct ContextRowView: View {
    let context: Context
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(context.name)
                    .font(.body)
                    .lineLimit(1)

                Text(context.updatedAt, style: .relative)
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

// MARK: - Context Detail View (Right Panel)

struct ContextDetailView: View {
    @Bindable var context: Context
    @State private var editedContent: String = ""
    @State private var showPreview: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundStyle(.blue)

                Text(context.name)
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
                    ContextEditorView(text: $editedContent)
                        .frame(width: showPreview ? geometry.size.width / 2 : geometry.size.width)

                    if showPreview {
                        Divider()

                        // Live Preview
                        ContextPreviewView(content: editedContent)
                            .frame(width: geometry.size.width / 2)
                    }
                }
            }
        }
        .background(.background)
        .onAppear {
            editedContent = context.content
        }
        .onChange(of: context) { _, newContext in
            editedContent = newContext.content
        }
        .onChange(of: editedContent) { _, newValue in
            context.updateContent(newValue)
        }
    }
}

// MARK: - Context Editor

struct ContextEditorView: View {
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
        .background(Color(nsColor: .textBackgroundColor))
        #else
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .focused($isFocused)
            .padding(16)
        #endif
    }
}

// MARK: - Context Preview

struct ContextPreviewView: View {
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
        do {
            let attributed = try AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return attributed
        } catch {
            return AttributedString(content)
        }
    }
}

// MARK: - Empty Context Selection

struct EmptyContextSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Context Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a context to edit its content")
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

struct ContextButtonStyle: ButtonStyle {
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

#Preview("Context List") {
    ContextListView(selection: .constant(nil))
        .modelContainer(PreviewContainer.shared.container)
}
