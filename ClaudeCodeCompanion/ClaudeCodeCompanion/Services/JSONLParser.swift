import Foundation

actor JSONLParser {

    // MARK: - ISO8601 formatter

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Public API

    /// Parse a single JSONL file into messages using streaming line reading.
    func parseFile(at url: URL, projectPath: String) throws -> [ConversationMessage] {
        let sessionId = Self.extractSessionId(from: url)
        guard let fileHandle = FileHandle(forReadingAtPath: url.path) else {
            throw ParserError.cannotOpenFile(url.path)
        }
        defer { fileHandle.closeFile() }

        var messages: [ConversationMessage] = []
        let bufferSize = 64 * 1024
        var leftover = ""

        while true {
            guard let chunk = try? fileHandle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            guard let chunkString = String(data: chunk, encoding: .utf8) else {
                continue
            }
            leftover += chunkString
            var lines = leftover.components(separatedBy: "\n")
            // Last element is incomplete unless chunk ended with newline
            leftover = lines.removeLast()

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let message = parseLine(trimmed, sessionId: sessionId) {
                    messages.append(message)
                }
            }
        }
        // Handle final leftover
        let trimmed = leftover.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let message = parseLine(trimmed, sessionId: sessionId) {
            messages.append(message)
        }
        return messages
    }

    // MARK: - Line parsing

    /// Parse a single JSONL line into a ConversationMessage.
    private func parseLine(_ line: String, sessionId: String) -> ConversationMessage? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let typeStr = json["type"] as? String,
              let messageType = ConversationMessage.MessageType(rawValue: typeStr) else {
            return nil
        }

        let uuid = json["uuid"] as? String ?? UUID().uuidString
        let parentUuid = json["parentUuid"] as? String
        let cwd = json["cwd"] as? String
        let gitBranch = json["gitBranch"] as? String

        let timestamp: Date
        if let ts = json["timestamp"] as? String {
            timestamp = Self.parseTimestamp(ts)
        } else {
            timestamp = Date.distantPast
        }

        let contentText = extractTextContent(from: json, type: messageType)

        return ConversationMessage(
            id: uuid,
            sessionId: sessionId,
            type: messageType,
            timestamp: timestamp,
            contentText: contentText,
            contentRaw: line,
            parentUuid: parentUuid,
            cwd: cwd,
            gitBranch: gitBranch
        )
    }

    // MARK: - Text extraction

    /// Extract plain text from message content. Handles both String and Array formats.
    private func extractTextContent(from json: [String: Any], type: ConversationMessage.MessageType) -> String {
        switch type {
        case .user, .system:
            return extractFromMessageField(json)
        case .assistant:
            return extractFromAssistantMessage(json)
        case .attachment:
            return extractFromAttachment(json)
        case .queueOperation:
            return extractFromQueueOperation(json)
        case .lastPrompt:
            return ""
        }
    }

    /// Extract text from `message.content` which may be String or Array.
    private func extractFromMessageField(_ json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any] else { return "" }
        return Self.extractContentText(from: message)
    }

    /// Extract text from assistant message content blocks, skipping thinking blocks.
    private func extractFromAssistantMessage(_ json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any] else { return "" }
        let content = message["content"]

        if let text = content as? String {
            return text
        }
        guard let blocks = content as? [[String: Any]] else { return "" }

        var parts: [String] = []
        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            case "tool_use":
                if let name = block["name"] as? String {
                    parts.append("[Tool: \(name)]")
                }
            case "tool_result":
                if let text = block["content"] as? String, !text.isEmpty {
                    parts.append(text)
                } else if let items = block["content"] as? [[String: Any]] {
                    for item in items {
                        if let t = item["text"] as? String {
                            parts.append(t)
                        }
                    }
                }
            default:
                // Skip thinking blocks and unknown types for plain text
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Extract text from attachment entries.
    private func extractFromAttachment(_ json: [String: Any]) -> String {
        guard let attachment = json["attachment"] as? [String: Any] else { return "" }
        if let content = attachment["content"] as? String, !content.isEmpty {
            return content
        }
        if let stdout = attachment["stdout"] as? String, !stdout.isEmpty {
            return stdout
        }
        if let hookName = attachment["hookName"] as? String {
            return "[Hook: \(hookName)]"
        }
        if let type = attachment["type"] as? String {
            return "[Attachment: \(type)]"
        }
        return ""
    }

    /// Extract text from queue-operation entries.
    private func extractFromQueueOperation(_ json: [String: Any]) -> String {
        let operation = json["operation"] as? String ?? "unknown"
        if let content = json["content"] as? String, !content.isEmpty {
            return "[\(operation)] \(content)"
        }
        return "[\(operation)]"
    }

    // MARK: - Content block parsing (static, for rich rendering)

    /// Parse structured content blocks from a raw JSON line for rich rendering.
    static func parseContentBlocks(from rawJSON: String) -> [ContentBlock] {
        guard let data = rawJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [.text(rawJSON)]
        }

        let type = json["type"] as? String ?? ""

        switch type {
        case "user", "system":
            let text = extractContentTextStatic(from: json)
            guard !text.isEmpty else { return [] }
            return [.text(text)]

        case "assistant":
            return parseAssistantBlocks(json)

        case "attachment":
            if let attachment = json["attachment"] as? [String: Any] {
                let content = attachment["content"] as? String
                    ?? attachment["stdout"] as? String
                    ?? ""
                guard !content.isEmpty else { return [] }
                return [.text(content)]
            }
            return []

        case "queue-operation":
            let op = json["operation"] as? String ?? ""
            let content = json["content"] as? String ?? ""
            let combined = content.isEmpty ? "[\(op)]" : "[\(op)] \(content)"
            return [.text(combined)]

        default:
            return []
        }
    }

    // MARK: - Private helpers

    private static func parseAssistantBlocks(_ json: [String: Any]) -> [ContentBlock] {
        guard let message = json["message"] as? [String: Any] else { return [] }
        let content = message["content"]

        if let text = content as? String {
            return [.text(text)]
        }
        guard let blocks = content as? [[String: Any]] else { return [] }

        var result: [ContentBlock] = []
        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    result.append(.text(text))
                }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty {
                    result.append(.thinking(text))
                }
            case "tool_use":
                let name = block["name"] as? String ?? "unknown"
                var inputJSON = "{}"
                if let input = block["input"] {
                    if let inputData = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
                       let inputStr = String(data: inputData, encoding: .utf8) {
                        inputJSON = inputStr
                    }
                }
                result.append(.toolUse(name: name, inputJSON: inputJSON))
            case "tool_result":
                if let text = block["content"] as? String {
                    result.append(.toolResult(content: text))
                } else if let items = block["content"] as? [[String: Any]] {
                    let combined = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !combined.isEmpty {
                        result.append(.toolResult(content: combined))
                    }
                }
            default:
                break
            }
        }
        return result
    }

    /// Extract content text from a message dict. Handles String and Array of {type, text}.
    private static func extractContentText(from message: [String: Any]) -> String {
        let content = message["content"]
        if let text = content as? String {
            return text
        }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                if block["type"] as? String == "tool_result" {
                    if let text = block["content"] as? String { return text }
                    if let items = block["content"] as? [[String: Any]] {
                        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    /// Static version for use in parseContentBlocks.
    private static func extractContentTextStatic(from json: [String: Any]) -> String {
        guard let message = json["message"] as? [String: Any] else { return "" }
        return extractContentText(from: message)
    }

    /// Extract session ID from a JSONL file URL.
    /// Handles both top-level files (UUID.jsonl) and subagent files (UUID/subagents/agent-XXX.jsonl).
    static func extractSessionId(from url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        return filename
    }

    /// Parse an ISO8601 timestamp string.
    static func parseTimestamp(_ string: String) -> Date {
        if let date = iso8601Formatter.date(from: string) {
            return date
        }
        if let date = iso8601FallbackFormatter.date(from: string) {
            return date
        }
        return Date.distantPast
    }

    /// Detect if a file path indicates a subagent conversation.
    static func isSubagentPath(_ url: URL) -> Bool {
        url.path.contains("/subagents/")
    }

    // MARK: - Errors

    enum ParserError: LocalizedError {
        case cannotOpenFile(String)

        var errorDescription: String? {
            switch self {
            case .cannotOpenFile(let path):
                return "Cannot open file at \(path)"
            }
        }
    }
}
