import SwiftUI

#if os(macOS)

struct TerminalCloseConfirmationSheet: View {
    @Binding var killTmuxSession: Bool
    let pendingPermissionRequests: Int
    let queuedTaskCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)

                Text("Close Terminal?")
                    .font(.headline)

                Text("This will stop the terminal and return any assigned work to the backlog.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if pendingPermissionRequests > 0 || queuedTaskCount > 0 {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if pendingPermissionRequests > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.yellow)
                            Text("\(pendingPermissionRequests) pending permission \(pendingPermissionRequests == 1 ? "request" : "requests") will be dismissed")
                                .font(.callout)
                        }
                    }
                    if queuedTaskCount > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(.blue)
                            Text("\(queuedTaskCount) queued \(queuedTaskCount == 1 ? "task" : "tasks") will be moved back to backlog")
                                .font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider()

            Toggle(isOn: $killTmuxSession) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also kill tmux session")
                        .font(.body)
                    Text("If unchecked, the tmux session keeps running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)

                Button("Close Terminal") {
                    onConfirm()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 380)
        .background(.background)
    }
}

#endif
