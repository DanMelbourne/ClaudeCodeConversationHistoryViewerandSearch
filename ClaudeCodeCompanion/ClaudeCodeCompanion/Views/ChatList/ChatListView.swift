import SwiftUI

struct ChatListView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        @Bindable var vm = appViewModel

        Group {
            if appViewModel.selectedProject == nil {
                emptyState
            } else if appViewModel.isLoadingSessions {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appViewModel.sessions.isEmpty {
                noSessionsState
            } else {
                sessionList
            }
        }
        .navigationTitle(appViewModel.selectedProject?.displayName ?? "Sessions")
    }

    // MARK: - Session List

    private var sessionList: some View {
        @Bindable var vm = appViewModel
        return List(selection: $vm.selectedSession) {
            ForEach(appViewModel.sessions) { session in
                SessionRow(session: session)
                    .tag(session)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: appViewModel.selectedSession) { _, newSession in
            if let session = newSession {
                Task { @MainActor in
                    appViewModel.loadMessages(for: session)
                    appViewModel.detailDestination = .conversation
                }
            }
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Select a project")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Choose a project from the sidebar to view its conversation sessions.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSessionsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("No sessions")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This project has no conversation history yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: ConversationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formattedDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    if session.agent != .claude {
                        AgentBadge(agent: session.agent)
                    }

                    if session.isSubagent {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(DesignConstants.accentColor)
                            .help("Subagent session")
                    }

                    Text("\(session.messageCount)")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesignConstants.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(DesignConstants.accentColor)
                }
            }

            if let title = session.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }

            if let preview = session.firstUserMessage {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            } else {
                Text("No preview available")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .help("\(session.agent.displayName) session with \(session.messageCount) messages")
    }

    private var formattedDate: String {
        guard let date = session.timestamp else { return "Unknown date" }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }
}
