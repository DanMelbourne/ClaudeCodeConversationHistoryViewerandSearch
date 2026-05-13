import SwiftUI

struct ConversationView: View {
    @Environment(AppViewModel.self) var appViewModel

    var body: some View {
        Group {
            if appViewModel.selectedSession == nil {
                emptyState
            } else if appViewModel.messages.isEmpty {
                emptyConversation
            } else {
                conversationContent
            }
        }
    }

    // MARK: - Conversation Content

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                        // Date divider if gap > 30 minutes from previous message
                        if shouldShowDateDivider(at: index) {
                            DateDivider(date: message.timestamp)
                                .padding(.vertical, 8)
                        }

                        if appViewModel.viewMode == .raw {
                            RawMessageView(message: message)
                        } else {
                            MessageView(message: message, showSystemMessages: appViewModel.showSystemMessages)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .overlay(alignment: .topTrailing) {
                systemMessageToggle
                    .padding(12)
            }
        }
    }

    // MARK: - System Message Toggle

    private var systemMessageToggle: some View {
        Toggle(isOn: Bindable(appViewModel).showSystemMessages) {
            Label("System", systemImage: "eye")
                .font(.caption)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Show or hide system messages")
    }

    // MARK: - Filtered Messages

    private var filteredMessages: [ParsedMessage] {
        if appViewModel.showSystemMessages {
            return appViewModel.messages
        }
        return appViewModel.messages.filter { $0.type != .system }
    }

    // MARK: - Date Divider Logic

    private func shouldShowDateDivider(at index: Int) -> Bool {
        guard index > 0 else { return false }
        let current = filteredMessages[index].timestamp
        let previous = filteredMessages[index - 1].timestamp
        return current.timeIntervalSince(previous) > 1800 // 30 minutes
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("Select a conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Choose a session from the list to view its messages.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyConversation: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("Empty conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Date Divider

private struct DateDivider: View {
    let date: Date

    var body: some View {
        HStack {
            VStack { Divider() }
            Text(formattedDate)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
            VStack { Divider() }
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy h:mm a"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Message View

private struct MessageView: View {
    let message: ParsedMessage
    let showSystemMessages: Bool

    var body: some View {
        if message.type == .system && !showSystemMessages {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                // Avatar
                avatar
                    .frame(width: 28, height: 28)

                // Content
                VStack(alignment: .leading, spacing: 4) {
                    // Header
                    HStack(spacing: 6) {
                        Text(roleName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(roleColor)

                        Text(formattedTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    // Content blocks
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.blocks) { block in
                            ContentBlockView(block: block)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBubbleColor, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
        switch message.type {
        case .user:
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
        case .assistant:
            ZStack {
                Circle()
                    .fill(DesignConstants.accentColor)
                Text("C")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .system:
            Image(systemName: "gearshape.circle.fill")
                .font(.title2)
                .foregroundStyle(.tertiary)
        default:
            Image(systemName: "questionmark.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Role Properties

    private var roleName: String {
        switch message.type {
        case .user: return "You"
        case .assistant: return "Claude"
        case .system: return "System"
        default: return "Other"
        }
    }

    private var roleColor: Color {
        switch message.type {
        case .user: return .primary
        case .assistant: return DesignConstants.accentColor
        case .system: return .secondary
        default: return .secondary
        }
    }

    private var messageBubbleColor: Color {
        switch message.type {
        case .user:
            return Color(nsColor: .controlBackgroundColor)
        case .assistant:
            return Color(nsColor: .controlBackgroundColor).opacity(0.6)
        case .system:
            return Color(nsColor: .controlBackgroundColor).opacity(0.3)
        default:
            return Color(nsColor: .controlBackgroundColor).opacity(0.3)
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: message.timestamp)
    }
}

// MARK: - Content Block View

private struct ContentBlockView: View {
    let block: ContentBlock

    var body: some View {
        switch block {
        case .text(let text):
            MarkdownTextView(markdown: text)

        case .thinking(let text):
            ThinkingBlockView(text: text)

        case .toolUse(let name, let inputJSON):
            ToolUseBlockView(name: name, inputJSON: inputJSON)

        case .toolResult(let content):
            ToolResultBlockView(content: content)
        }
    }
}

// MARK: - Thinking Block

private struct ThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Thinking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .tint(.secondary)
    }
}

// MARK: - Tool Use Block

private struct ToolUseBlockView: View {
    let name: String
    let inputJSON: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(inputJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(DesignConstants.accentColor)
                Text(toolDisplayName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
        }
        .tint(DesignConstants.accentColor)
    }

    private var toolDisplayName: String {
        // Extract a short description from the tool name and first argument
        let shortName = name.replacingOccurrences(of: "mcp__", with: "")
            .replacingOccurrences(of: "__", with: ": ")
        return shortName
    }
}

// MARK: - Tool Result Block

private struct ToolResultBlockView: View {
    let content: String
    @State private var isExpanded = false

    var body: some View {
        if content.count > 200 {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Result (\(content.count) chars)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Result")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Raw Message View

private struct RawMessageView: View {
    let message: ParsedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.type.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignConstants.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(DesignConstants.accentColor)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.rawJSON, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy raw JSON")
            }

            Text(message.rawJSON)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
        .padding(.vertical, 4)
    }
}
