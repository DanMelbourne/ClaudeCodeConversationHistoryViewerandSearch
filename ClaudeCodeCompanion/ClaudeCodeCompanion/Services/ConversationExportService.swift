import Foundation

enum ConversationExportService {
    struct Conversation {
        struct Message {
            let timestamp: Date
            let role: String
            let content: String
        }

        let projectName: String
        let sessionTitle: String
        let sessionDate: Date?
        let messages: [Message]
    }

    struct ExportResult {
        let projectCount: Int
        let conversationCount: Int
        let messageCount: Int
    }

    static func consolidatedText(exportedAt: Date, conversations: [Conversation]) -> String {
        let formatter = ISO8601DateFormatter()
        var sections = ["Claude Code Conversation History\nExported: \(formatter.string(from: exportedAt))"]

        var currentProject: String?
        for conversation in conversations {
            if conversation.projectName != currentProject {
                sections.append("# \(conversation.projectName)")
                currentProject = conversation.projectName
            }

            let title: String
            if let sessionDate = conversation.sessionDate {
                title = "## \(conversation.sessionTitle) — \(formatter.string(from: sessionDate))"
            } else {
                title = "## \(conversation.sessionTitle)"
            }
            sections.append(title)

            for message in conversation.messages {
                sections.append("[\(formatter.string(from: message.timestamp))] \(message.role)\n\(message.content)")
            }
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    static func exportAllConversations(from projects: [Project], to destination: URL) throws -> ExportResult {
        let fileManager = FileManager.default
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw ExportError.cannotCreateDestination
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer { try? handle.close() }

            try write("Claude Code Conversation History\nExported: \(ISO8601DateFormatter().string(from: Date()))\n", to: handle)

            var projectCount = 0
            var conversationCount = 0
            var messageCount = 0
            for project in projects.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
                let sessions = sessionFiles(for: project)
                let agentReferences = agentSessionReferences(for: project)
                guard !sessions.isEmpty || !agentReferences.isEmpty else { continue }

                projectCount += 1
                try write("\n# \(project.displayName)\n", to: handle)

                for session in sessions {
                    conversationCount += 1
                    let title = session.url.deletingPathExtension().lastPathComponent
                    if let date = session.date {
                        try write("\n## \(title) — \(ISO8601DateFormatter().string(from: date))\n", to: handle)
                    } else {
                        try write("\n## \(title)\n", to: handle)
                    }
                    messageCount += try appendMessages(from: session.url, to: handle)
                }

                // Codex and Cursor conversations for the same folder follow the
                // Claude transcripts so one file holds the whole project.
                for reference in agentReferences {
                    let messages = agentMessages(for: reference)
                    guard !messages.isEmpty else { continue }
                    conversationCount += 1

                    let title = "\(reference.agent.displayName): \(reference.title)"
                    if let date = reference.date {
                        try write("\n## \(title) — \(ISO8601DateFormatter().string(from: date))\n", to: handle)
                    } else {
                        try write("\n## \(title)\n", to: handle)
                    }
                    for message in messages {
                        if try appendInteractiveChatMessage(message.contentRaw, to: handle) {
                            messageCount += 1
                        }
                    }
                }
            }

            guard messageCount > 0 else {
                throw ExportError.noVisibleMessages
            }
            try handle.synchronize()
            try replaceDestination(destination, with: temporaryURL, fileManager: fileManager)
            return ExportResult(
                projectCount: projectCount,
                conversationCount: conversationCount,
                messageCount: messageCount
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func exportProjectConversations(from project: Project, to destination: URL) throws -> ExportResult {
        try exportAllConversations(from: [project], to: destination)
    }

    // MARK: - Codex and Cursor sessions

    /// A conversation from an agent that stores history outside the project
    /// folder. Bodies are read one at a time so a large export stays bounded.
    enum AgentSessionReference {
        case codex(url: URL, id: String, date: Date?)
        case cursor(CursorHistoryProvider.Conversation)

        var agent: AgentKind {
            switch self {
            case .codex: return .codex
            case .cursor: return .cursor
            }
        }

        var title: String {
            switch self {
            case .codex(_, let id, _): return id
            case .cursor(let conversation): return conversation.title
            }
        }

        var date: Date? {
            switch self {
            case .codex(_, _, let date): return date
            case .cursor(let conversation): return conversation.createdAt ?? conversation.updatedAt
            }
        }
    }

    /// Find the Codex rollouts and Cursor conversations whose working directory
    /// maps onto this project's folder.
    static func agentSessionReferences(for project: Project) -> [AgentSessionReference] {
        let folderNames = Set(project.allPaths.map(\.lastPathComponent) + [project.id])
        var references: [AgentSessionReference] = []

        if AgentKind.isEnabled(.codex) {
            for file in CodexHistoryProvider.rolloutFiles() {
                guard let header = CodexHistoryProvider.readHeader(at: file),
                      folderNames.contains(ProjectPathEncoder.encodedFolderName(for: header.workingDirectory))
                else { continue }
                references.append(.codex(url: file, id: header.id, date: header.modificationDate))
            }
        }

        if AgentKind.isEnabled(.cursor) {
            for conversation in CursorHistoryProvider.conversations() {
                let directory = conversation.workingDirectory
                    ?? CursorHistoryProvider.Conversation.unassignedWorkingDirectory
                guard folderNames.contains(ProjectPathEncoder.encodedFolderName(for: directory)) else { continue }
                references.append(.cursor(conversation))
            }
        }

        return references.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    static func agentMessages(for reference: AgentSessionReference) -> [ConversationMessage] {
        switch reference {
        case .codex(let url, _, _):
            return CodexHistoryProvider.parseSession(at: url)?.messages ?? []
        case .cursor(let conversation):
            return CursorHistoryProvider.messages(for: conversation)
        }
    }

    private static func sessionFiles(for project: Project) -> [(url: URL, date: Date?)] {
        let fileManager = FileManager.default
        var uniqueURLs = Set<URL>()
        for folder in project.allPaths {
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                uniqueURLs.insert(url)
            }
        }

        return uniqueURLs.map { url in
            let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let startDate = firstVisibleMessageDate(in: url) ?? modificationDate
            return (url, startDate)
        }.sorted {
            let lhsDate = $0.date ?? .distantPast
            let rhsDate = $1.date ?? .distantPast
            // A consolidated history reads forward in time: oldest session first.
            return lhsDate == rhsDate ? $0.url.path < $1.url.path : lhsDate < rhsDate
        }
    }

    /// Uses the same visible-message boundary as export, rather than an unreliable file date.
    private static func firstVisibleMessageDate(in fileURL: URL) -> Date? {
        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? reader.close() }

        var buffer = Data()
        while let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                if let date = visibleMessageDate(in: lineData) {
                    return date
                }
            }
        }

        return buffer.isEmpty ? nil : visibleMessageDate(in: buffer)
    }

