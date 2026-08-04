import Foundation

/// Builds Claude-Code-shaped JSONL records for other agents' transcripts.
///
/// Codex and Cursor each store conversations in their own format. Rather than
/// teaching every renderer, exporter and search path about three schemas, the
/// adapters transcode into the same record shape `JSONLParser` already reads:
///
///     {"type":"assistant","uuid":…,"timestamp":…,
///      "message":{"role":"assistant","content":[{"type":"text","text":…}]}}
///
/// That keeps rendering, export, FTS text extraction and the cached-copy path
/// identical for all agents.
enum AgentMessageBuilder {

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Content blocks

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func thinkingBlock(_ text: String) -> [String: Any] {
        ["type": "thinking", "thinking": text]
    }

    static func toolUseBlock(name: String, input: Any) -> [String: Any] {
        ["type": "tool_use", "name": name, "input": input]
    }

    static func toolResultBlock(_ content: String) -> [String: Any] {
        ["type": "tool_result", "content": content]
    }

    // MARK: - Records

    /// Build one Claude-shaped message. Returns nil when every block is empty,
    /// so callers never index blank rows.
    static func message(
        type: ConversationMessage.MessageType,
        uuid: String,
        sessionId: String,
        timestamp: Date,
        blocks: [[String: Any]],
        cwd: String?,
        gitBranch: String?,
        agent: AgentKind
    ) -> ConversationMessage? {
        guard !blocks.isEmpty else { return nil }

        var record: [String: Any] = [
            "type": type.rawValue,
            "uuid": uuid,
            "timestamp": isoFormatter.string(from: timestamp),
            "agent": agent.rawValue,
            "message": [
                "role": type == .assistant ? "assistant" : "user",
                "content": blocks
            ] as [String: Any]
        ]
        if let cwd { record["cwd"] = cwd }
        if let gitBranch { record["gitBranch"] = gitBranch }

        let raw = jsonString(record)
        let text = plainText(from: blocks)

        return ConversationMessage(
            id: uuid,
            sessionId: sessionId,
            type: type,
            timestamp: timestamp,
            contentText: text,
            contentRaw: raw,
            parentUuid: nil,
            cwd: cwd,
            gitBranch: gitBranch,
            agent: agent
        )
    }

    /// Plain-text projection used for FTS indexing and previews.
    /// Mirrors `JSONLParser`'s extraction: thinking blocks are excluded.
    static func plainText(from blocks: [[String: Any]]) -> String {
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            case "tool_use":
                if let name = block["name"] as? String { parts.append("[Tool: \(name)]") }
            case "tool_result":
                if let content = block["content"] as? String, !content.isEmpty { parts.append(content) }
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Codex and Cursor both use "output"/"content" fields that are either a
    /// bare string or an array of `{type, text}` items.
    static func flattenedText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let items = value as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String { return text }
            return jsonString(dict)
        }
        return ""
    }

    /// Trim a long tool payload so a single 5 MB command output cannot bloat
    /// the index or stall the renderer.
    static func truncated(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… [truncated \(text.count - limit) characters]"
    }
}
