import SwiftUI
import SwiftData

#if os(macOS)
import AppKit
#endif

// MARK: - Workspace Header (Xcode style)

#if os(macOS)
struct WorkspaceHeaderView: View {
    @Binding var showTerminal: Bool
    @Environment(\.terminalSessionManager) private var sessionManager

    private let headerHeight: CGFloat = 35

    var body: some View {
        OrbView()
            .frame(height: headerHeight, alignment: .center)
    }
}

// Orb - Token usage histogram display (connected to CostTracker)
struct OrbView: View {
    @State private var costTracker = CostTracker.shared

    private var histogramValues: [Double] {
        costTracker.globalHistogramValues
    }

    private var totalTokens: Int {
        costTracker.globalTotalTokens
    }

    private var totalCost: Double {
        costTracker.globalTotalCostUSD
    }

    var body: some View {
        HStack(spacing: 12) {
            // Histogram bars
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(histogramValues.enumerated()), id: \.offset) { _, value in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            LinearGradient(
                                colors: [.orange, .orange.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 5, height: max(3, CGFloat(value) * 20))
                }
            }
            .frame(height: 20)

            // Token count and cost - wider display
            HStack(spacing: 8) {
                Text(formatTokenCount(totalTokens))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.orange)
                if totalCost > 0 {
                    Text(String(format: "$%.4f", totalCost))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.1))
        )
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Pills (inside Orb)

struct WorkspacePill: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

struct DestinationPill: View {
    let appName: String
    let destination: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "app.fill")
                .font(.system(size: 10))
            Text(appName)
                .font(.system(size: 11))
            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Image(systemName: "desktopcomputer")
                .font(.system(size: 10))
            Text(destination)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
