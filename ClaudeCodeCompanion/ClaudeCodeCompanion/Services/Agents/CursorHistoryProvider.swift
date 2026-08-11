import Foundation
import SQLite3

/// Reads Cursor's agent/chat history.
///
/// Cursor stores everything in one key/value SQLite database at
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`:
///
/// - `composerData:<composerId>` — one conversation: title, timestamps,
///   the tracked git repo (used as the project folder) and the ordered list of
///   message ids in `fullConversationHeadersOnly`.
/// - `bubbleId:<composerId>:<bubbleId>` — one message: `type` 1 = user,
///   2 = assistant, plus `text`, `thinking` and `toolFormerData`.
///
/// The database is opened read-only so a running Cursor is never disturbed.
enum CursorHistoryProvider {

    struct Conversation {
        let id: String
        let title: String
        let workingDirectory: String?
        let createdAt: Date?
        let updatedAt: Date?
        let bubbleIds: [String]

        /// Conversations that never touched a git repo have no folder to group
        /// under; they collect in one clearly-labelled project instead of
        /// vanishing from the index.
        static let unassignedWorkingDirectory = "/Cursor Chats"

        var projectPath: String {
            ProjectPathEncoder.projectPath(
                for: workingDirectory ?? Self.unassignedWorkingDirectory
            )
        }

        /// Used for incremental reindexing — a conversation is re-read only
        /// when this moves forward.
        var lastModified: Date {
            updatedAt ?? createdAt ?? .distantPast
        }

        /// Synthetic `indexed_files.path` — Cursor has no per-conversation file.
        var indexKey: String { "cursor://composer/\(id)" }
    }

    static var databaseURL: URL {
        AgentKind.cursor.defaultHistoryLocation.appendingPathComponent("state.vscdb")
    }

    static func isAvailable(databaseURL: URL = databaseURL) -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    // MARK: - Conversations

    /// Every conversation header, newest first. Bubble bodies are not read.
    nonisolated static func conversations(databaseURL: URL = databaseURL) -> [Conversation] {
        guard let db = ReadOnlyDatabase(url: databaseURL) else { return [] }
        defer { db.close() }

        var result: [Conversation] = []
        db.query("SELECT key, value FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;'") { key, value in
            guard let json = jsonObject(value) else { return }
            let composerId = json["composerId"] as? String
                ?? String(key.dropFirst("composerData:".count))
            guard !composerId.isEmpty else { return }

            let headers = json["fullConversationHeadersOnly"] as? [[String: Any]] ?? []
            let bubbleIds = headers.compactMap { $0["bubbleId"] as? String }
            guard !bubbleIds.isEmpty else { return }

            let title = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["text"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
                ?? "Untitled conversation"

            result.append(Conversation(
                id: composerId,
                title: title,
                workingDirectory: repoPath(from: json),
                createdAt: date(fromMilliseconds: json["createdAt"]),
                updatedAt: date(fromMilliseconds: json["lastUpdatedAt"]),
                bubbleIds: bubbleIds
            ))
        }

        return result.sorted { $0.lastModified > $1.lastModified }
    }

    // MARK: - Messages

    /// Read one conversation's messages, in transcript order.
    nonisolated static func messages(
        for conversation: Conversation,
        databaseURL: URL = databaseURL
    ) -> [ConversationMessage] {
        guard let db = ReadOnlyDatabase(url: databaseURL) else { return [] }
        defer { db.close() }
        return messages(for: conversation, in: db)
    }

    /// Bulk variant that reuses one open database across many conversations.
    nonisolated static func messages(
        for conversation: Conversation,
        in db: ReadOnlyDatabase
    ) -> [ConversationMessage] {
        let prefix = "bubbleId:\(conversation.id):"
        var bodies: [String: [String: Any]] = [:]

        // Range scan over the primary key instead of LIKE so the index is used.
        db.query(
            "SELECT key, value FROM cursorDiskKV WHERE key >= ? AND key < ?",
            parameters: [prefix, prefix + "\u{7F}"]
        ) { key, value in
            guard let json = jsonObject(value) else { return }
            bodies[String(key.dropFirst(prefix.count))] = json
        }

        var messages: [ConversationMessage] = []
        var fallbackTime = conversation.createdAt ?? conversation.updatedAt ?? Date.distantPast

        for bubbleId in conversation.bubbleIds {
            guard let body = bodies[bubbleId] else { continue }
            let timestamp = date(fromISO: body["createdAt"]) ?? fallbackTime
            fallbackTime = timestamp

            guard let message = message(
                fromBubble: body,
                bubbleId: bubbleId,
                sessionId: conversation.id,
                timestamp: timestamp,
                cwd: conversation.workingDirectory
            ) else { continue }
            messages.append(message)
        }
        return messages
    }

    /// Map one Cursor bubble onto a Claude-shaped message.
    nonisolated static func message(
        fromBubble body: [String: Any],
        bubbleId: String,
        sessionId: String,
        timestamp: Date,
        cwd: String?
    ) -> ConversationMessage? {
        let isUser = (body["type"] as? Int) == 1
        var blocks: [[String: Any]] = []

        if let thinking = body["thinking"] as? [String: Any],
           let text = thinking["text"] as? String, !text.isEmpty {
            blocks.append(AgentMessageBuilder.thinkingBlock(text))
        }

        if let text = body["text"] as? String, !text.isEmpty {
            blocks.append(AgentMessageBuilder.textBlock(text))
        }

        if let tool = body["toolFormerData"] as? [String: Any] {
            let name = tool["name"] as? String ?? "tool"
            blocks.append(AgentMessageBuilder.toolUseBlock(name: name, input: toolInput(tool["params"])))
            let output = AgentMessageBuilder.truncated(
                AgentMessageBuilder.flattenedText(tool["result"] ?? tool["output"])
            )
            if !output.isEmpty {
                blocks.append(AgentMessageBuilder.toolResultBlock(output))
            }
        }

        return AgentMessageBuilder.message(
            type: isUser ? .user : .assistant,
            uuid: bubbleId,
            sessionId: sessionId,
            timestamp: timestamp,
            blocks: blocks,
            cwd: cwd,
            gitBranch: nil,
            agent: .cursor
        )
    }

    // MARK: - Helpers

    private nonisolated static func repoPath(from composer: [String: Any]) -> String? {
        guard let repos = composer["trackedGitRepos"] as? [[String: Any]] else { return nil }
        for repo in repos {
            if let path = repo["repoPath"] as? String, !path.isEmpty { return path }
        }
        return nil
    }

    private nonisolated static func toolInput(_ raw: Any?) -> Any {
        if let string = raw as? String {
            if let data = string.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return decoded
            }
            return ["params": string]
        }
        if let dict = raw as? [String: Any] { return dict }
        return [String: Any]()
    }

    private nonisolated static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private nonisolated static func date(fromMilliseconds value: Any?) -> Date? {
        if let ms = value as? Double, ms > 0 { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = value as? Int, ms > 0 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        return nil
    }

    private nonisolated static func date(fromISO value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let parsed = JSONLParser.parseTimestamp(string)
        return parsed == .distantPast ? nil : parsed
    }
}

// MARK: - Read-only SQLite helper

/// Minimal read-only wrapper over an external SQLite file.
///
/// Opened with `mode=ro` so a running Cursor keeps full write access and the
/// app can never corrupt the file.
final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    /// Run a two-column (key, value) query, streaming rows to `row`.
    func query(_ sql: String, parameters: [String] = [], row: (String, String) -> Void) {
        guard let handle else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), (parameter as NSString).utf8String, -1, transient)
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
            let key = String(cString: keyPtr)
            let value: String
            if let valuePtr = sqlite3_column_text(stmt, 1) {
                value = String(cString: valuePtr)
            } else if let blob = sqlite3_column_blob(stmt, 1) {
                let count = Int(sqlite3_column_bytes(stmt, 1))
                value = String(data: Data(bytes: blob, count: count), encoding: .utf8) ?? ""
            } else {
                value = ""
            }
            row(key, value)
        }
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    deinit { close() }
}
