import Foundation
import SQLite3

actor DatabaseManager {
    private var db: OpaquePointer?
    private let dbPath: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClaudeCodeCompanion")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        dbPath = appDir.appendingPathComponent("index.db")
    }

    // MARK: - Open / Close

    func open() throws {
        guard db == nil else { return }
        let rc = sqlite3_open(dbPath.path, &db)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw DBError.openFailed(msg)
        }
        // Performance pragmas
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA cache_size = -8000") // 8 MB
    }

    func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Schema

    func createSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS indexed_files (
                path TEXT PRIMARY KEY,
                last_modified REAL NOT NULL,
                session_id TEXT NOT NULL,
                project_path TEXT NOT NULL
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                project_path TEXT NOT NULL,
                uuid TEXT,
                parent_uuid TEXT,
                type TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                content_text TEXT NOT NULL,
                content_raw TEXT NOT NULL,
                is_subagent INTEGER NOT NULL DEFAULT 0,
                cwd TEXT,
                git_branch TEXT
            )
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_project ON messages(project_path)")
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp)")

        // FTS5 external content table
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                content_text,
                content='messages',
                content_rowid='id',
                tokenize='porter unicode61'
            )
        """)

        // Triggers to keep FTS in sync
        try execute("""
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content_text) VALUES (new.id, new.content_text);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content_text) VALUES('delete', old.id, old.content_text);
            END
        """)

        try execute("""
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content_text) VALUES('delete', old.id, old.content_text);
                INSERT INTO messages_fts(rowid, content_text) VALUES (new.id, new.content_text);
            END
        """)
    }

    // MARK: - Indexing

    /// Check whether a file needs reindexing based on its modification date.
    func needsReindex(path: String, modificationDate: Date) -> Bool {
        guard let db else { return true }
        let sql = "SELECT last_modified FROM indexed_files WHERE path = ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return true }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        let storedModified = sqlite3_column_double(stmt, 0)
        return modificationDate.timeIntervalSince1970 > storedModified
    }

    /// Index messages from a parsed file. Deletes previous messages for the file first.
    func indexMessages(_ messages: [ConversationMessage], filePath: String, modificationDate: Date, projectPath: String, isSubagent: Bool) throws {
        guard let db else { throw DBError.notOpen }

        try deleteMessagesForFile(path: filePath)

        try execute("BEGIN TRANSACTION")

        do {
            // Insert messages
            let insertSQL = """
                INSERT INTO messages (session_id, project_path, uuid, parent_uuid, type, timestamp, content_text, content_raw, is_subagent, cwd, git_branch)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(lastError)
            }
            defer { sqlite3_finalize(stmt) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

            for msg in messages {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, (msg.sessionId as NSString).utf8String, -1, transient)
                sqlite3_bind_text(stmt, 2, (projectPath as NSString).utf8String, -1, transient)
                sqlite3_bind_text(stmt, 3, (msg.id as NSString).utf8String, -1, transient)
                if let parentUuid = msg.parentUuid {
                    sqlite3_bind_text(stmt, 4, (parentUuid as NSString).utf8String, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_text(stmt, 5, (msg.type.rawValue as NSString).utf8String, -1, transient)

                let tsString = ISO8601DateFormatter().string(from: msg.timestamp)
                sqlite3_bind_text(stmt, 6, (tsString as NSString).utf8String, -1, transient)
                sqlite3_bind_text(stmt, 7, (msg.contentText as NSString).utf8String, -1, transient)
                sqlite3_bind_text(stmt, 8, (msg.contentRaw as NSString).utf8String, -1, transient)
                sqlite3_bind_int(stmt, 9, isSubagent ? 1 : 0)
                if let cwd = msg.cwd {
                    sqlite3_bind_text(stmt, 10, (cwd as NSString).utf8String, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                if let branch = msg.gitBranch {
                    sqlite3_bind_text(stmt, 11, (branch as NSString).utf8String, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }

                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else {
                    throw DBError.insertFailed(lastError)
                }
            }

            // Update indexed_files record
            let sessionId = messages.first?.sessionId ?? ""
            let upsertSQL = """
                INSERT INTO indexed_files (path, last_modified, session_id, project_path)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET last_modified = excluded.last_modified
            """
            var upsertStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(lastError)
            }
            defer { sqlite3_finalize(upsertStmt) }

            sqlite3_bind_text(upsertStmt, 1, (filePath as NSString).utf8String, -1, transient)
            sqlite3_bind_double(upsertStmt, 2, modificationDate.timeIntervalSince1970)
            sqlite3_bind_text(upsertStmt, 3, (sessionId as NSString).utf8String, -1, transient)
            sqlite3_bind_text(upsertStmt, 4, (projectPath as NSString).utf8String, -1, transient)

            guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
                throw DBError.insertFailed(lastError)
            }

            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Delete all messages associated with a file path.
    func deleteMessagesForFile(path: String) throws {
        guard let db else { throw DBError.notOpen }

        // Get session_id for this file
        let selectSQL = "SELECT session_id FROM indexed_files WHERE path = ?"
        var selectStmt: OpaquePointer?
        defer { sqlite3_finalize(selectStmt) }

        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else { return }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(selectStmt, 1, (path as NSString).utf8String, -1, transient)

        guard sqlite3_step(selectStmt) == SQLITE_ROW else { return }
        guard let sessionIdPtr = sqlite3_column_text(selectStmt, 0) else { return }
        let sessionId = String(cString: sessionIdPtr)

        // Delete messages by session_id from this file
        // We need to match on session_id. Multiple files can share a session_id (subagents),
        // but each file has a unique agent filename as the sessionId in messages.
        let deleteSQL = "DELETE FROM messages WHERE session_id = ?"
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }

        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(deleteStmt, 1, (sessionId as NSString).utf8String, -1, transient)
        sqlite3_step(deleteStmt)

        // Delete indexed_files entry
        let deleteFileSQL = "DELETE FROM indexed_files WHERE path = ?"
        var deleteFileStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteFileStmt) }

        guard sqlite3_prepare_v2(db, deleteFileSQL, -1, &deleteFileStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(deleteFileStmt, 1, (path as NSString).utf8String, -1, transient)
        sqlite3_step(deleteFileStmt)
    }

    // MARK: - Search

    /// Full-text search using FTS5. Returns results with highlighted snippets.
    func search(query: String, projectPath: String? = nil, sessionId: String? = nil, limit: Int = 100) throws -> [SearchResult] {
        guard let db else { throw DBError.notOpen }

        // Sanitize the query for FTS5: wrap each word in quotes to prevent syntax errors
        let sanitizedQuery = sanitizeFTS5Query(query)
        guard !sanitizedQuery.isEmpty else { return [] }

        var sql = """
            SELECT
                m.id,
                m.session_id,
                m.project_path,
                m.type,
                m.timestamp,
                snippet(messages_fts, 0, '<mark>', '</mark>', '...', 40) as snippet,
                m.content_text
            FROM messages_fts
            JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ?
        """
        var bindIndex: Int32 = 2

        if projectPath != nil {
            sql += " AND m.project_path = ?"
            bindIndex += 1
        }
        if sessionId != nil {
            sql += " AND m.session_id = ?"
            bindIndex += 1
        }

        sql += " ORDER BY rank LIMIT ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var paramIndex: Int32 = 1
        sqlite3_bind_text(stmt, paramIndex, (sanitizedQuery as NSString).utf8String, -1, transient)
        paramIndex += 1

        if let projectPath {
            sqlite3_bind_text(stmt, paramIndex, (projectPath as NSString).utf8String, -1, transient)
            paramIndex += 1
        }
        if let sessionId {
            sqlite3_bind_text(stmt, paramIndex, (sessionId as NSString).utf8String, -1, transient)
            paramIndex += 1
        }

        sqlite3_bind_int(stmt, paramIndex, Int32(limit))

        var results: [SearchResult] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let sessionIdVal = columnText(stmt, 1)
            let projectPathVal = columnText(stmt, 2)
            let messageType = columnText(stmt, 3)
            let timestampStr = columnText(stmt, 4)
            let snippet = columnText(stmt, 5)
            let fullText = columnText(stmt, 6)

            let timestamp = isoFormatter.date(from: timestampStr)
                ?? isoFallback.date(from: timestampStr)
                ?? Date.distantPast

            // Fetch surrounding context
            let (before, after) = fetchContext(messageId: id, sessionId: sessionIdVal)

            results.append(SearchResult(
                id: id,
                sessionId: sessionIdVal,
                projectPath: projectPathVal,
                messageType: messageType,
                timestamp: timestamp,
                snippet: snippet,
                fullText: fullText,
                contextBefore: before,
                contextAfter: after
            ))
        }

        return results
    }

    // MARK: - Queries

    /// Get all messages for a session, ordered by timestamp.
    func messagesForSession(sessionId: String) throws -> [ConversationMessage] {
        guard let db else { throw DBError.notOpen }

        let sql = """
            SELECT uuid, session_id, type, timestamp, content_text, content_raw, parent_uuid, cwd, git_branch
            FROM messages
            WHERE session_id = ?
            ORDER BY id ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, transient)

        var messages: [ConversationMessage] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = columnText(stmt, 0)
            let sessId = columnText(stmt, 1)
            let typeStr = columnText(stmt, 2)
            let timestampStr = columnText(stmt, 3)
            let contentText = columnText(stmt, 4)
            let contentRaw = columnText(stmt, 5)
            let parentUuid = columnTextOptional(stmt, 6)
            let cwd = columnTextOptional(stmt, 7)
            let gitBranch = columnTextOptional(stmt, 8)

            let timestamp = isoFormatter.date(from: timestampStr)
                ?? isoFallback.date(from: timestampStr)
                ?? Date.distantPast

            guard let type = ConversationMessage.MessageType(rawValue: typeStr) else { continue }

            messages.append(ConversationMessage(
                id: uuid,
                sessionId: sessId,
                type: type,
                timestamp: timestamp,
                contentText: contentText,
                contentRaw: contentRaw,
                parentUuid: parentUuid,
                cwd: cwd,
                gitBranch: gitBranch
            ))
        }
        return messages
    }

    /// Get all sessions for a project.
    func sessionsForProject(projectPath: String) throws -> [ConversationSession] {
        guard let db else { throw DBError.notOpen }

        let sql = """
            SELECT
                m.session_id,
                f.path,
                COUNT(*) as msg_count,
                MAX(m.timestamp) as last_ts,
                MIN(CASE WHEN m.type = 'user' THEN m.content_text END) as first_user_msg,
                MAX(m.is_subagent) as is_subagent
            FROM messages m
            JOIN indexed_files f ON f.session_id = m.session_id AND f.project_path = m.project_path
            WHERE m.project_path = ?
            GROUP BY m.session_id
            ORDER BY last_ts DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, (projectPath as NSString).utf8String, -1, transient)

        var sessions: [ConversationSession] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = columnText(stmt, 0)
            let filePath = columnText(stmt, 1)
            let msgCount = Int(sqlite3_column_int(stmt, 2))
            let lastTimestamp = columnTextOptional(stmt, 3)
            let firstUserMsg = columnTextOptional(stmt, 4)
            let isSubagent = sqlite3_column_int(stmt, 5) != 0

            let timestamp: Date?
            if let ts = lastTimestamp {
                timestamp = isoFormatter.date(from: ts) ?? isoFallback.date(from: ts)
            } else {
                timestamp = nil
            }

            // Truncate preview text
            let preview: String?
            if let msg = firstUserMsg, !msg.isEmpty {
                preview = String(msg.prefix(200))
            } else {
                preview = nil
            }

            sessions.append(ConversationSession(
                id: sessionId,
                projectId: projectPath,
                filePath: URL(fileURLWithPath: filePath),
                firstUserMessage: preview,
                timestamp: timestamp,
                messageCount: msgCount,
                isSubagent: isSubagent
            ))
        }
        return sessions
    }

    /// Get all projects.
    func allProjects() throws -> [Project] {
        guard let db else { throw DBError.notOpen }

        let sql = """
            SELECT
                m.project_path,
                COUNT(DISTINCT m.session_id) as session_count,
                MAX(m.timestamp) as last_ts
            FROM messages m
            GROUP BY m.project_path
            ORDER BY last_ts DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        var projects: [Project] = []
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()
        isoFallback.formatOptions = [.withInternetDateTime]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let projectPath = columnText(stmt, 0)
            let sessionCount = Int(sqlite3_column_int(stmt, 1))
            let lastTimestamp = columnTextOptional(stmt, 2)

            let timestamp: Date?
            if let ts = lastTimestamp {
                timestamp = isoFormatter.date(from: ts) ?? isoFallback.date(from: ts)
            } else {
                timestamp = nil
            }

            let displayName = Self.projectDisplayName(from: projectPath)

            projects.append(Project(
                id: projectPath,
                displayName: displayName,
                path: URL(fileURLWithPath: projectPath),
                sessionCount: sessionCount,
                lastActivityDate: timestamp
            ))
        }
        return projects
    }

    /// Get total count of indexed files.
    func indexedFileCount() throws -> Int {
        guard let db else { throw DBError.notOpen }
        let sql = "SELECT COUNT(*) FROM indexed_files"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get total count of indexed messages.
    func indexedMessageCount() throws -> Int {
        guard let db else { throw DBError.notOpen }
        let sql = "SELECT COUNT(*) FROM messages"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.queryFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Rebuild FTS index

    /// Rebuild the FTS5 index from the messages table. Call after bulk operations.
    func rebuildFTSIndex() throws {
        try execute("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
    }

    // MARK: - Private helpers

    private func execute(_ sql: String) throws {
        guard let db else { throw DBError.notOpen }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errmsg)
            throw DBError.executeFailed(msg)
        }
    }

    private var lastError: String {
        guard let db else { return "Database not open" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: ptr)
    }

    private func columnTextOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    /// Fetch one message before and one after the given message for context.
    private func fetchContext(messageId: Int, sessionId: String) -> (before: String, after: String) {
        guard let db else { return ("", "") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        var before = ""
        var after = ""

        // Message before
        let beforeSQL = """
            SELECT content_text FROM messages
            WHERE session_id = ? AND id < ? AND type IN ('user', 'assistant')
            ORDER BY id DESC LIMIT 1
        """
        var beforeStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, beforeSQL, -1, &beforeStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(beforeStmt, 1, (sessionId as NSString).utf8String, -1, transient)
            sqlite3_bind_int64(beforeStmt, 2, Int64(messageId))
            if sqlite3_step(beforeStmt) == SQLITE_ROW {
                before = columnText(beforeStmt, 0)
                if before.count > 200 {
                    before = String(before.prefix(200)) + "..."
                }
            }
        }
        sqlite3_finalize(beforeStmt)

        // Message after
        let afterSQL = """
            SELECT content_text FROM messages
            WHERE session_id = ? AND id > ? AND type IN ('user', 'assistant')
            ORDER BY id ASC LIMIT 1
        """
        var afterStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, afterSQL, -1, &afterStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(afterStmt, 1, (sessionId as NSString).utf8String, -1, transient)
            sqlite3_bind_int64(afterStmt, 2, Int64(messageId))
            if sqlite3_step(afterStmt) == SQLITE_ROW {
                after = columnText(afterStmt, 0)
                if after.count > 200 {
                    after = String(after.prefix(200)) + "..."
                }
            }
        }
        sqlite3_finalize(afterStmt)

        return (before, after)
    }

    /// Sanitize a search query for FTS5. Wraps terms in quotes and joins with spaces (implicit AND).
    private func sanitizeFTS5Query(_ query: String) -> String {
        let terms = query.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Derive a human-readable project name from the folder path.
    /// Claude project folders are named like "-Users-dan-Code-MyProject"
    static func projectDisplayName(from projectPath: String) -> String {
        // The folder name is the project path with slashes replaced by dashes
        let url = URL(fileURLWithPath: projectPath)
        let folderName = url.lastPathComponent

        // Convert dash-separated path back to readable name
        // e.g. "-Users-dan-Code-MyProject" -> "MyProject"
        let components = folderName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

        // Find the meaningful suffix after "Code" or similar common prefixes
        if let codeIndex = components.lastIndex(of: "Code"), codeIndex + 1 < components.count {
            let meaningful = components[(codeIndex + 1)...]
            return meaningful.joined(separator: " ")
        }

        // Fallback: take the last component
        if let last = components.last {
            return last
        }

        return folderName
    }

    // MARK: - Errors

    enum DBError: LocalizedError {
        case openFailed(String)
        case notOpen
        case prepareFailed(String)
        case insertFailed(String)
        case queryFailed(String)
        case executeFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Failed to open database: \(msg)"
            case .notOpen: return "Database is not open"
            case .prepareFailed(let msg): return "Failed to prepare statement: \(msg)"
            case .insertFailed(let msg): return "Failed to insert: \(msg)"
            case .queryFailed(let msg): return "Query failed: \(msg)"
            case .executeFailed(let msg): return "Execution failed: \(msg)"
            }
        }
    }
}
