import SwiftUI

struct ConversationView: View {
    @Environment(AppViewModel.self) var appViewModel
    @State private var localSearchText: String = ""
    @State private var localSearchResults: [String] = []  // message IDs that match
    @State private var localSearchIndex: Int = 0
    @State private var localSearchTask: Task<Void, Never>?
    @FocusState private var localSearchFocused: Bool

    var body: some View {
        Group {
            if appViewModel.selectedSession == nil {
                emptyState
            } else if appViewModel.isLoadingMessages {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !appViewModel.hasMessages {
                emptyConversation
            } else {
                conversationContent
            }
        }
    }

    // MARK: - Conversation Content

    private var conversationContent: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if let notice = appViewModel.cachedConversationNotice {
                    Label(notice, systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.quaternary)
                        .help("This reconstruction comes from the local SQLite search cache, not the original JSONL file.")
                }

                // Local find bar
                if appViewModel.showConversationSearch {
                    localSearchBar(proxy: proxy)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // The view model publishes this projection only when
                        // the conversation or system-message setting changes.
                        // `body` therefore never re-scans the transcript.
                        ForEach(appViewModel.displayedMessageRows) { row in
                            if row.showsDateDivider {
                                DateDivider(date: row.message.timestamp)
                                    .padding(.vertical, 8)
                            }

                            if appViewModel.viewMode == .raw {
                                RawMessageView(message: row.message)
                                    .id(row.message.id)
                            } else {
                                MessageView(
                                    message: row.message,
                                    showSystemMessages: appViewModel.showSystemMessages,
                                    isHighlighted: appViewModel.scrollToMessageId == row.message.id,
                                    highlightTerm: appViewModel.showConversationSearch ? localSearchText : nil
                                )
                                .id(row.message.id)
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
            .onKeyPress(.escape) {
                if appViewModel.showConversationSearch {
                    appViewModel.showConversationSearch = false
                    clearLocalSearch()
                    return .handled
                }
                return .ignored
            }
            .onChange(of: appViewModel.scrollToMessageId) { _, messageId in
                guard let messageId else { return }
                // Single scroll attempt after a short delay for the view to render
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard appViewModel.scrollToMessageId == messageId else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(messageId, anchor: .center)
                    }
                    // Clear highlight after 4 seconds
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        guard appViewModel.scrollToMessageId == messageId else { return }
                        withAnimation(.easeOut(duration: 0.8)) {
                            appViewModel.scrollToMessageId = nil
                        }
                    }
                }
            }
            .onChange(of: appViewModel.selectedSession) { _, _ in
                // Clear local search when switching sessions
                appViewModel.showConversationSearch = false
                clearLocalSearch()
            }
        }
    }

    // MARK: - Local Search Bar

    private func localSearchBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Find in conversation...", text: $localSearchText)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .focused($localSearchFocused)
                .onSubmit { navigateLocalSearch(direction: 1, proxy: proxy) }
                .onChange(of: localSearchText) { _, _ in
                    performLocalSearch { first in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(first, anchor: .center)
                        }
                    }
                }

            if !localSearchResults.isEmpty {
                Text("\(localSearchIndex + 1)/\(localSearchResults.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36)

                Button { navigateLocalSearch(direction: -1, proxy: proxy) } label: {
                    Image(systemName: "chevron.up").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Previous match")

                Button { navigateLocalSearch(direction: 1, proxy: proxy) } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Next match")
            } else if !localSearchText.isEmpty {
                Text("No matches")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                appViewModel.showConversationSearch = false
                clearLocalSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close find bar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Local Search Logic

    /// Debounced and run off the main actor.
    ///
    /// Scanning every block of every message and lowercasing the result is
    /// tens of megabytes of string work in a long transcript. Doing that
    /// synchronously inside `onChange` blocked the main thread on every
    /// keystroke.
    private func performLocalSearch(then scroll: ((String) -> Void)? = nil) {
        localSearchTask?.cancel()

        let query = localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            localSearchResults = []
            localSearchIndex = 0
            return
        }

        let rows = appViewModel.displayedMessageRows
        localSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let matches = await Task.detached(priority: .userInitiated) {
                Self.matchingMessageIDs(in: rows, query: query)
            }.value

            guard !Task.isCancelled else { return }
            localSearchResults = matches
            localSearchIndex = 0
            if let first = matches.first { scroll?(first) }
        }
    }

    /// Pure and static so it runs off the main actor and is unit testable.
    nonisolated static func matchingMessageIDs(in rows: [ConversationDisplayRow], query: String) -> [String] {
        rows.compactMap { row in
            let message = row.message
            let matches = message.blocks.contains { block in
                switch block {
                case .text(let s), .thinking(let s), .toolResult(let s):
                    return s.range(of: query, options: .caseInsensitive) != nil
                case .toolUse(let name, let input):
                    return name.range(of: query, options: .caseInsensitive) != nil
                        || input.range(of: query, options: .caseInsensitive) != nil
                }
            }
            return matches ? message.id : nil
        }
    }

    private func navigateLocalSearch(direction: Int, proxy: ScrollViewProxy) {
        guard !localSearchResults.isEmpty else { return }
        localSearchIndex = (localSearchIndex + direction + localSearchResults.count) % localSearchResults.count
        let targetId = localSearchResults[localSearchIndex]
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(targetId, anchor: .center)
        }
        appViewModel.scrollToMessageId = targetId
    }

    private func clearLocalSearch() {
        localSearchTask?.cancel()
        localSearchTask = nil
        localSearchText = ""
        localSearchResults = []
        localSearchIndex = 0
    }

    // MARK: - System Message Toggle

    private var systemMessageToggle: some View {
        Toggle(isOn: Binding(
            get: { appViewModel.showSystemMessages },
            set: { value in
                Task { @MainActor in
                    await appViewModel.setShowSystemMessages(value)
                }
            }
        )) {
            Label("System", systemImage: "eye")
                .font(.caption)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Show or hide system messages")
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
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return ConversationFormatters.time.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return ConversationFormatters.yesterdayTime.string(from: date)
        }
        return ConversationFormatters.fullDateTime.string(from: date)
    }
}

