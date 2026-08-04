import Foundation
import SQLite3

actor DatabaseManager {
    private var db: OpaquePointer?
    private let dbPath: URL

    /// - databaseURL: overrides the default location. Tests use it to exercise
    ///   schema migration against a throwaway index.
    init(databaseURL: URL? = nil) {
        if let databaseURL {
            dbPath = databaseURL
            return
        }
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
        try execute("PRAGMA cache_size = -32000")      // 32 MB page cache
        try execute("PRAGMA temp_store = MEMORY")      // sorts/merges stay off disk
        try execute("PRAGMA mmap_size = 1073741824")   // read the index via mmap, up to 1 GB
    }

    func close() {
        sqlite3_finalize(contextBeforeStmt)
        sqlite3_finalize(contextAfterStmt)
        contextBeforeStmt = nil
        contextAfterStmt = nil
        if let db {
            // Lets SQLite refresh stale query-planner statistics for the next launch.
            sqlite3_exec(db, "PRAGMA optimize", nil, nil, nil)
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

        try addColumnIfMissing(table: "indexed_files", column: "agent", definition: "TEXT NOT NULL DEFAULT 'claude'")
        // How far into an append-only transcript the index has already read.
        try addColumnIfMissing(table: "indexed_files", column: "bytes_indexed", definition: "INTEGER NOT NULL DEFAULT 0")

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

        // Added after the first release — existing indexes are migrated in place.
        try addColumnIfMissing(table: "messages", column: "agent", definition: "TEXT NOT NULL DEFAULT 'claude'")

        try execute("CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_agent ON messages(agent)")
        // Identity guard for incremental indexing: a transcript's last line may
        // still be mid-write, so the next pass re-reads it. Inserting with
        // OR IGNORE against this index makes that a no-op instead of a duplicate.
        // Created after migration, once any historical duplicates are collapsed.
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
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF content_text ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content_text) VALUES('delete', old.id, old.content_text);
                INSERT INTO messages_fts(rowid, content_text) VALUES (new.id, new.content_text);
            END
        """)

        // Runs last: it rewrites rows in the tables created above.
        try migrateStoragePolicyIfNeeded()
        try createIdentityIndex()
    }

    /// The unique identity index cannot be created while duplicates exist, so
    /// it is attempted after the migration has collapsed them.
    private func createIdentityIndex() throws {
        try? execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_identity ON messages(session_id, uuid)")
    }

    // MARK: - Storage policy

    /// `content_raw` exists only so a deleted transcript can still be shown as
    /// a cached copy, and that view renders user and assistant records only.
    /// Storing verbatim JSON for everything else — and for multi-megabyte tool
    /// payloads — cost 1.9 GB on this Mac's index and bought nothing.
    ///
    /// Search is unaffected: `content_text` is what FTS indexes, and it is
    /// never trimmed.
    enum StoragePolicy {
        /// Bump when the rules below — or message identity — change, to trigger
        /// a one-off reindex. v3 moved Codex message ids onto byte offsets.
        static let version = 3
        static let maximumRawBytes = 64 * 1024

        static func rawPayload(for message: ConversationMessage) -> String {
            switch message.type {
            case .user, .assistant:
                let raw = message.contentRaw
                guard raw.utf8.count > maximumRawBytes else { return raw }
                return String(raw.prefix(maximumRawBytes))
            case .system, .attachment, .queueOperation, .lastPrompt:
                // Never rendered in the cached view.
                return ""
            }
        }
    }

    /// Bring an existing index up to the current storage policy **in place**.
    ///
    /// Rebuilding from the transcripts would be simpler, but it would throw
    /// away the one thing the index holds that cannot be regenerated: rows for
    /// transcripts the user has since deleted, which are what the cached-copy
    /// view is for. So the migration rewrites the oversized and unused payloads
    /// and keeps every row.
    private func migrateStoragePolicyIfNeeded() throws {
        try execute("CREATE TABLE IF NOT EXISTS index_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        guard tableExists("messages") else {
            try recordStoragePolicyVersion()
            return
        }

        var stored = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM index_meta WHERE key = 'storage_policy'", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            stored = Int(columnText(stmt, 0)) ?? 0
        }
        sqlite3_finalize(stmt)
        guard stored != StoragePolicy.version else { return }

        // The FTS trigger is scoped to content_text, so rewriting content_raw
        // costs nothing in the full-text index.
        try execute("UPDATE messages SET content_raw = '' WHERE type NOT IN ('user', 'assistant') AND content_raw <> ''")
        try execute("UPDATE messages SET content_raw = substr(content_raw, 1, \(StoragePolicy.maximumRawBytes)) WHERE length(content_raw) > \(StoragePolicy.maximumRawBytes)")

        // Older passes could index the same transcript twice — the same session
        // copied into a worktree folder, for instance. Collapse those before the
        // identity index is created.
        // Index the grouping columns first, then delete only the rows that are
        // actually duplicates. `NOT IN (SELECT MIN(id) …)` would evaluate every
        // row in the table instead of the few thousand that collide.
        try execute("CREATE INDEX IF NOT EXISTS idx_messages_identity_scan ON messages(session_id, uuid)")
        try execute("""
            DELETE FROM messages WHERE id IN (
                SELECT m.id FROM messages m
                JOIN (
                    SELECT session_id, uuid, MIN(id) AS keep_id
                    FROM messages GROUP BY session_id, uuid HAVING COUNT(*) > 1
                ) d ON d.session_id = m.session_id AND d.uuid = m.uuid
                WHERE m.id <> d.keep_id
            )
        """)
        try execute("DROP INDEX IF EXISTS idx_messages_identity_scan")

        try? execute("VACUUM")
        try recordStoragePolicyVersion()
    }

    private func recordStoragePolicyVersion() throws {
        try execute("""
            INSERT INTO index_meta (key, value) VALUES ('storage_policy', '\(StoragePolicy.version)')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Add a column to an existing table when a previous version of the app
    /// created it without one. `ALTER TABLE … ADD COLUMN` is a no-op-safe way
    /// to migrate an index built before agents other than Claude Code existed.
    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        guard let db else { throw DBError.notOpen }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return }

        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if columnText(stmt, 1) == column { exists = true }
        }
        guard !exists else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
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

    /// What the index already knows about one transcript file.
    struct IndexedFileState: Sendable {
        let modificationDate: Date
        let bytesIndexed: Int
    }

    /// Every indexed file's modification date and read offset, in one query.
    func indexedFileStates() -> [String: IndexedFileState] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT path, last_modified, bytes_indexed FROM indexed_files", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }

        var result: [String: IndexedFileState] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[columnText(stmt, 0)] = IndexedFileState(
                modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                bytesIndexed: Int(sqlite3_column_int64(stmt, 2))
            )
        }
        return result
    }

    /// Every indexed file with its recorded modification date.
    ///
    /// One query replaces a per-file round trip; a full pass over this Mac's
    /// history checks ~6,000 files, and asking the actor once per file was the
    /// dominant cost of an otherwise no-op refresh.
    func indexedFileModificationDates() -> [String: Date] {
        guard let db else { return [:] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT path, last_modified FROM indexed_files", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }

        var result: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = columnText(stmt, 0)
            result[path] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        }
        return result
    }

    /// Index messages from a parsed file. Deletes previous messages for the file first.
    func indexMessages(
        _ messages: [ConversationMessage],
        filePath: String,
        modificationDate: Date,
        projectPath: String,
        isSubagent: Bool,
        agent: AgentKind = .claude,
        replaceExisting: Bool = true,
        bytesIndexed: Int = 0
    ) throws {
        guard let db else { throw DBError.notOpen }

        // A huge transcript is indexed in batches: the first batch replaces the
        // previous copy, later batches append to it.
        if replaceExisting {
            try deleteMessagesForFile(path: filePath)
        }

        try execute("BEGIN TRANSACTION")

        do {
            // Insert messages
            let insertSQL = """
                INSERT OR IGNORE INTO messages (session_id, project_path, uuid, parent_uuid, type, timestamp, content_text, content_raw, is_subagent, cwd, git_branch, agent)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                let rawPayload = StoragePolicy.rawPayload(for: msg)
                sqlite3_bind_text(stmt, 8, (rawPayload as NSString).utf8String, -1, transient)
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
                sqlite3_bind_text(stmt, 12, (msg.agent.rawValue as NSString).utf8String, -1, transient)

                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else {
                    throw DBError.insertFailed(lastError)
                }
            }

            // Update indexed_files record
            let sessionId = messages.first?.sessionId ?? ""
            let upsertSQL = """
                INSERT INTO indexed_files (path, last_modified, session_id, project_path, agent, bytes_indexed)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    last_modified = excluded.last_modified,
                    agent = excluded.agent,
                    bytes_indexed = excluded.bytes_indexed
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
            sqlite3_bind_text(upsertStmt, 5, (agent.rawValue as NSString).utf8String, -1, transient)
            sqlite3_bind_int64(upsertStmt, 6, Int64(bytesIndexed))

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

    /// Drop everything indexed for one agent — used when the user switches
    /// that agent off so its history stops appearing in search.
    func deleteMessages(agent: AgentKind) throws {
        guard let db else { throw DBError.notOpen }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for sql in ["DELETE FROM messages WHERE agent = ?", "DELETE FROM indexed_files WHERE agent = ?"] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, (agent.rawValue as NSString).utf8String, -1, transient)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Search

    /// Full-text search using FTS5. Returns results with highlighted snippets.
    ///
    /// - projectPath: exact project_path match (single folder).
    /// - projectBasePath: match a project's base folder AND all of its worktrees
    ///   (folders named `<base>--claude-worktrees-…`), including worktree folders
    ///   that no longer exist on disk. Use this for "Current Project" scope.
    func search(query: String, projectPath: String? = nil, projectBasePath: String? = nil, sessionId: String? = nil, limit: Int = 100) throws -> [SearchResult] {
        guard let db else { throw DBError.notOpen }

        // Sanitize the query for FTS5: wrap each word in quotes to prevent syntax errors
        let sanitizedQuery = sanitizeFTS5Query(query)
        guard !sanitizedQuery.isEmpty else { return [] }

        var sql = """
            SELECT
                m.id,
                m.session_id,
                m.project_path,
                m.uuid,
                m.type,
                m.timestamp,
                snippet(messages_fts, 0, '<mark>', '</mark>', '...', 40) as snippet,
                m.content_text,
                m.agent
            FROM messages_fts
            JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ?
        """

        if projectPath != nil {
            sql += " AND m.project_path = ?"
        }
        if projectBasePath != nil {
            // Base folder exactly, OR any worktree folder under that base.
            sql += " AND (m.project_path = ? OR m.project_path LIKE ? ESCAPE '\\')"
        }
        if sessionId != nil {
            sql += " AND m.session_id = ?"
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
        if let projectBasePath {
            sqlite3_bind_text(stmt, paramIndex, (projectBasePath as NSString).utf8String, -1, transient)
            paramIndex += 1
            let worktreePattern = Self.escapeLike(projectBasePath) + "--claude-worktrees-%"
            sqlite3_bind_text(stmt, paramIndex, (worktreePattern as NSString).utf8String, -1, transient)
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
            let messageUuid = columnText(stmt, 3)
            let messageType = columnText(stmt, 4)
            let timestampStr = columnText(stmt, 5)
            let snippet = columnText(stmt, 6)
            let fullText = columnText(stmt, 7)
            let agent = AgentKind(rawValue: columnText(stmt, 8)) ?? .claude

            let timestamp = isoFormatter.date(from: timestampStr)
                ?? isoFallback.date(from: timestampStr)
                ?? Date.distantPast

            let (before, after) = fetchContext(messageId: id, sessionId: sessionIdVal)

            results.append(SearchResult(
                id: id,
                sessionId: sessionIdVal,
                projectPath: projectPathVal,
                messageUuid: messageUuid,
                messageType: messageType,
                timestamp: timestamp,
                snippet: snippet,
                fullText: fullText,
                contextBefore: before,
                contextAfter: after,
                agent: agent
            ))
        }

        return results
    }

    // MARK: - Queries

    /// Get all messages for a session, ordered by timestamp.
    func messagesForSession(sessionId: String) throws -> [ConversationMessage] {
        guard let db else { throw DBError.notOpen }

        let sql = """
            SELECT uuid, session_id, type, timestamp, content_text, content_raw, parent_uuid, cwd, git_branch, agent
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
            let agent = AgentKind(rawValue: columnText(stmt, 9)) ?? .claude

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
                gitBranch: gitBranch,
                agent: agent
            ))
        }
        return messages
    }

    /// Get all sessions for a project.
    ///
    /// - includeWorktrees: also return sessions recorded in `<path>--claude-worktrees-…`
    ///   folders, which is how Codex sessions run inside a worktree are indexed.
    func sessionsForProject(projectPath: String, includeWorktrees: Bool = false) throws -> [ConversationSession] {
        guard let db else { throw DBError.notOpen }

        let projectPredicate = includeWorktrees
            ? "(m.project_path = ? OR m.project_path LIKE ? ESCAPE '\\')"
            : "m.project_path = ?"

        let sql = """
            SELECT
                m.session_id,
                f.path,
                COUNT(*) as msg_count,
                MAX(m.timestamp) as last_ts,
                MIN(CASE WHEN m.type = 'user' THEN m.content_text END) as first_user_msg,
                MAX(m.is_subagent) as is_subagent,
                MIN(m.agent) as agent
            FROM messages m
            JOIN indexed_files f ON f.session_id = m.session_id AND f.project_path = m.project_path
            WHERE \(projectPredicate)
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
        if includeWorktrees {
            let worktreePattern = Self.escapeLike(projectPath) + "--claude-worktrees-%"
            sqlite3_bind_text(stmt, 2, (worktreePattern as NSString).utf8String, -1, transient)
        }

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
            let agent = AgentKind(rawValue: columnText(stmt, 6)) ?? .claude

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
                isSubagent: isSubagent,
                agent: agent
            ))
        }
        return sessions
    }

    /// Get all projects. Pass `agents` to count only those agents' sessions —
    /// used for the Codex/Cursor rows that merge into the filesystem list.
    func allProjects(agents: Set<AgentKind>? = nil) throws -> [Project] {
        guard let db else { throw DBError.notOpen }

        // Values come from a fixed enum, never user input.
        let agentFilter: String
        if let agents, !agents.isEmpty {
            let list = agents.map { "'\($0.rawValue)'" }.sorted().joined(separator: ", ")
            agentFilter = "WHERE m.agent IN (\(list))"
        } else {
            agentFilter = ""
        }

        let sql = """
            SELECT
                m.project_path,
                COUNT(DISTINCT m.session_id) as session_count,
                MAX(m.timestamp) as last_ts,
                GROUP_CONCAT(DISTINCT m.agent) as agents,
                (
                    SELECT c.cwd FROM messages c
                    WHERE c.project_path = m.project_path AND c.cwd IS NOT NULL
                    ORDER BY c.timestamp DESC LIMIT 1
                ) as working_directory
            FROM messages m
            \(agentFilter)
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
            let agentList = columnTextOptional(stmt, 3) ?? AgentKind.claude.rawValue
            let workingDirectory = columnTextOptional(stmt, 4)

            let timestamp: Date?
            if let ts = lastTimestamp {
                timestamp = isoFormatter.date(from: ts) ?? isoFallback.date(from: ts)
            } else {
                timestamp = nil
            }

            let displayName = Self.projectDisplayName(from: projectPath)
            let agents = Set(agentList.split(separator: ",").compactMap { AgentKind(rawValue: String($0)) })

            projects.append(Project(
                id: projectPath,
                displayName: displayName,
                path: URL(fileURLWithPath: projectPath),
                additionalPaths: [],
                sessionCount: sessionCount,
                lastActivityDate: timestamp,
                agents: agents.isEmpty ? [.claude] : agents,
                workingDirectory: workingDirectory
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

    /// Statements for the neighbouring-message lookups, compiled once and
    /// reused for every row of a result set. A 500-hit search used to recompile
    /// two statements per hit.
    private var contextBeforeStmt: OpaquePointer?
    private var contextAfterStmt: OpaquePointer?

    private func prepareContextStatements() {
        guard let db, contextBeforeStmt == nil else { return }
        sqlite3_prepare_v2(db, """
            SELECT content_text FROM messages
            WHERE session_id = ? AND id < ? AND type IN ('user', 'assistant')
            ORDER BY id DESC LIMIT 1
        """, -1, &contextBeforeStmt, nil)
        sqlite3_prepare_v2(db, """
            SELECT content_text FROM messages
            WHERE session_id = ? AND id > ? AND type IN ('user', 'assistant')
            ORDER BY id ASC LIMIT 1
        """, -1, &contextAfterStmt, nil)
    }

    /// Fetch one message before and one after the given message for context.
    private func fetchContext(messageId: Int, sessionId: String) -> (before: String, after: String) {
        guard db != nil else { return ("", "") }
        prepareContextStatements()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func neighbour(_ stmt: OpaquePointer?) -> String {
            guard let stmt else { return "" }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, transient)
            sqlite3_bind_int64(stmt, 2, Int64(messageId))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
            let text = columnText(stmt, 0)
            return text.count > 200 ? String(text.prefix(200)) + "..." : text
        }

        return (neighbour(contextBeforeStmt), neighbour(contextAfterStmt))
    }

    /// Escape SQL LIKE wildcards (`%`, `_`) and the escape char itself so a literal
    /// path can be used as a LIKE prefix. Pairs with `ESCAPE '\'` in the query.
    nonisolated static func escapeLike(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
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
