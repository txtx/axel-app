import SwiftUI
import SwiftData
import CryptoKit

// MARK: - Team List View (Middle Column)

struct TeamListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var members: [OrganizationMember]
    @Query private var invitations: [OrganizationInvitation]
    @Query private var profiles: [Profile]

    @Binding var selectedMember: OrganizationMember?
    @State private var isInviting = false

    private var pendingInvitations: [OrganizationInvitation] {
        invitations.filter { $0.isPending }
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack {
                Text("Team")
                    .font(.title2.bold())
                Spacer()
                Text("\(members.count)")
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

            if members.isEmpty && pendingInvitations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        // Members Section
                        if !members.isEmpty {
                            Section {
                                ForEach(members) { member in
                                    TeamMemberRowView(
                                        member: member,
                                        profile: profiles.first { $0.id == member.user?.id },
                                        isSelected: selectedMember == member
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        TapGesture().onEnded {
                                            selectedMember = member
                                        }
                                    )
                                    .contextMenu {
                                        if member.role != "owner" {
                                            Button(role: .destructive) {
                                                removeMember(member)
                                            } label: {
                                                Label("Remove from Team", systemImage: "person.badge.minus")
                                            }
                                        }
                                    }
                                }
                            } header: {
                                SectionHeaderView(title: "Members", count: members.count)
                            }
                        }

                        // Pending Invitations Section
                        if !pendingInvitations.isEmpty {
                            Section {
                                ForEach(pendingInvitations) { invitation in
                                    PendingInviteRowView(invitation: invitation)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                cancelInvitation(invitation)
                                            } label: {
                                                Label("Cancel Invitation", systemImage: "xmark.circle")
                                            }
                                        }
                                }
                            } header: {
                                SectionHeaderView(title: "Pending Invitations", count: pendingInvitations.count)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedMember = nil
                }
            }

            Divider()

            // Invite button
            Button {
                isInviting = true
            } label: {
                Label("Invite Member", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TeamButtonStyle())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        #if os(iOS)
        .navigationTitle("Team")
        #endif
        .background(.background)
        .sheet(isPresented: $isInviting) {
            InviteMemberView(isPresented: $isInviting)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("No Team Members")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Invite collaborators to work together on this organization")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                isInviting = true
            } label: {
                Label("Invite Member", systemImage: "person.badge.plus")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func removeMember(_ member: OrganizationMember) {
        if selectedMember == member {
            selectedMember = nil
        }
        modelContext.delete(member)
    }

    private func cancelInvitation(_ invitation: OrganizationInvitation) {
        modelContext.delete(invitation)
    }
}

// MARK: - Section Header

private struct SectionHeaderView: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Team Member Row

struct TeamMemberRowView: View {
    let member: OrganizationMember
    let profile: Profile?
    var isSelected: Bool = false

    private var displayName: String {
        profile?.fullName ?? profile?.email ?? "Unknown"
    }

    private var displayEmail: String? {
        if profile?.fullName != nil {
            return profile?.email
        }
        return nil
    }

    private var roleColor: Color {
        switch member.role {
        case "owner": return .orange
        case "admin": return .blue
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Avatar with Gravatar
            GravatarImage(email: profile?.email, name: displayName, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body)
                        .lineLimit(1)

                    Text(member.role.capitalized)
                        .font(.caption)
                        .foregroundStyle(roleColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(roleColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                if let email = displayEmail {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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
        #endif
    }
}

// MARK: - Pending Invite Row

struct PendingInviteRowView: View {
    let invitation: OrganizationInvitation

    private var statusText: String {
        if invitation.isExpired {
            return "Expired"
        }
        return "Pending"
    }

    private var statusColor: Color {
        invitation.isExpired ? .red : .orange
    }

    private var expiryText: String {
        if invitation.isExpired {
            return "Expired \(invitation.expiresAt.formatted(.relative(presentation: .named)))"
        }
        return "Expires \(invitation.expiresAt.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            Circle()
                .fill(Color.orange.opacity(0.2))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "envelope")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(invitation.email)
                        .font(.body)
                        .lineLimit(1)

                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(expiryText)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(invitation.role.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }
}

// MARK: - Invite Member View

struct InviteMemberView: View {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var modelContext
    @Query private var organizations: [Organization]
    @Query private var members: [OrganizationMember]

    @State private var email = ""
    @State private var selectedRole = "member"
    @State private var gitContributors: [GitContributor] = []
    @State private var isLoadingContributors = false
    @FocusState private var isEmailFocused: Bool

    private let roles = ["member", "admin"]

    private var currentOrg: Organization? {
        organizations.first
    }

    private var existingEmails: Set<String> {
        Set(members.compactMap { $0.user?.email?.lowercased() })
    }

    private var suggestedContributors: [GitContributor] {
        gitContributors.filter { !existingEmails.contains($0.email.lowercased()) }
    }

    private var isValidEmail: Bool {
        let emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
        return email.wholeMatch(of: emailRegex) != nil
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Header with organization info
            VStack(spacing: 12) {
                HStack {
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

                // Organization avatar and name
                if let org = currentOrg {
                    VStack(spacing: 8) {
                        if let avatarUrl = org.avatarUrl, let url = URL(string: avatarUrl) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .overlay {
                                        Text(org.name.prefix(1).uppercased())
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundStyle(.blue)
                                    }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 56, height: 56)
                                .overlay {
                                    Text(org.name.prefix(1).uppercased())
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(.blue)
                                }
                        }

                        Text("Invite to \(org.name)")
                            .font(.title3.weight(.medium))
                    }
                } else {
                    Text("Invite Team Member")
                        .font(.title3.weight(.medium))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Email field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Email Address")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        TextField("colleague@company.com", text: $email)
                            .textFieldStyle(.roundedBorder)
                            .focused($isEmailFocused)
                    }

                    // Role picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Role")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("Role", selection: $selectedRole) {
                            ForEach(roles, id: \.self) { role in
                                Text(role.capitalized).tag(role)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Suggested contributors
                    if !suggestedContributors.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested from Git History")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            ForEach(suggestedContributors.prefix(5)) { contributor in
                                Button {
                                    email = contributor.email
                                } label: {
                                    HStack(spacing: 10) {
                                        GravatarImage(email: contributor.email, name: contributor.name, size: 28)

                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(contributor.name)
                                                .font(.body)
                                                .foregroundStyle(.primary)
                                            Text(contributor.email)
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }

                                        Spacer()

                                        Text("\(contributor.commits) commits")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.05))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if isLoadingContributors {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading git contributors...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 16) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Send Invite") {
                    sendInvite()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!isValidEmail)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(width: 450, height: 480)
        .background(.background)
        .onAppear {
            isEmailFocused = true
            loadGitContributors()
        }
        #else
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()

                    Picker("Role", selection: $selectedRole) {
                        ForEach(roles, id: \.self) { role in
                            Text(role.capitalized).tag(role)
                        }
                    }
                }

                if !suggestedContributors.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestedContributors.prefix(5)) { contributor in
                            Button {
                                email = contributor.email
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(contributor.name)
                                    Text(contributor.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Invite Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        sendInvite()
                    }
                    .disabled(!isValidEmail)
                }
            }
            .onAppear {
                loadGitContributors()
            }
        }
        #endif
    }

    private func sendInvite() {
        guard isValidEmail, let org = currentOrg else { return }

        let invitation = OrganizationInvitation(
            email: email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
            role: selectedRole
        )
        invitation.organization = org
        modelContext.insert(invitation)
        isPresented = false
    }

    private func loadGitContributors() {
        isLoadingContributors = true
        Task {
            let contributors = await fetchGitContributors()
            await MainActor.run {
                gitContributors = contributors
                isLoadingContributors = false
            }
        }
    }
}

// MARK: - Git Contributors

struct GitContributor: Identifiable {
    let name: String
    let email: String
    let commits: Int

    var id: String { email }

    var gravatarURL: URL? {
        gravatarUrl(for: email)
    }
}

// MARK: - Gravatar Helper

/// Generate Gravatar URL from email
func gravatarUrl(for email: String, size: Int = 80) -> URL? {
    let trimmed = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let hash = Insecure.MD5.hash(data: Data(trimmed.utf8))
    let hashString = hash.map { String(format: "%02x", $0) }.joined()
    return URL(string: "https://www.gravatar.com/avatar/\(hashString)?s=\(size)&d=identicon")
}

/// Gravatar image view with fallback
struct GravatarImage: View {
    let email: String?
    let name: String
    let size: CGFloat

    init(email: String?, name: String, size: CGFloat = 36) {
        self.email = email
        self.name = name
        self.size = size
    }

    var body: some View {
        if let email = email, let url = gravatarUrl(for: email, size: Int(size * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    fallbackAvatar
                case .empty:
                    ProgressView()
                        .frame(width: size, height: size)
                @unknown default:
                    fallbackAvatar
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: size, height: size)
            .overlay {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}

#if os(macOS)
private func fetchGitContributors() async -> [GitContributor] {
    // Try to get contributors from the current working directory
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["shortlog", "-sne", "HEAD"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        // Parse git shortlog output: "   123\tName <email>"
        let regex = /^\s*(\d+)\s+(.+)\s+<(.+)>$/
        var contributors: [GitContributor] = []

        for line in output.components(separatedBy: "\n") {
            if let match = line.wholeMatch(of: regex) {
                let commits = Int(match.1) ?? 0
                let name = String(match.2).trimmingCharacters(in: .whitespaces)
                let email = String(match.3)
                contributors.append(GitContributor(name: name, email: email, commits: commits))
            }
        }

        return contributors.sorted { $0.commits > $1.commits }
    } catch {
        return []
    }
}
#else
private func fetchGitContributors() async -> [GitContributor] {
    // Git operations not available on iOS
    return []
}
#endif

// MARK: - Empty Team Selection

struct EmptyTeamSelectionView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            Text("No Member Selected")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Select a team member to view details")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Team Member Detail View

struct TeamMemberDetailView: View {
    let member: OrganizationMember
    @Query private var profiles: [Profile]

    private var profile: Profile? {
        profiles.first { $0.id == member.user?.id }
    }

    private var displayName: String {
        profile?.fullName ?? profile?.email ?? "Unknown"
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Header
            HStack(spacing: 14) {
                GravatarImage(email: profile?.email, name: displayName, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)

                    if let email = profile?.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(member.role.capitalized)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(roleColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(roleColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
            #endif

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Member info
                    GroupBox("Member Information") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let email = profile?.email {
                                LabeledContent("Email", value: email)
                            }
                            LabeledContent("Role", value: member.role.capitalized)
                            LabeledContent("Joined", value: member.createdAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(20)
            }
        }
        .background(.background)
    }

    private var roleColor: Color {
        switch member.role {
        case "owner": return .orange
        case "admin": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Button Style

struct TeamButtonStyle: ButtonStyle {
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

#Preview("Team List") {
    TeamListView(selectedMember: .constant(nil))
}