// MARK: - Shared Formatters

/// `DateFormatter` construction costs ~0.05 ms. Built per row it added tens of
/// milliseconds to every render pass of a long conversation, so the formatters
/// are created once and reused. Main-actor isolated because `DateFormatter` is
/// not thread-safe.
@MainActor
enum ConversationFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let yesterdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "'Yesterday' h:mm a"
        return formatter
    }()

    static let fullDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter
    }()
}

// MARK: - Message View

private struct MessageView: View {
    let message: ParsedMessage
    let showSystemMessages: Bool
    var isHighlighted: Bool = false
    var highlightTerm: String? = nil

    var body: some View {
        if message.type == .system && !showSystemMessages {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                avatar
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(roleName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(roleColor)

                        Text(formattedTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                            ContentBlockView(block: block)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(messageBubbleColor, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, isHighlighted ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHighlighted ? DesignConstants.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isHighlighted ? DesignConstants.accentColor.opacity(0.4) : Color.clear, lineWidth: 2)
            )
            .textSelection(.enabled)
            .animation(.easeInOut(duration: 0.3), value: isHighlighted)
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
        ConversationFormatters.time.string(from: message.timestamp)
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

    /// A single transcript line can carry a multi-megabyte payload (pasted
    /// images arrive base64-encoded). Laying that out as one `Text` blocks the
    /// main thread for seconds, so Raw mode shows a bounded prefix. The Copy
    /// button still copies the whole record.
    static let rawDisplayLimit = 20_000

    private var displayedJSON: String {
        // `utf8.count` is O(1); `count` walks the whole string, which defeats
        // the point of the guard on exactly the records it is here to catch.
        let byteLength = message.rawJSON.utf8.count
        guard byteLength > Self.rawDisplayLimit else { return message.rawJSON }
        return String(message.rawJSON.prefix(Self.rawDisplayLimit))
            + "\n\n… \(byteLength - Self.rawDisplayLimit) more bytes — use Copy raw JSON for the full record."
    }

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

            Text(displayedJSON)
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
