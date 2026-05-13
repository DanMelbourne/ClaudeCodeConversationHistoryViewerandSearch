import Foundation

// MARK: - Project

/// A project derived from a folder under ~/.claude/projects/
struct Project: Identifiable, Hashable {
    let id: String
    let displayName: String
    let path: URL
    var sessionCount: Int
    var lastActivityDate: Date?
}

// MARK: - ConversationSession

/// A conversation session (one JSONL file)
struct ConversationSession: Identifiable, Hashable {
    let id: String
    let projectId: String
    let filePath: URL
    var firstUserMessage: String?
    var timestamp: Date?
    var messageCount: Int
    var isSubagent: Bool
}

// MARK: - ConversationMessage

/// A single message in a conversation
struct ConversationMessage: Identifiable, Hashable {
    let id: String
    let sessionId: String
    let type: MessageType
    let timestamp: Date
    let contentText: String
    let contentRaw: String
    let parentUuid: String?
    let cwd: String?
    let gitBranch: String?

    enum MessageType: String, Codable, Hashable {
        case user
        case assistant
        case system
        case attachment
        case queueOperation = "queue-operation"
        case lastPrompt = "last-prompt"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ConversationMessage, rhs: ConversationMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ContentBlock

/// Structured content blocks for rich rendering
enum ContentBlock: Identifiable, Hashable {
    case text(String)
    case thinking(String)
    case toolUse(name: String, inputJSON: String)
    case toolResult(content: String)

    var id: String {
        switch self {
        case .text(let s):
            return "text-\(s.hashValue)"
        case .thinking(let s):
            return "thinking-\(s.hashValue)"
        case .toolUse(let name, let input):
            return "tool-\(name)-\(input.hashValue)"
        case .toolResult(let s):
            return "result-\(s.hashValue)"
        }
    }
}

// MARK: - ParsedMessage

/// Parsed message with structured content for rendering
struct ParsedMessage: Identifiable {
    let id: String
    let type: ConversationMessage.MessageType
    let timestamp: Date
    let blocks: [ContentBlock]
    let rawJSON: String
}

// MARK: - SearchResult

/// A result from FTS5 full-text search
struct SearchResult: Identifiable {
    let id: Int
    let sessionId: String
    let projectPath: String
    let messageType: String
    let timestamp: Date
    let snippet: String
    let fullText: String
    let contextBefore: String
    let contextAfter: String
}