#endif

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selection: SidebarSection?
    @Query private var hints: [Hint]
    @Query private var tasks: [WorkTask]
    @Query private var skills: [Skill]
    @Query private var contexts: [Context]
    @Query private var members: [OrganizationMember]
    var onNewTask: () -> Void
    @State private var authService = AuthService.shared
    @State private var syncService = SyncService.shared
    @Environment(\.modelContext) private var modelContext
    #if os(macOS)
    @Environment(\.terminalSessionManager) private var sessionManager
    #endif

    private var pendingHintsCount: Int {
        hints.filter { $0.hintStatus == .pending }.count
    }

    private var answeredHintsCount: Int {
        hints.filter { $0.hintStatus == .answered }.count
    }

    private var queuedTasksCount: Int {
        tasks.filter { $0.taskStatus == .queued }.count
    }

    private var runningTasksCount: Int {
        tasks.filter { $0.taskStatus == .running }.count
    }

    #if os(macOS)
    private var runningCount: Int {
        sessionManager.runningCount
    }
    #else
    private var runningCount: Int {
        runningTasksCount
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Spacer()
                    .frame(height: 4)
                    .listRowSeparator(.hidden)

                // Inbox (Hints that need answers - RED = call to action / bottleneck)
                Label {
                    HStack {
                        Text("Inbox")
                        Spacer()
                        if pendingHintsCount > 0 {
                            Text("\(pendingHintsCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "tray.fill")
                        .foregroundStyle(.red)
                }
                .tag(SidebarSection.inbox(.pending))

                // Indented sub-items for hints
                Label {
                    HStack {
                        Text("Resolved")
                        Spacer()
                        if answeredHintsCount > 0 {
                            Text("\(answeredHintsCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.inbox(.answered))

                // Tasks (BLUE)
                Label {
                    HStack {
                        Text("Tasks")
                        Spacer()
                        if queuedTasksCount > 0 {
                            Text("\(queuedTasksCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.blue)
                }
                .tag(SidebarSection.queue(.queued))

                // Coding Agents
                Label {
                    HStack {
                        Text("Agents")
                        Spacer()
                        if runningTasksCount > 0 {
                            Text("\(runningTasksCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .foregroundStyle(.green)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.queue(.running))

                // Coding Agents (root)
                Label {
                    Text("Agents")
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(.orange)
                }
                .listRowSeparator(.hidden)

                // Terminals (first under Coding Agents)
                Label {
                    HStack {
                        Text("Terminals")
                        Spacer()
                        if runningCount > 0 {
                            Text("\(runningCount)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: runningCount > 0 ? "terminal.fill" : "terminal")
                        .foregroundStyle(runningCount > 0 ? .green : .secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.terminals)

                // Optimizations (shows Skills view)
                Label {
                    HStack {
                        Text("Optimizations")
                        Spacer()
                        if !skills.isEmpty {
                            Text("\(skills.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(.purple)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.optimizations(.skills))

                // Context (under Optimizations)
                Label {
                    HStack {
                        Text("Context")
                        Spacer()
                        if !contexts.isEmpty {
                            Text("\(contexts.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "briefcase.fill")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
                .tag(SidebarSection.optimizations(.context))

                // Team (fourth under Coding Agents)
                Label {
                    HStack {
                        Text("Team")
                        Spacer()
                        if !members.isEmpty {
                            Text("\(members.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: "person.2")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .tag(SidebarSection.team)

                #if os(macOS)
                // Show running sessions under Terminals
                ForEach(sessionManager.sessions) { session in
                    Label {
                        Text(session.taskTitle)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    .padding(.leading, 32)
                    .font(.callout)
                    .listRowSeparator(.hidden)
                }
                #endif
            }
            .listStyle(.sidebar)
            #if os(macOS)
            .scrollContentBackground(.hidden)
            #endif

            Divider()

            // Account/Sync section
            HStack(spacing: 10) {
                if authService.isAuthenticated {
                    if let user = authService.currentUser {
                        AsyncImage(url: URL(string: user.userMetadata["avatar_url"]?.stringValue ?? "")) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 0) {
                            Text(user.userMetadata["user_name"]?.stringValue ?? "Signed In")
                                .font(.callout)
                                .lineLimit(1)
                            if syncService.isSyncing {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Syncing...")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Synced")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }

                        Spacer()

                        Button {
                            Task {
                                await syncService.performFullSync(context: modelContext)
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.callout)
                                .foregroundStyle(syncService.isSyncing ? .secondary : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(syncService.isSyncing)

                        Menu {
                            Button(role: .destructive) {
                                Task {
                                    await authService.signOut(clearingLocalData: modelContext)
                                }
                            } label: {
                                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                    }
                } else {
                    Button {
                        Task {
                            await authService.signInWithGitHub()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle")
                                .font(.system(size: 20))
                            Text("Sign in to Sync")
                                .font(.callout)
                            Spacer()
                            if authService.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(authService.isLoading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle("Axel")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        #endif
    }
}


struct SidebarButtonStyle: ButtonStyle {
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

// MARK: - Hint Inbox View (Middle Column)

struct HintInboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Hint.createdAt, order: .reverse) private var hints: [Hint]

    let filter: HintFilter
    @Binding var selection: Hint?

    private var filteredHints: [Hint] {
        switch filter {
        case .pending: hints.filter { $0.hintStatus == .pending }
        case .answered: hints.filter { $0.hintStatus == .answered }
        case .all: hints
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header with filter name
            HStack {
                Text(filter == .pending ? "Inbox" : filter.rawValue)
                    .font(.title2.bold())
                Spacer()
                Text("\(filteredHints.count)")
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

            if filteredHints.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredHints) { hint in
                            HintRowView(hint: hint, isSelected: selection?.id == hint.id)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        selection = hint
                                    }
                                )
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }
            }
        }
        #if os(iOS)
        .navigationTitle(filter.rawValue)
        #else
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
        #endif
        .background(.background)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(emptyDescription)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .pending: "No Blockers"
        case .answered: "No Resolved Items"
        case .all: "No Blockers"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .pending: "checkmark.seal"
        case .answered: "checkmark.circle"
        case .all: "checkmark.seal"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .pending: "All clear! AI agents will ask questions here when they need help."
        case .answered: "Questions you've answered will appear here"
        case .all: "No questions from AI agents yet"
        }
    }
}

struct HintRowView: View {
    let hint: Hint
    var isSelected: Bool = false

    private var typeIcon: String {
        switch hint.hintType {
        case .exclusiveChoice: "circle.circle"
        case .multipleChoice: "checklist"
        case .textInput: "text.cursor"
        }
    }

    private var typeColor: Color {
        switch hint.hintStatus {
        case .pending: .blue
        case .answered: .green
        case .cancelled: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Type indicator
            Image(systemName: typeIcon)
                .font(.title2)
                .foregroundStyle(typeColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(hint.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(hint.hintStatus == .pending ? .primary : .secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let task = hint.task {
                        Text(task.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(hint.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
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
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }
}

// MARK: - Hint Detail View

struct HintDetailView: View {
    @Bindable var hint: Hint
    @Environment(\.modelContext) private var modelContext
    @State private var selectedOption: String?
    @State private var selectedOptions: Set<String> = []
    @State private var textResponse: String = ""

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: hint.hintStatus == .pending ? "questionmark.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(hint.hintStatus == .pending ? .blue : .green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.title)
                        .font(.headline)
                        .lineLimit(1)

                    if let task = hint.task {
                        Text("From: \(task.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if hint.hintStatus == .pending {
                    Text("Awaiting Response")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("Resolved")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Description
                    if let description = hint.hintDescription {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    // Response UI based on type
                    if hint.hintStatus == .pending {
                        responseUI
                    } else {
                        answeredUI
                    }
                }
                .padding(24)
            }
        }
        .background(.background)
        .onAppear {
            loadExistingResponse()
        }
    }

    @ViewBuilder
    private var responseUI: some View {
        switch hint.hintType {
        case .exclusiveChoice:
            exclusiveChoiceUI
        case .multipleChoice:
            multipleChoiceUI
        case .textInput:
            textInputUI
        }
    }

    private var exclusiveChoiceUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select one option:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        selectedOption = option.value
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedOption == option.value ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selectedOption == option.value ? .blue : .secondary)

                            Text(option.label)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOption == option.value ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            submitButton
        }
    }

    private var multipleChoiceUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select all that apply:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let options = hint.options {
                ForEach(options, id: \.value) { option in
                    Button {
                        if selectedOptions.contains(option.value) {
                            selectedOptions.remove(option.value)
                        } else {
                            selectedOptions.insert(option.value)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedOptions.contains(option.value) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selectedOptions.contains(option.value) ? .blue : .secondary)

                            Text(option.label)
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOptions.contains(option.value) ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            submitButton
        }
    }

    private var textInputUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your response:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            TextEditor(text: $textResponse)
                .font(.body)
                .frame(minHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )

            submitButton
        }
    }

    private var submitButton: some View {
        HStack {
            Spacer()

            Button {
                submitResponse()
            } label: {
                Label("Submit", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .padding(.top, 8)
    }

    private var canSubmit: Bool {
        switch hint.hintType {
        case .exclusiveChoice:
            return selectedOption != nil
        case .multipleChoice:
            return !selectedOptions.isEmpty
        case .textInput:
            return !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submitResponse() {
        var response: Any

        switch hint.hintType {
        case .exclusiveChoice:
            response = selectedOption ?? ""
        case .multipleChoice:
            response = Array(selectedOptions)
        case .textInput:
            response = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Encode response
        if let data = try? JSONEncoder().encode(AnyCodableValue(response)) {
            hint.responseData = data
        }

        hint.hintStatus = .answered
        hint.answeredAt = Date()
    }

    private func loadExistingResponse() {
        // Load any existing response for editing
    }

    @ViewBuilder
    private var answeredUI: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Response:")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let data = hint.responseData,
               let response = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
                Text(response.description)
                    .font(.body)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.1))
                    )
            }

            if let answeredAt = hint.answeredAt {
                Text("Resolved \(answeredAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// Helper for encoding/decoding responses
struct AnyCodableValue: Codable, CustomStringConvertible {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([String].self) {
            value = array
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [String] {
            try container.encode(array)
        }
    }

    var description: String {
        if let string = value as? String {
            return string
        } else if let array = value as? [String] {
            return array.joined(separator: ", ")
        }
        return String(describing: value)
    }
}

// MARK: - Empty Hint Selection View

struct EmptyHintSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "questionmark.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Question Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a question from the inbox to respond")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Task Detail View (Right Panel)

struct TaskDetailView: View {
    @Bindable var task: WorkTask
    let viewModel: TodoViewModel
    @Binding var showTerminal: Bool
    @Binding var selectedTask: WorkTask?
    var onStartTerminal: ((WorkTask) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext
    @State private var editedTitle: String = ""
    @State private var editedDescription: String = ""
    @State private var isPreviewingMarkdown: Bool = false
    @State private var syncService = SyncService.shared
    @State private var showDeleteConfirmation: Bool = false
    @State private var showSkillPicker: Bool = false
    @FocusState private var isTitleFocused: Bool

    private var statusColor: Color {
        switch task.taskStatus {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private var statusIcon: String {
        switch task.taskStatus {
        case .queued: "clock.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .inReview: "eye.circle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(statusColor)

                Text(task.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                // Status badge
                Text(task.taskStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Capsule())

                // Run in Terminal button
                if task.taskStatus == .queued {
                    Button {
                        onStartTerminal?(task)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.callout)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            #endif

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Editable title
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Task title", text: $editedTitle, axis: .vertical)
                            .font(.title.weight(.medium))
                            .textFieldStyle(.plain)
                            .onChange(of: editedTitle) { _, newValue in
                                if task.title != newValue {
                                    task.updateTitle(newValue)
                                }
                            }

                        // Description - using TextField instead of TextEditor to avoid hang
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Description")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                // Edit/Preview toggle
                                Picker("Mode", selection: $isPreviewingMarkdown) {
                                    Label("Edit", systemImage: "pencil")
                                        .tag(false)
                                    Label("Preview", systemImage: "eye")
                                        .tag(true)
                                }
                                .pickerStyle(.segmented)
                                .fixedSize()
                            }

                            if isPreviewingMarkdown {
                                // Markdown preview
                                ScrollView {
                                    if editedDescription.isEmpty {
                                        Text("No description")
                                            .foregroundStyle(.tertiary)
                                            .italic()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        Text(LocalizedStringKey(editedDescription))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .frame(minHeight: 120)
                                .padding(12)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                            } else {
                                // Multi-line TextField instead of TextEditor (TextEditor causes hang)
                                TextField("Description", text: $editedDescription, axis: .vertical)
                                    .lineLimit(5...20)
                                    .font(.system(.body, design: .monospaced))
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                    .onChange(of: editedDescription) { _, newValue in
                                        let newDesc = newValue.isEmpty ? nil : newValue
                                        if task.taskDescription != newDesc {
                                            task.updateDescription(newDesc)
                                        }
                                    }

                                // Markdown hints
                                HStack(spacing: 16) {
                                    Text("**bold**")
                                    Text("*italic*")
                                    Text("`code`")
                                    Text("[link](url)")
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }

                        // Created date
                        HStack {
                            Label {
                                Text("Created \(task.createdAt, style: .relative)")
                            } icon: {
                                Image(systemName: "calendar")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            if task.taskStatus == .completed, let completedAt = task.completedAt {
                                Label {
                                    Text("Completed \(completedAt, style: .relative)")
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                                .font(.callout)
                                .foregroundStyle(.green)
                            }
                        }
                    }

                    // Status Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Status")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(TaskStatus.allCases, id: \.self) { status in
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if status == .completed {
                                            task.markCompleted()
                                            selectedTask = nil
                                        } else {
                                            task.updateStatus(status)
                                        }
                                    }
                                    Task {
                                        await syncService.performFullSync(context: modelContext)
                                    }
                                } label: {
                                    Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .tint(task.taskStatus == status ? statusColorFor(status) : .secondary)
                            }
                        }
                    }

                    Divider()

                    // Skills
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Skills")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                showSkillPicker = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.callout)
                            }
                            .buttonStyle(.bordered)
                        }

                        if task.skills.isEmpty {
                            Text("No skills attached")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(task.skills, id: \.id) { skill in
                                        HStack(spacing: 6) {
                                            Image(systemName: "sparkles")
                                                .font(.caption)
                                            Text(skill.name)
                                                .font(.callout)
                                            Button {
                                                removeSkill(skill)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.caption2)
                                            }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.purple.opacity(0.1))
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Delete
                    HStack {
                        Spacer()

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Task", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(task.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(.background)
        .alert("Delete Task", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteTodo(task, context: modelContext)
                    selectedTask = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(task.title)\"? This action cannot be undone.")
        }
        .sheet(isPresented: $showSkillPicker) {
            TaskSkillPickerView(task: task)
        }
        .onAppear {
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.id) { _, _ in
            editedTitle = task.title
            editedDescription = task.taskDescription ?? ""
        }
        .onChange(of: task.title) { _, newTitle in
            if editedTitle != newTitle {
                editedTitle = newTitle
            }
        }
        .onChange(of: task.taskDescription) { _, newDescription in
            let newValue = newDescription ?? ""
            if editedDescription != newValue {
                editedDescription = newValue
            }
        }
        .onDisappear {
            Task {
                await SyncService.shared.performFullSync(context: modelContext)
            }
        }
    }

    /* NOTE: TextEditor was replaced with TextField(axis: .vertical) because TextEditor
       causes the app to hang when used in this view hierarchy. This appears to be a SwiftUI bug. */

    private func statusColorFor(_ status: TaskStatus) -> Color {
        switch status {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private func removeSkill(_ skill: Skill) {
        if let taskSkill = task.taskSkills.first(where: { $0.skill?.id == skill.id }) {
            modelContext.delete(taskSkill)
        }
    }
}

// MARK: - Task Skill Picker View

struct TaskSkillPickerView: View {
    let task: WorkTask
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Skill.name) private var allSkills: [Skill]
    @ObservedObject private var skillManager = SkillManager.shared
    @State private var selectedSkillIds: Set<UUID> = []

    private var availableSkills: [Skill] {
        let attachedIds = Set(task.skills.map { $0.id })
        return allSkills.filter { !attachedIds.contains($0.id) }
    }

    private var hasAnySkills: Bool {
        !allSkills.isEmpty || !skillManager.allLocalSkills.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !hasAnySkills {
                    emptyState
                } else if availableSkills.isEmpty && skillManager.allLocalSkills.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                        Text("All skills attached")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedSkillIds) {
                        // Local skills section (read-only, cannot be attached)
                        if !skillManager.allLocalSkills.isEmpty {
                            Section {
                                ForEach(skillManager.allLocalSkills) { skill in
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text")
                                            .font(.title3)
                                            .foregroundStyle(.blue)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .font(.body)

                                            Text("Local skill - read only")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }

                                        Spacer()

                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            } header: {
                                Label("Local Skills", systemImage: "folder")
                            }
                        }

                        // Custom skills section (can be attached)
                        if !availableSkills.isEmpty {
                            Section {
                                ForEach(availableSkills) { skill in
                                    HStack(spacing: 12) {
                                        Image(systemName: "sparkles")
                                            .font(.title3)
                                            .foregroundStyle(.purple)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .font(.body)

                                            if !skill.content.isEmpty {
                                                Text(skill.content.prefix(60) + (skill.content.count > 60 ? "..." : ""))
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    .tag(skill.id)
                                }
                            } header: {
                                Label("Custom Skills", systemImage: "sparkles")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Skills")
            #if os(macOS)
            .frame(minWidth: 400, minHeight: 300)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSelectedSkills()
                        dismiss()
                    }
                    .disabled(selectedSkillIds.isEmpty)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("No Skills Available")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Create skills in the Agents section first")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addSelectedSkills() {
        for skillId in selectedSkillIds {
            if let skill = allSkills.first(where: { $0.id == skillId }) {
                let taskSkill = TaskSkill(task: task, skill: skill)
                modelContext.insert(taskSkill)
            }
        }
    }
}

// MARK: - Empty Task Selection View

struct EmptyTaskSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "square.stack")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Task Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a task from the queue to view details")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Create Task View

struct CreateTaskView: View {
    @Binding var isPresented: Bool
    var workspace: Workspace?
    @Environment(\.modelContext) private var modelContext
    @State private var title = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(iOS)
        NavigationStack {
            createTaskContent
                .navigationTitle("New Task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            createTask()
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        #else
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 2)

                TextField("New Task", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit {
                        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            createTask()
                        }
                    }

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
            .padding(20)

            Spacer()

            HStack(spacing: 16) {
                Spacer()

                Text("Press ⏎ to save")
                    .font(.callout)
                    .foregroundStyle(.tertiary)

                Button("Save") {
                    createTask()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 480, height: 180)
        .background(.background)
        .onAppear {
            isFocused = true
        }
        #endif
    }

    #if os(iOS)
    private var createTaskContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "circle")
                    .font(.title2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 4)

                TextField("What needs to be done?", text: $title, axis: .vertical)
                    .font(.title3)
                    .focused($isFocused)
            }
            .padding()

            Spacer()
        }
        .onAppear {
            isFocused = true
        }
    }
    #endif

    private func createTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Get highest priority among existing queued tasks (lower priority = top of queue)
        let maxPriority: Int
        if let workspace {
            maxPriority = workspace.tasks
                .filter { $0.taskStatus == .queued }
                .map { $0.priority }
                .max() ?? 0
        } else {
            // No workspace filter - check all tasks
            let descriptor = FetchDescriptor<WorkTask>(
                predicate: #Predicate { $0.status == "queued" }
            )
            let existingTasks = (try? modelContext.fetch(descriptor)) ?? []
            maxPriority = existingTasks.map { $0.priority }.max() ?? 0
        }

        let todo = WorkTask(title: trimmedTitle)
        todo.workspace = workspace
        todo.priority = maxPriority + 50  // New tasks go to bottom of queue
        modelContext.insert(todo)
        isPresented = false

        // Sync to push the new task to Supabase
        Task {
            await SyncService.shared.performFullSync(context: modelContext)
        }
    }
}

// MARK: - Queue Views (Tasks List)

struct QueueListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkTask.createdAt, order: .reverse) private var tasks: [WorkTask]

    let filter: TaskFilter
    @Binding var selection: WorkTask?
    var onNewTask: () -> Void

    private var filteredTasks: [WorkTask] {
        switch filter {
        case .queued: tasks.filter { $0.taskStatus == .queued }
        case .running: tasks.filter { $0.taskStatus == .running }
        case .completed: tasks.filter { $0.taskStatus == .completed }
        case .all: tasks
        }
    }

    private var headerTitle: String {
        switch filter {
        case .queued: "Tasks"
        case .running: "Agents"
        case .completed: "Completed"
        case .all: "All Tasks"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack {
                Text(headerTitle)
                    .font(.title2.bold())
                Spacer()
                Text("\(filteredTasks.count)")
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

            if filteredTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredTasks) { task in
                            TaskRowView(task: task, isSelected: selection?.id == task.id)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        selection = task
                                    }
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: filteredTasks.map(\.id))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = nil
                }
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 450)
        #endif
        .background(.background)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: onNewTask) {
                    Image(systemName: "plus")
                }
            }
            #endif
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: emptyIcon)
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text(emptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(emptyDescription)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button(action: onNewTask) {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .queued: "No Tasks"
        case .running: "Nothing Coding Agents"
        case .completed: "No Completed Tasks"
        case .all: "No Tasks"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .queued: "tray"
        case .running: "terminal"
        case .completed: "checkmark.circle"
        case .all: "tray"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .queued: "Create a task to get started"
        case .running: "Start a task to see it here"
        case .completed: "Complete a task to see it here"
        case .all: "Create your first task"
        }
    }
}

struct TaskRowView: View {
    let task: WorkTask
    var isSelected: Bool = false

    private var statusColor: Color {
        switch task.taskStatus {
        case .queued: .blue
        case .running: .green
        case .completed: .secondary
        case .inReview: .yellow
        case .aborted: .red
        }
    }

    private var statusIcon: String {
        switch task.taskStatus {
        case .queued: "clock.circle.fill"
        case .running: "play.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .inReview: "eye.circle.fill"
        case .aborted: "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Status indicator
            Image(systemName: statusIcon)
                .font(.title2)
                .frame(width: 24, height: 24)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(task.taskStatus == .completed ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(task.taskStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption)
                        .foregroundStyle(statusColor)

                    Text(task.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Priority indicator
            if task.priority > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        #if os(macOS)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }
}

// MARK: - Window Drag Area (macOS only)

#if os(macOS)
struct WindowDragArea: NSViewRepresentable {
    typealias NSViewType = NSView
    typealias Coordinator = Void

    @MainActor @preconcurrency
    func makeNSView(context: NSViewRepresentableContext<WindowDragArea>) -> NSView {
        let view = DraggableView()
        view.wantsLayer = true
        return view
    }

    @MainActor @preconcurrency
    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<WindowDragArea>) {}
}

class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
#endif