    private static func visibleMessageDate(in lineData: Data) -> Date? {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        let type = (json["type"] as? String)
            ?? ((json["message"] as? [String: Any])?["role"] as? String)
        guard let type,
              type == "user" || type == "human" || type == "assistant",
              let timestamp = json["timestamp"] as? String,
              let date = parseTimestamp(timestamp),
              let line = String(data: lineData, encoding: .utf8),
              !JSONLParser.parseContentBlocks(from: line).isEmpty else {
            return nil
        }
        return date
    }

    private static func parseTimestamp(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: timestamp)
    }

    private static func appendMessages(from fileURL: URL, to handle: FileHandle) throws -> Int {
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }

        var buffer = Data()
        var messageCount = 0
        while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw ExportError.invalidTranscript
                }
                if try appendInteractiveChatMessage(line, to: handle) {
                    messageCount += 1
                }
            }
        }
        if !buffer.isEmpty {
            guard let line = String(data: buffer, encoding: .utf8) else {
                throw ExportError.invalidTranscript
            }
            if try appendInteractiveChatMessage(line, to: handle) {
                messageCount += 1
            }
        }
        return messageCount
    }

    /// Matches ConversationView's default filter: only user and assistant records are visible.
    private static func appendInteractiveChatMessage(_ line: String, to handle: FileHandle) throws -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }

        let type = (json["type"] as? String)
            ?? ((json["message"] as? [String: Any])?["role"] as? String)
        guard let type,
              type == "user" || type == "human" || type == "assistant" else { return false }

        let blocks = JSONLParser.parseContentBlocks(from: line)
        let content = blocks.map(contentText).filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !content.isEmpty else { return false }

        // Transcoded Codex/Cursor records carry their agent so the export names
        // the right assistant.
        let agent = (json["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? .claude
        let role: String
        switch type {
        case "user", "human": role = "User"
        case "assistant": role = agent == .claude ? "Claude" : agent.displayName
        default: return false
        }
        let timestamp = (json["timestamp"] as? String) ?? "Unknown time"
        try write("\n[\(timestamp)] \(role)\n\(content)\n", to: handle)
        return true
    }

    private static func contentText(_ block: ContentBlock) -> String {
        switch block {
        case let .text(text): text
        case let .thinking(text): "[Thinking]\n\(text)"
        case let .toolUse(name, inputJSON): "[Tool: \(name)]\n\(inputJSON)"
        case let .toolResult(content): "[Tool result]\n\(content)"
        }
    }

    private static func write(_ text: String, to handle: FileHandle) throws {
        guard let data = text.data(using: .utf8) else { throw ExportError.encodingFailure }
        try handle.write(contentsOf: data)
    }

    private static func replaceDestination(_ destination: URL, with temporaryURL: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }

    enum ExportError: LocalizedError {
        case cannotCreateDestination
        case encodingFailure
        case invalidTranscript
        case noVisibleMessages

        var errorDescription: String? {
            switch self {
            case .cannotCreateDestination:
                "The chosen folder could not create the export file. Choose another location and try again."
            case .encodingFailure:
                "The conversation history could not be converted to text. Try exporting again."
            case .invalidTranscript:
                "A conversation file is not valid UTF-8 text. Repair or remove that file, then export again."
            case .noVisibleMessages:
                "The selected project has no user or Claude messages to export."
            }
        }
    }
}
